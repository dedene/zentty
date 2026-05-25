import Darwin
import Foundation

struct AgentToolLauncher {
    let tool: AgentBootstrapTool
    let arguments: [String]
    let environment: [String: String]

    func run() throws {
        trace("entry tool=\(tool) args=\(arguments)")
        var executablePath = try findRealBinary()
        trace("findRealBinary -> \(executablePath)")
        switch resolveMiseShimIfNeeded(executablePath) {
        case .success(let resolvedPath):
            trace("mise resolved -> \(resolvedPath)")
            executablePath = resolvedPath
        case .failure(let diagnostic):
            failLaunch(with: diagnostic)
        case .none:
            break
        }

        let directEnvironment = directEnvironmentPatch()

        trace("env check ZENTTY_PANE_TOKEN=\(envFlag("ZENTTY_PANE_TOKEN")) ZENTTY_WORKLANE_ID=\(envFlag("ZENTTY_WORKLANE_ID")) ZENTTY_PANE_ID=\(envFlag("ZENTTY_PANE_ID")) ZENTTY_INSTANCE_SOCKET=\(envFlag("ZENTTY_INSTANCE_SOCKET"))")
        if let reason = bootstrapSkipReason {
            trace("shouldAttemptBootstrap=false reason=\(reason); exec real binary directly (NO STATUS EMITTED)")
            try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
        }
        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"]?.nonEmpty else {
            trace("ZENTTY_INSTANCE_SOCKET missing; exec real binary directly (NO STATUS EMITTED)")
            try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
        }

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: arguments,
            standardInput: nil,
            environment: bootstrapEnvironment(realBinaryPath: executablePath),
            expectsResponse: true,
            tool: tool
        )

        do {
            trace("bootstrap IPC send socket=\(socketPath) tool=\(tool)")
            guard let response = try AgentIPCClient.send(request: request, socketPath: socketPath) else {
                trace("bootstrap IPC returned nil response; exec real binary directly (NO STATUS EMITTED)")
                try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
            }
            guard let launchPlan = response.result?.launchPlan else {
                trace("bootstrap response ok=\(response.ok) error=\(String(describing: response.error)) has no launchPlan; exec real binary directly (NO STATUS EMITTED)")
                try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
            }
            trace("bootstrap launchPlan received executable=\(launchPlan.executablePath) preLaunchActions=\(launchPlan.preLaunchActions.count)")
            try run(plan: launchPlan, socketPath: socketPath)
        } catch {
            trace("bootstrap IPC threw \(error); exec real binary directly (NO STATUS EMITTED)")
            try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard environment["ZENTTY_AGENT_WRAPPER_TRACE"] == "1" else { return }
        let line = "[zentty-launcher-trace] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func envFlag(_ key: String) -> String {
        guard let value = environment[key], !value.isEmpty else { return "UNSET" }
        return "set"
    }

    private var bootstrapSkipReason: String? {
        if environment["ZENTTY_PANE_TOKEN"]?.nonEmpty == nil {
            return "ZENTTY_PANE_TOKEN missing"
        }
        if environment["ZENTTY_WORKLANE_ID"]?.nonEmpty == nil {
            return "ZENTTY_WORKLANE_ID missing"
        }
        if environment["ZENTTY_PANE_ID"]?.nonEmpty == nil {
            return "ZENTTY_PANE_ID missing"
        }

        switch tool {
        case .amp:
            if environment["ZENTTY_AMP_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_AMP_HOOKS_DISABLED=1"
            }
            if let subcommand = arguments.first, Self.ampPassthroughSubcommands.contains(subcommand) {
                return "amp passthrough subcommand: \(subcommand)"
            }
            if let flag = arguments.first(where: Self.isAmpEarlyExitFlag) {
                return "amp early-exit flag: \(flag)"
            }
            return nil
        case .claude:
            if environment["ZENTTY_CLAUDE_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_CLAUDE_HOOKS_DISABLED=1"
            }
            let passthroughSubcommands: Set<String> = ["mcp", "config", "api-key"]
            if let subcommand = arguments.first, passthroughSubcommands.contains(subcommand) {
                return "claude passthrough subcommand: \(subcommand)"
            }
            return nil
        case .copilot:
            if environment["ZENTTY_COPILOT_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_COPILOT_HOOKS_DISABLED=1"
            }
            return nil
        case .cursor:
            if environment["ZENTTY_CURSOR_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_CURSOR_HOOKS_DISABLED=1"
            }
            return nil
        case .droid:
            if environment["ZENTTY_DROID_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_DROID_HOOKS_DISABLED=1"
            }
            return nil
        case .kimi:
            if environment["ZENTTY_KIMI_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_KIMI_HOOKS_DISABLED=1"
            }
            if let subcommand = arguments.first, Self.kimiPassthroughSubcommands.contains(subcommand) {
                return "kimi passthrough subcommand: \(subcommand)"
            }
            if let flag = arguments.first(where: { Self.kimiEarlyExitFlags.contains($0) }) {
                return "kimi early-exit flag: \(flag)"
            }
            return nil
        case .pi:
            // Pi has management subcommands (install/remove/update/list/…)
            // and early-exit flags (--help, --version, --list-models, …).
            // Injecting our bridge extension via -e at position 0 turns the
            // subcommand into a chat message, so pass these through without
            // any Zentty rewriting.
            //
            // Source of truth: `pi --help`, i.e. pi-mono's
            // packages/coding-agent/src/cli.ts. Bump the sets below if pi
            // core adds a new subcommand or early-exit flag. Pi extensions
            // cannot add shell subcommands, only slash commands / CLI flags
            // parsed after the extension loads, so only pi-core drift can
            // invalidate this list.
            if let subcommand = arguments.first, Self.piPassthroughSubcommands.contains(subcommand) {
                return "pi passthrough subcommand: \(subcommand)"
            }
            if let flag = arguments.first(where: { Self.piEarlyExitFlags.contains($0) }) {
                return "pi early-exit flag: \(flag)"
            }
            return nil
        case .grok:
            if environment["ZENTTY_GROK_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_GROK_HOOKS_DISABLED=1"
            }
            // Grok supports -p for headless/plan mode and standard --help/-v.
            // For now let the bootstrap run; the grokPlan emits a clean session.start
            // and the adapter is best-effort. Add passthrough lists later if
            // `grok login` or other management commands appear.
            return nil
        case .agy:
            if environment["ZENTTY_AGY_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_AGY_HOOKS_DISABLED=1"
            }
            if let subcommand = arguments.first, Self.agyPassthroughSubcommands.contains(subcommand) {
                return "agy passthrough subcommand: \(subcommand)"
            }
            if let flag = arguments.first(where: { Self.agyEarlyExitFlags.contains($0) }) {
                return "agy early-exit flag: \(flag)"
            }
            return nil
        case .hermes:
            if environment["ZENTTY_HERMES_HOOKS_DISABLED"] == "1" {
                return "ZENTTY_HERMES_HOOKS_DISABLED=1"
            }
            if let subcommand = arguments.first, Self.isHermesPassthroughSubcommand(subcommand) {
                return "hermes passthrough subcommand: \(subcommand)"
            }
            if let flag = arguments.first(where: { Self.hermesEarlyExitFlags.contains(Self.optionName($0)) }) {
                return "hermes early-exit flag: \(flag)"
            }
            return nil
        case .codex, .gemini, .opencode:
            return nil
        }
    }

    static let piPassthroughSubcommands: Set<String> = [
        "install", "remove", "uninstall", "update", "list", "config",
    ]

    static let piEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-v", "--list-models", "--export",
    ]

    static let ampPassthroughSubcommands: Set<String> = [
        "login", "logout", "mcp", "permission", "permissions", "review",
        "skill", "skills", "tool", "tools", "update", "up", "usage", "version",
    ]

    static let ampEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-V", "--jetbrains",
    ]

    private static func isAmpEarlyExitFlag(_ argument: String) -> Bool {
        let optionName = argument.hasPrefix("--")
            ? (argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument)
            : argument
        return ampEarlyExitFlags.contains(optionName)
    }

    static let kimiPassthroughSubcommands: Set<String> = [
        "login", "logout", "term", "acp", "info", "export", "mcp", "plugin", "vis", "web",
    ]

    static let kimiEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-V",
    ]

    static let agyPassthroughSubcommands: Set<String> = [
        "changelog", "help", "install", "login", "logout", "plugin", "plugins", "update", "version",
    ]

    static let agyEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-v",
    ]

    static let hermesEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-V", "--list-tools", "--list-toolsets",
    ]

    private static func isHermesPassthroughSubcommand(_ argument: String) -> Bool {
        !argument.hasPrefix("-") && argument != "chat"
    }

    private static func optionName(_ argument: String) -> String {
        argument.hasPrefix("--")
            ? (argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument)
            : argument
    }

    private func findRealBinary() throws -> String {
        let wrappedToolNames = tool.realBinaryNames
        let wrapperDirectories = environmentPathEntries(forKeys: [
            "ZENTTY_ALL_WRAPPER_BIN_DIRS",
            "ZENTTY_WRAPPER_BIN_DIRS",
            "ZENTTY_WRAPPER_BIN_DIR",
        ])

        let cliDirectory = environment["ZENTTY_CLI_BIN"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let excludedDirectories = Set(wrapperDirectories + [cliDirectory].compactMap { $0 })

        for entry in environmentPathEntries(forKeys: ["PATH"]) {
            guard !excludedDirectories.contains(entry) else {
                continue
            }
            for wrappedToolName in wrappedToolNames {
                let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                    .appendingPathComponent(wrappedToolName, isDirectory: false)
                    .path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        throw POSIXError(.ENOENT)
    }

    private func resolveMiseShimIfNeeded(_ executablePath: String) -> Result<String, LaunchFailureDiagnostic>? {
        guard isMiseShimPath(executablePath) else {
            return nil
        }

        let binaryName = URL(fileURLWithPath: executablePath).lastPathComponent
        let result = runMiseWhich(binaryName: binaryName)
        if result.exitCode == 0, let resolvedPath = result.stdout.nonBlankFirstLine {
            return .success(resolvedPath)
        }

        let message = result.stderr.nonBlank
            ?? result.stdout.nonBlank
            ?? "mise which \(binaryName) failed with exit code \(result.exitCode)."
        return .failure(LaunchFailureDiagnostic(message: message, exitCode: result.exitCode))
    }

    private func isMiseShimPath(_ executablePath: String) -> Bool {
        let components = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .pathComponents

        guard components.count >= 2 else {
            return false
        }

        for index in 0..<(components.count - 1) {
            if components[index] == "mise", components[index + 1] == "shims" {
                return true
            }
        }
        return false
    }

    private func runMiseWhich(binaryName: String) -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["mise", "which", binaryName]
        process.environment = environment
        process.standardInput = Pipe()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessOutput(
                exitCode: 127,
                stdout: "",
                stderr: "mise which \(binaryName) failed: \(error.localizedDescription)"
            )
        }

        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func failLaunch(with diagnostic: LaunchFailureDiagnostic) -> Never {
        let message = diagnostic.message.hasSuffix("\n")
            ? diagnostic.message
            : diagnostic.message + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        sendLaunchFailureNotification(message: diagnostic.message)
        Darwin.exit(diagnostic.exitCode == 0 ? 1 : diagnostic.exitCode)
    }

    private func sendLaunchFailureNotification(message: String) {
        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"]?.nonEmpty,
              IPCCommand.hasRequiredRoutingEnvironment(environment) else {
            return
        }

        let summary = message.nonBlankFirstLine ?? "\(toolDisplayName) failed to start."
        let request = AgentIPCRequest(
            kind: .pane,
            arguments: [
                "--title", "\(toolDisplayName) failed to start",
                "--subtitle", summary,
                "--body", message,
            ],
            standardInput: nil,
            environment: IPCCommand.forwardedEnvironment(from: environment),
            expectsResponse: false,
            subcommand: "notify"
        )
        _ = try? AgentIPCClient.send(request: request, socketPath: socketPath)
    }

    private var toolDisplayName: String {
        switch tool {
        case .amp:
            return "Amp"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .droid:
            return "Droid"
        case .gemini:
            return "Gemini"
        case .kimi:
            return "Kimi"
        case .opencode:
            return "OpenCode"
        case .pi:
            return "Pi"
        case .grok:
            return "Grok"
        case .agy:
            return "Antigravity"
        case .hermes:
            return "Hermes Agent"
        }
    }

    private func bootstrapEnvironment(realBinaryPath: String) -> [String: String] {
        let forwardedKeys = [
            "HOME",
            "PWD",
            "PATH",
            "AMP_SETTINGS_FILE",
            "ZENTTY_CLI_BIN",
            "ZENTTY_INSTANCE_SOCKET",
            "ZENTTY_WINDOW_ID",
            "ZENTTY_WORKLANE_ID",
            "ZENTTY_PANE_ID",
            "ZENTTY_PANE_TOKEN",
            "ZENTTY_INSTANCE_ID",
            "ZENTTY_AMP_HOOKS_DISABLED",
            "ZENTTY_CLAUDE_HOOKS_DISABLED",
            "ZENTTY_COPILOT_HOOKS_DISABLED",
            "ZENTTY_CURSOR_HOOKS_DISABLED",
            "ZENTTY_CURSOR_VERBOSE_HOOKS",
            "ZENTTY_DROID_HOOKS_DISABLED",
            "ZENTTY_KIMI_HOOKS_DISABLED",
            "ZENTTY_GROK_HOOKS_DISABLED",
            "ZENTTY_AGY_HOOKS_DISABLED",
            "ZENTTY_HERMES_HOOKS_DISABLED",
            "ZENTTY_CODEX_NOTIFY_DISABLED",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
            "CODEX_HOME",
            "COPILOT_HOME",
            "HERMES_HOME",
            "XDG_CONFIG_HOME",
            "XDG_STATE_HOME",
            "OPENCODE_CONFIG",
            "OPENCODE_CONFIG_DIR",
            "OPENCODE_TUI_CONFIG",
            "ZENTTY_OPENCODE_BASE_CONFIG_DIR",
        ]

        var forwarded = [String: String](uniqueKeysWithValues: forwardedKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
        if let cliPath = resolvedCLIPath() {
            forwarded["ZENTTY_CLI_BIN"] = cliPath
        }
        forwarded["ZENTTY_REAL_BINARY"] = realBinaryPath
        return forwarded
    }

    private func resolvedCLIPath() -> String? {
        if let configuredPath = environment["ZENTTY_CLI_BIN"]?.nonEmpty,
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            return CommandLine.arguments.first?.nonEmpty
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else {
            return CommandLine.arguments.first?.nonEmpty
        }

        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func directEnvironmentPatch() -> EnvironmentPatch {
        switch tool {
        case .claude:
            return EnvironmentPatch(set: [:], unset: ["CLAUDECODE"])
        case .amp, .codex, .copilot, .cursor, .droid, .gemini, .kimi, .opencode, .pi, .grok, .agy, .hermes:
            return EnvironmentPatch()
        }
    }

    private func run(plan: AgentLaunchPlan, socketPath: String) throws {
        var environmentPatch = EnvironmentPatch(
            set: plan.setEnvironment,
            unset: plan.unsetEnvironment
        )

        switch tool {
        case .amp:
            environmentPatch.set["ZENTTY_AMP_PID"] = "\(getpid())"
        case .claude:
            environmentPatch.set["ZENTTY_CLAUDE_PID"] = "\(getpid())"
        case .codex:
            environmentPatch.set["ZENTTY_CODEX_PID"] = "\(getpid())"
        case .copilot:
            environmentPatch.set["ZENTTY_COPILOT_PID"] = "\(getpid())"
        case .gemini:
            environmentPatch.set["ZENTTY_GEMINI_PID"] = "\(getpid())"
        case .cursor:
            environmentPatch.set["ZENTTY_CURSOR_PID"] = "\(getpid())"
        case .droid:
            environmentPatch.set["ZENTTY_DROID_PID"] = "\(getpid())"
        case .kimi:
            environmentPatch.set["ZENTTY_KIMI_PID"] = "\(getpid())"
        case .grok:
            environmentPatch.set["ZENTTY_GROK_PID"] = "\(getpid())"
        case .agy:
            environmentPatch.set["ZENTTY_AGY_PID"] = "\(getpid())"
        case .hermes:
            environmentPatch.set["ZENTTY_HERMES_PID"] = "\(getpid())"
        case .opencode, .pi:
            break
        }

        try runPreLaunchActions(plan.preLaunchActions, socketPath: socketPath, environmentPatch: environmentPatch)
        try exec(executablePath: plan.executablePath, arguments: plan.arguments, environmentPatch: environmentPatch)
    }

    private func runPreLaunchActions(
        _ actions: [AgentLaunchAction],
        socketPath: String,
        environmentPatch: EnvironmentPatch
    ) throws {
        guard !actions.isEmpty else {
            trace("runPreLaunchActions: no actions to send")
            return
        }

        let actionEnvironment = mergedEnvironment(with: environmentPatch)
        for (index, action) in actions.enumerated() {
            let request = AgentIPCRequest(
                kind: .ipc,
                arguments: action.arguments,
                standardInput: action.standardInput?.replacingOccurrences(
                    of: AgentIPCProtocol.selfPIDPlaceholder,
                    with: "\(getpid())"
                ),
                environment: bootstrapActionEnvironment(from: actionEnvironment),
                expectsResponse: false,
                subcommand: action.subcommand
            )
            trace("preLaunchAction[\(index)] sending subcommand=\(action.subcommand) args=\(action.arguments) hasStdin=\(action.standardInput != nil)")
            do {
                _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
                trace("preLaunchAction[\(index)] sent OK")
            } catch {
                trace("preLaunchAction[\(index)] FAILED \(error) (suppressed in normal operation)")
            }
        }
    }

    private func bootstrapActionEnvironment(from environment: [String: String]) -> [String: String] {
        let keys = [
            "ZENTTY_WINDOW_ID",
            "ZENTTY_WORKLANE_ID",
            "ZENTTY_PANE_ID",
            "ZENTTY_PANE_TOKEN",
            "ZENTTY_AMP_PID",
            "ZENTTY_CLAUDE_PID",
            "ZENTTY_CODEX_PID",
            "ZENTTY_COPILOT_PID",
            "ZENTTY_GEMINI_PID",
            "ZENTTY_CURSOR_PID",
            "ZENTTY_DROID_PID",
            "ZENTTY_KIMI_PID",
            "ZENTTY_GROK_PID",
            "ZENTTY_AGY_PID",
            "ZENTTY_HERMES_PID",
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
    }

    private func exec(
        executablePath: String,
        arguments: [String],
        environmentPatch: EnvironmentPatch
    ) throws -> Never {
        let nextEnvironment = mergedEnvironment(with: environmentPatch)
        var argv = ([executablePath] + arguments).map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var envp = nextEnvironment
            .map { key, value in strdup("\(key)=\(value)") }
        envp.append(nil)
        defer {
            for pointer in envp where pointer != nil {
                free(pointer)
            }
        }

        execve(executablePath, &argv, &envp)
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    private func mergedEnvironment(with patch: EnvironmentPatch) -> [String: String] {
        var merged = environment
        for key in patch.unset {
            merged.removeValue(forKey: key)
        }
        for (key, value) in patch.set {
            merged[key] = value
        }
        return merged
    }

    private func environmentPathEntries(forKeys keys: [String]) -> [String] {
        for key in keys {
            guard let value = environment[key], !value.isEmpty else {
                continue
            }
            return value.split(separator: ":").map(String.init)
        }
        return []
    }
}

private struct EnvironmentPatch {
    var set: [String: String] = [:]
    var unset: [String] = []
}

private struct LaunchFailureDiagnostic: Error {
    let message: String
    let exitCode: Int32
}

private struct ProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonBlankFirstLine: String? {
        split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(\.nonBlank)
            .first
    }
}
