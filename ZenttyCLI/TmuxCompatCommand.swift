import ArgumentParser
import Darwin
import Foundation
import os

private let tmuxCompatCLILogger = Logger(subsystem: "be.zenjoy.zentty", category: "tmux-compat-cli")

/// Hidden subcommand the bundled `tmux-shim/tmux` script re-execs into.
/// Forwards the tmux subcommand and its arguments to the running Zentty
/// instance via `AgentIPCRequest(kind: .tmuxCompat, ...)` and prints the
/// returned `stdout` to stdout, exiting with `exitCode`.
///
/// Hidden because users never invoke this directly — it's only meant to be
/// reachable through the bundled shim, which Claude Code's agent-teams mode
/// resolves as `tmux` on PATH when the toggle is enabled.
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
        guard let invocation = Self.parseTmuxInvocation(rawArguments) else {
            FileHandle.standardError.write(Data(
                "zentty: __tmux-compat requires a tmux subcommand\n".utf8
            ))
            throw ExitCode(1)
        }
        let localSubcommand = invocation.subcommand
        let localArguments = invocation.arguments
        trace(
            event: "cli_start",
            subcommand: localSubcommand,
            arguments: localArguments,
            environment: environment
        )
        if localSubcommand == "wait-for" || localSubcommand == "wait" {
            try runLocalWaitFor(arguments: localArguments, environment: environment)
            trace(
                event: "cli_wait_for_done",
                subcommand: localSubcommand,
                arguments: localArguments,
                environment: environment
            )
            return
        }

        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            FileHandle.standardError.write(Data(
                "zentty: __tmux-compat must be invoked from inside a Zentty pane (ZENTTY_INSTANCE_SOCKET unset)\n".utf8
            ))
            throw ExitCode(1)
        }
        guard IPCCommand.hasRequiredRoutingEnvironment(environment) else {
            let missing = IPCCommand.missingRoutingEnvironmentKeys(environment).joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "zentty: __tmux-compat missing routing env: \(missing)\n".utf8
            ))
            throw ExitCode(1)
        }

        let stdinPayload = Self.subcommandReadsStandardInput(localSubcommand)
            ? readStandardInputIfPresent()
            : nil

        let request = AgentIPCRequest(
            kind: .tmuxCompat,
            arguments: localArguments,
            standardInput: stdinPayload,
            environment: forwardedEnvironment(from: environment),
            expectsResponse: true,
            subcommand: localSubcommand
        )

        do {
            let response = try AgentIPCClient.send(request: request, socketPath: socketPath)
            if let stdout = response?.result?.stdout, !stdout.isEmpty {
                FileHandle.standardOutput.write(Data(stdout.utf8))
            }
            trace(
                event: "cli_result",
                subcommand: localSubcommand,
                arguments: localArguments,
                environment: environment,
                fields: ["stdout_bytes": "\(response?.result?.stdout?.utf8.count ?? 0)"]
            )
        } catch let error as AgentIPCClientError {
            trace(
                event: "cli_error",
                subcommand: localSubcommand,
                arguments: localArguments,
                environment: environment,
                fields: ["error": error.localizedDescription]
            )
            switch error {
            case .responseError(let payload):
                tmuxCompatCLILogger.warning(
                    "tmux \(localSubcommand, privacy: .public) failed: \(payload.message, privacy: .public)"
                )
                FileHandle.standardError.write(Data(
                    "zentty tmux \(localSubcommand): \(payload.message)\n".utf8
                ))
                throw ExitCode(1)
            default:
                tmuxCompatCLILogger.warning(
                    "tmux \(localSubcommand, privacy: .public) IPC failed: \(error.localizedDescription, privacy: .public)"
                )
                throw ExitCode(1)
            }
        }
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

    /// Strip tmux's global options that appear before the subcommand. Real
    /// tmux accepts e.g. `-S socket-path`, `-L socket-name`, `-f config`,
    /// `-c shell-command`, `-T features` ahead of the subcommand; we ignore
    /// them because routing happens via `ZENTTY_INSTANCE_SOCKET`. Claude Code
    /// 2.1.128 prefixes `-S <socket-from-$TMUX>` onto every call, which
    /// previously crashed ArgumentParser before any handler ran.
    static func parseTmuxInvocation(
        _ arguments: [String]
    ) -> (subcommand: String, arguments: [String])? {
        let valueGlobals: Set<String> = ["-S", "-L", "-T", "-f", "-c"]
        let boolGlobals: Set<String> = [
            "-2", "-C", "-CC", "-D", "-d", "-l", "-N", "-P", "-q", "-u", "-U", "-v", "-V",
        ]

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueGlobals.contains(argument) {
                index += (index + 1 < arguments.count) ? 2 : 1
                continue
            }
            if boolGlobals.contains(argument) {
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
        switch subcommand.lowercased() {
        case "load-buffer", "loadb", "set-buffer", "setb":
            return true
        default:
            return false
        }
    }

    private func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
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

    private func runLocalWaitFor(arguments: [String], environment: [String: String]) throws {
        let signal = arguments.contains("-S") || arguments.contains("--signal")
        let timeout = optionValue("--timeout", in: arguments).flatMap(TimeInterval.init) ?? 30
        guard let name = arguments.first(where: { !$0.hasPrefix("-") }) else {
            FileHandle.standardError.write(Data("zentty tmux wait-for: wait-for requires a name\n".utf8))
            throw ExitCode(1)
        }

        let url = waitForSignalURL(name: name, environment: environment)
        if signal {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return
        }

        FileHandle.standardError.write(Data("zentty tmux wait-for: timed out waiting for '\(name)'\n".utf8))
        throw ExitCode(1)
    }

    private func optionValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func waitForSignalURL(name: String, environment: [String: String]) -> URL {
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
        environment: [String: String],
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
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }
}
