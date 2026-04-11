import Darwin
import Foundation

struct AgentToolLauncher {
    let tool: AgentBootstrapTool
    let arguments: [String]
    let environment: [String: String]

    func run() throws {
        let executablePath = try findRealBinary()
        let directEnvironment = directEnvironmentPatch()

        guard shouldAttemptBootstrap,
              let socketPath = environment["ZENTTY_INSTANCE_SOCKET"]?.nonEmpty else {
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
            guard let response = try AgentIPCClient.send(request: request, socketPath: socketPath),
                  let launchPlan = response.result?.launchPlan else {
                try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
            }
            try run(plan: launchPlan, socketPath: socketPath)
        } catch {
            try exec(executablePath: executablePath, arguments: arguments, environmentPatch: directEnvironment)
        }
    }

    private var shouldAttemptBootstrap: Bool {
        guard environment["ZENTTY_PANE_TOKEN"]?.nonEmpty != nil,
              environment["ZENTTY_WORKLANE_ID"]?.nonEmpty != nil,
              environment["ZENTTY_PANE_ID"]?.nonEmpty != nil else {
            return false
        }

        switch tool {
        case .claude:
            if environment["ZENTTY_CLAUDE_HOOKS_DISABLED"] == "1" {
                return false
            }
            let passthroughSubcommands: Set<String> = ["mcp", "config", "api-key"]
            return !passthroughSubcommands.contains(arguments.first ?? "")
        case .copilot:
            return environment["ZENTTY_COPILOT_HOOKS_DISABLED"] != "1"
        case .codex, .gemini, .opencode:
            return true
        }
    }

    private func findRealBinary() throws -> String {
        let wrappedToolName = tool.rawValue
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
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(wrappedToolName, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw POSIXError(.ENOENT)
    }

    private func bootstrapEnvironment(realBinaryPath: String) -> [String: String] {
        let forwardedKeys = [
            "HOME",
            "PATH",
            "ZENTTY_CLI_BIN",
            "ZENTTY_INSTANCE_SOCKET",
            "ZENTTY_WINDOW_ID",
            "ZENTTY_WORKLANE_ID",
            "ZENTTY_PANE_ID",
            "ZENTTY_PANE_TOKEN",
            "ZENTTY_CLAUDE_HOOKS_DISABLED",
            "ZENTTY_COPILOT_HOOKS_DISABLED",
            "ZENTTY_CODEX_NOTIFY_DISABLED",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
            "CODEX_HOME",
            "COPILOT_HOME",
            "OPENCODE_CONFIG_DIR",
            "ZENTTY_OPENCODE_BASE_CONFIG_DIR",
        ]

        var forwarded = [String: String](uniqueKeysWithValues: forwardedKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
        forwarded["ZENTTY_REAL_BINARY"] = realBinaryPath
        return forwarded
    }

    private func directEnvironmentPatch() -> EnvironmentPatch {
        switch tool {
        case .claude:
            return EnvironmentPatch(set: [:], unset: ["CLAUDECODE"])
        case .codex, .copilot, .gemini, .opencode:
            return EnvironmentPatch()
        }
    }

    private func run(plan: AgentLaunchPlan, socketPath: String) throws {
        var environmentPatch = EnvironmentPatch(
            set: plan.setEnvironment,
            unset: plan.unsetEnvironment
        )

        switch tool {
        case .claude:
            environmentPatch.set["ZENTTY_CLAUDE_PID"] = "\(getpid())"
        case .codex:
            environmentPatch.set["ZENTTY_CODEX_PID"] = "\(getpid())"
        case .copilot:
            environmentPatch.set["ZENTTY_COPILOT_PID"] = "\(getpid())"
        case .gemini:
            environmentPatch.set["ZENTTY_GEMINI_PID"] = "\(getpid())"
        case .opencode:
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
            return
        }

        let actionEnvironment = mergedEnvironment(with: environmentPatch)
        for action in actions {
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
            _ = try? AgentIPCClient.send(request: request, socketPath: socketPath)
        }
    }

    private func bootstrapActionEnvironment(from environment: [String: String]) -> [String: String] {
        let keys = [
            "ZENTTY_WINDOW_ID",
            "ZENTTY_WORKLANE_ID",
            "ZENTTY_PANE_ID",
            "ZENTTY_PANE_TOKEN",
            "ZENTTY_CLAUDE_PID",
            "ZENTTY_CODEX_PID",
            "ZENTTY_COPILOT_PID",
            "ZENTTY_GEMINI_PID",
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

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
