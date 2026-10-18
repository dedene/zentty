import ArgumentParser
import Darwin
import Foundation
import os

private let tmuxCompatCLILogger = Logger(subsystem: "be.zenjoy.zentty", category: "tmux-compat-cli")

/// Hidden subcommand the bundled `tmux-shim/tmux` script re-execs into.
/// Interprets the tmux command line (globals, `-V`, `;` sequences,
/// `if-shell`, `run-shell`) and forwards each remaining command to the
/// running Zentty instance via `AgentIPCRequest(kind: .tmuxCompat, ...)`,
/// printing the returned `stdout` and exiting with tmux-style status.
///
/// Hidden because users never invoke this directly — it's only reachable
/// through the bundled shim, which tmux-based tools resolve as `tmux` on
/// PATH in Agent Teams panes and `zentty launch --teams` / `--tmux-shim`.
struct TmuxCompatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__tmux-compat",
        abstract: "Internal — translate tmux commands to Zentty pane operations.",
        shouldDisplay: false,
        // Tmux subcommands use `-h` as a meaningful flag (e.g.
        // `split-window -h` for horizontal). Suppress ArgumentParser's
        // built-in help so `-h` reaches our handler.
        helpNames: []
    )

    /// Captures everything after `__tmux-compat` raw, including tmux global
    /// options like `-S socket-path` that ArgumentParser would otherwise
    /// reject as unknown. Real tmux accepts globals before the subcommand;
    /// Claude Code 2.1.128+ prefixes `-S <socket>` (parsed from `$TMUX`)
    /// onto every call, so we must tolerate them.
    @Argument(parsing: .allUnrecognized, help: .hidden)
    var rawArguments: [String] = []

    mutating func run() throws {
        let environment = ProcessInfo.processInfo.environment
        if TmuxCommandLine.isVersionRequest(rawArguments) {
            FileHandle.standardOutput.write(Data(TmuxCommandLine.versionLine.utf8))
            return
        }
        guard let invocation = Self.parseTmuxInvocation(rawArguments) else {
            FileHandle.standardError.write(Data(
                "zentty: __tmux-compat requires a tmux subcommand\n".utf8
            ))
            throw ExitCode(1)
        }

        let backend = TmuxCompatCLIBackend(environment: environment)
        let outcome = TmuxCommandRunner(backend: backend).run([invocation.subcommand] + invocation.arguments)
        if !outcome.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        if !outcome.stderr.isEmpty {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        if outcome.exitCode != 0 {
            throw ExitCode(outcome.exitCode)
        }
    }

    /// Strip tmux's global options that appear before the subcommand. Real
    /// tmux accepts e.g. `-S socket-path`, `-L socket-name`, `-f config`,
    /// `-c shell-command`, `-T features` ahead of the subcommand; we ignore
    /// them because routing happens via `ZENTTY_INSTANCE_SOCKET`. Claude Code
    /// 2.1.128 prefixes `-S <socket-from-$TMUX>` onto every call, which
    /// previously crashed ArgumentParser before any handler ran.
    static func parseTmuxInvocation(
        _ arguments: [String]
    ) -> (subcommand: String, arguments: [String])? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if TmuxCommandLine.globalValueOptions.contains(argument) {
                index += (index + 1 < arguments.count) ? 2 : 1
                continue
            }
            if TmuxCommandLine.globalBoolOptions.contains(argument) || argument == "-V" {
                index += 1
                continue
            }
            let subcommand = argument
            let rest = Array(arguments[(index + 1)...])
            return (subcommand, rest)
        }
        return nil
    }

    static func subcommandReadsStandardInput(_ subcommand: String) -> Bool {
        switch TmuxCommandLine.canonicalName(subcommand) {
        case "load-buffer", "set-buffer":
            return true
        default:
            return false
        }
    }
}

/// The CLI side of `TmuxCommandRunner`: IPC to the app, local shell, local
/// wait-for.
final class TmuxCompatCLIBackend: TmuxCommandBackend {
    private let environment: [String: String]
    private var standardInputConsumed = false

    init(environment: [String: String]) {
        self.environment = environment
    }

    func send(subcommand: String, arguments: [String]) -> TmuxCommandOutcome {
        trace(event: "cli_start", subcommand: subcommand, arguments: arguments)
        if TmuxCommandLine.canonicalName(subcommand) == "wait-for" {
            let outcome = runLocalWaitFor(arguments: arguments)
            trace(event: "cli_wait_for_done", subcommand: subcommand, arguments: arguments)
            return outcome
        }

        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            return .failure(
                "zentty: __tmux-compat must be invoked from inside a Zentty pane (ZENTTY_INSTANCE_SOCKET unset)"
            )
        }
        guard IPCCommand.hasRequiredRoutingEnvironment(environment) else {
            let missing = IPCCommand.missingRoutingEnvironmentKeys(environment).joined(separator: ", ")
            return .failure("zentty: __tmux-compat missing routing env: \(missing)")
        }

        var stdinPayload: String?
        if TmuxCompatCommand.subcommandReadsStandardInput(subcommand), !standardInputConsumed {
            standardInputConsumed = true
            stdinPayload = readStandardInputIfPresent()
        }

        let request = AgentIPCRequest(
            kind: .tmuxCompat,
            arguments: arguments,
            standardInput: stdinPayload,
            environment: forwardedEnvironment(),
            expectsResponse: true,
            subcommand: subcommand
        )

        do {
            let response = try AgentIPCClient.send(request: request, socketPath: socketPath)
            let stdout = response?.result?.stdout ?? ""
            trace(
                event: "cli_result",
                subcommand: subcommand,
                arguments: arguments,
                fields: ["stdout_bytes": "\(stdout.utf8.count)"]
            )
            return TmuxCommandOutcome(stdout: stdout)
        } catch let error as AgentIPCClientError {
            trace(
                event: "cli_error",
                subcommand: subcommand,
                arguments: arguments,
                fields: ["error": error.localizedDescription]
            )
            switch error {
            case .responseError(let payload):
                tmuxCompatCLILogger.warning(
                    "tmux \(subcommand, privacy: .public) failed: \(payload.message, privacy: .public)"
                )
                // tmux prints its own errors bare (`can't find pane: %3`);
                // tools match on that text.
                return .failure(payload.message)
            default:
                tmuxCompatCLILogger.warning(
                    "tmux \(subcommand, privacy: .public) IPC failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failure("zentty tmux \(subcommand): \(error.localizedDescription)")
            }
        } catch {
            return .failure("zentty tmux \(subcommand): \(error.localizedDescription)")
        }
    }

    func expandFormat(_ format: String, target: String?) -> String? {
        var arguments = ["-p"]
        if let target {
            arguments += ["-t", target]
        }
        arguments.append(format)
        let outcome = send(subcommand: "display-message", arguments: arguments)
        guard outcome.exitCode == 0 else {
            return nil
        }
        return outcome.stdout.hasSuffix("\n") ? String(outcome.stdout.dropLast()) : outcome.stdout
    }

    func runShell(_ command: String) -> (stdout: String, exitCode: Int32) {
        let process = shellProcess(command)
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            return ("", 127)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    func runShellInBackground(_ command: String) {
        let process = shellProcess(command)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// tmux runs shell commands with `/bin/sh -c`; the shell inherits the
    /// caller's environment, so a nested `tmux` resolves to the shim again.
    private func shellProcess(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func readStandardInputIfPresent() -> String? {
        guard isatty(STDIN_FILENO) == 0 else {
            return nil
        }
        // Match the IPC server's `maxRequestBytes` so a large `set-buffer`
        // payload fails fast in the CLI rather than buffering then bouncing.
        let cap = 256 * 1024
        var collected = Data()
        let handle = FileHandle.standardInput
        while collected.count <= cap {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            collected.append(chunk)
        }
        if collected.count > cap {
            FileHandle.standardError.write(Data(
                "zentty: __tmux-compat stdin exceeds 256 KiB; truncated.\n".utf8
            ))
            collected = collected.prefix(cap)
        }
        guard !collected.isEmpty else {
            return nil
        }
        return String(data: collected, encoding: .utf8)
    }

    private func forwardedEnvironment() -> [String: String] {
        // Only the routing keys; the server resolves the target from these
        // and validates the token. We deliberately do NOT forward TMUX or
        // TMUX_PANE — they are user-controlled and the server has no need
        // to read them.
        let keys = [
            "ZENTTY_WINDOW_ID",
            "ZENTTY_WORKLANE_ID",
            "ZENTTY_PANE_ID",
            "ZENTTY_PANE_TOKEN",
            "ZENTTY_INSTANCE_ID",
            "ZENTTY_TMUX_COMPAT_TRACE_PATH",
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
    }

    private func runLocalWaitFor(arguments: [String]) -> TmuxCommandOutcome {
        let signal = arguments.contains("-S") || arguments.contains("--signal")
        let timeout = optionValue("--timeout", in: arguments).flatMap(TimeInterval.init) ?? 30
        guard let name = arguments.first(where: { !$0.hasPrefix("-") }) else {
            return .failure("zentty tmux wait-for: wait-for requires a name")
        }

        let url = waitForSignalURL(name: name)
        if signal {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return .success
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                return .success
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return .success
        }
        return .failure("zentty tmux wait-for: timed out waiting for '\(name)'")
    }

    private func optionValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func waitForSignalURL(name: String) -> URL {
        let scope = environment["ZENTTY_INSTANCE_ID"] ?? environment["ZENTTY_WORKLANE_ID"] ?? "global"
        let rawName = "\(scope)-\(name)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = rawName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return URL(fileURLWithPath: "/tmp/zentty-tmux-wait-for-\(String(sanitized)).sig")
    }

    private func trace(
        event: String,
        subcommand: String,
        arguments: [String],
        fields: [String: String] = [:]
    ) {
        guard let path = environment["ZENTTY_TMUX_COMPAT_TRACE_PATH"], !path.isEmpty else {
            return
        }

        var payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "event": event,
            "subcommand": subcommand,
            "arguments": arguments,
            "worklane_id": environment["ZENTTY_WORKLANE_ID"] ?? "",
            "pane_id": environment["ZENTTY_PANE_ID"] ?? "",
        ]
        fields.forEach { payload[$0.key] = $0.value }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: url) else {
            var line = data
            line.append(UInt8(ascii: "\n"))
            try? line.write(to: url, options: .atomic)
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }
}
