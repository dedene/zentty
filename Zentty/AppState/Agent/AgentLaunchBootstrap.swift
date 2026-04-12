import Foundation

enum AgentLaunchBootstrap {
    static func makePlan(
        request: AgentIPCRequest,
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> AgentLaunchPlan {
        guard request.version == AgentIPCProtocol.version else {
            throw AgentIPCError.invalidMessage
        }
        guard let tool = request.tool else {
            throw AgentIPCError.invalidMessage
        }

        let environment = request.environment
        guard let executablePath = environment["ZENTTY_REAL_BINARY"]?.nilIfBlank else {
            throw AgentIPCError.invalidMessage
        }

        switch tool {
        case .claude:
            return try claudePlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment
            )
        case .codex:
            return try codexPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        case .copilot:
            return try copilotPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        case .gemini:
            return try geminiPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        case .opencode:
            return try opencodePlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                bundle: bundle,
                fileManager: fileManager
            )
        }
    }

    private static func claudePlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> AgentLaunchPlan {
        let passthroughCommands: Set<String> = ["mcp", "config", "api-key"]
        if environment["ZENTTY_CLAUDE_HOOKS_DISABLED"] == "1"
            || passthroughCommands.contains(arguments.first ?? "") {
            return directPlan(
                executablePath: executablePath,
                arguments: arguments,
                unsetEnvironment: ["CLAUDECODE"]
            )
        }

        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return directPlan(
                executablePath: executablePath,
                arguments: arguments,
                unsetEnvironment: ["CLAUDECODE"]
            )
        }

        let hookCommand = "\"\(shellEscapedDoubleQuoted(cliPath))\" ipc agent-event --adapter=claude"
        let settingsJSON = try compactJSONString([
            "hooks": [
                "SessionStart": claudeHookEntries(command: hookCommand, timeout: 10),
                "Stop": claudeHookEntries(command: hookCommand, timeout: 10),
                "SessionEnd": claudeHookEntries(command: hookCommand, timeout: 1),
                "Notification": claudeHookEntries(command: hookCommand, timeout: 10),
                "PermissionRequest": claudeHookEntries(command: hookCommand, timeout: 10),
                "UserPromptSubmit": claudeHookEntries(command: hookCommand, timeout: 10),
                "PreToolUse": [[
                    "matcher": "AskUserQuestion",
                    "hooks": [[
                        "type": "command",
                        "command": hookCommand,
                        "timeout": 5,
                    ]],
                ]],
                "TaskCreated": claudeHookEntries(command: hookCommand, timeout: 5),
                "TaskCompleted": claudeHookEntries(command: hookCommand, timeout: 5),
            ],
        ])

        var plannedArguments = arguments
        let shouldReuseSession = arguments.contains { argument in
            switch argument {
            case "--resume", "--continue", "-c":
                return true
            default:
                return argument.hasPrefix("--resume=") || argument.hasPrefix("--session-id=") || argument == "--session-id"
            }
        }

        if shouldReuseSession {
            plannedArguments.insert(contentsOf: ["--settings", settingsJSON], at: 0)
        } else {
            plannedArguments.insert(contentsOf: ["--session-id", UUID().uuidString.lowercased(), "--settings", settingsJSON], at: 0)
        }

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: plannedArguments,
            setEnvironment: [
                "ZENTTY_AGENT_TOOL": "claude",
            ],
            unsetEnvironment: ["CLAUDECODE"],
            preLaunchActions: []
        )
    }

    private static func codexPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        var setEnvironment = ["ZENTTY_AGENT_TOOL": "codex"]
        let overlayDirectoryURL = try prepareToolDirectory(
            tool: .codex,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL,
            fileManager: fileManager
        )

        let sourceHomeURL = URL(fileURLWithPath: environment["CODEX_HOME"]?.nilIfBlank ?? "\(environment["HOME"] ?? NSHomeDirectory())/.codex", isDirectory: true)
        if let overlayHomePath = try prepareCodexOverlay(
            sourceHomeURL: sourceHomeURL,
            overlayDirectoryURL: overlayDirectoryURL,
            cliPath: cliPath,
            fileManager: fileManager
        ) {
            setEnvironment["CODEX_HOME"] = overlayHomePath
        }

        var plannedArguments = arguments
        plannedArguments.insert(contentsOf: [
            "-c", "features.codex_hooks=true",
            "-c", "tui.notification_method=osc9",
            "-c", #"tui.terminal_title=["status","spinner","project","task-progress"]"#,
        ], at: 0)

        if environment["ZENTTY_CODEX_NOTIFY_DISABLED"] != "1",
           !hasCodexNotifyOverride(arguments) {
            let notifyValue = tomlStringArrayLiteral([cliPath, "codex-notify"])
            plannedArguments.insert(contentsOf: ["-c", "notify=\(notifyValue)"], at: 0)
        }

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: plannedArguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    private static func copilotPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_COPILOT_HOOKS_DISABLED"] == "1" {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        let extracted = extractCopilotConfigDirOverride(arguments)
        var setEnvironment = ["ZENTTY_AGENT_TOOL": "copilot"]

        let overlayDirectoryURL = try prepareToolDirectory(
            tool: .copilot,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL,
            fileManager: fileManager
        )
        let sourceHomePath = extracted.sourceConfigDirectory
            ?? environment["COPILOT_HOME"]?.nilIfBlank
            ?? "\(environment["HOME"] ?? NSHomeDirectory())/.copilot"
        if let overlayHomePath = try prepareCopilotOverlay(
            sourceHomeURL: URL(fileURLWithPath: sourceHomePath, isDirectory: true),
            overlayDirectoryURL: overlayDirectoryURL,
            cliPath: cliPath,
            fileManager: fileManager
        ) {
            setEnvironment["COPILOT_HOME"] = overlayHomePath
        }

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: extracted.forwardedArguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    private static func geminiPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return AgentLaunchPlan(
                executablePath: executablePath,
                arguments: arguments,
                setEnvironment: ["ZENTTY_AGENT_TOOL": "gemini"],
                unsetEnvironment: [],
                preLaunchActions: []
            )
        }

        var setEnvironment = ["ZENTTY_AGENT_TOOL": "gemini"]
        let overlayDirectoryURL = try prepareToolDirectory(
            tool: .gemini,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL,
            fileManager: fileManager
        )
        if let overlaySettingsPath = try prepareGeminiOverlay(
            sourceSettingsURL: geminiSystemSettingsSourceURL(environment: environment, fileManager: fileManager),
            overlayDirectoryURL: overlayDirectoryURL,
            cliPath: cliPath,
            fileManager: fileManager
        ) {
            setEnvironment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = overlaySettingsPath
        }

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    private static func opencodePlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        bundle: Bundle,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        var setEnvironment = ["ZENTTY_AGENT_TOOL": "opencode"]
        let sourceConfigPath = environment["ZENTTY_OPENCODE_BASE_CONFIG_DIR"]?.nilIfBlank
            ?? environment["OPENCODE_CONFIG_DIR"]?.nilIfBlank
            ?? ""
        setEnvironment["ZENTTY_OPENCODE_BASE_CONFIG_DIR"] = sourceConfigPath

        if let pluginURL = bundle.resourceURL?
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
           fileManager.isReadableFile(atPath: pluginURL.path) {
            let overlayDirectoryURL = try prepareToolDirectory(
                tool: .opencode,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
            let overlayConfigURL = overlayDirectoryURL.appendingPathComponent("config", isDirectory: true)
            try fileManager.createDirectory(at: overlayConfigURL, withIntermediateDirectories: true)
            if let sourceConfigPath = sourceConfigPath.nilIfBlank,
               fileManager.fileExists(atPath: sourceConfigPath) {
                try copyDirectoryContents(
                    from: URL(fileURLWithPath: sourceConfigPath, isDirectory: true),
                    to: overlayConfigURL,
                    fileManager: fileManager
                )
            }
            let pluginsURL = overlayConfigURL.appendingPathComponent("plugins", isDirectory: true)
            try fileManager.createDirectory(at: pluginsURL, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: pluginsURL.appendingPathComponent(pluginURL.lastPathComponent, isDirectory: false))
            try fileManager.copyItem(
                at: pluginURL,
                to: pluginsURL.appendingPathComponent(pluginURL.lastPathComponent, isDirectory: false)
            )
            setEnvironment["OPENCODE_CONFIG_DIR"] = overlayConfigURL.path
        }

        let sessionStartJSON = """
        {"version":1,"event":"session.start","agent":{"name":"OpenCode","pid":\(AgentIPCProtocol.selfPIDPlaceholder)}}
        """
        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: [
                AgentLaunchAction(
                    subcommand: "agent-event",
                    arguments: [],
                    standardInput: sessionStartJSON
                ),
            ]
        )
    }

    private static func prepareCodexOverlay(
        sourceHomeURL: URL,
        overlayDirectoryURL: URL,
        cliPath: String,
        fileManager: FileManager
    ) throws -> String? {
        let overlayHomeURL = overlayDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: overlayHomeURL, withIntermediateDirectories: true)
        try symlinkDirectoryContentsSkipping(
            from: sourceHomeURL,
            to: overlayHomeURL,
            skippingNames: ["hooks.json"],
            fileManager: fileManager
        )

        let overlayHooksURL = overlayHomeURL.appendingPathComponent("hooks.json", isDirectory: false)
        let sourceHooksURL = sourceHomeURL.appendingPathComponent("hooks.json", isDirectory: false)
        if fileManager.fileExists(atPath: sourceHooksURL.path) {
            let rawData = try Data(contentsOf: sourceHooksURL)
            if let mergedData = try codexMergedHooksJSON(existingData: rawData, cliPath: cliPath) {
                try mergedData.write(to: overlayHooksURL, options: .atomic)
            } else {
                try rawData.write(to: overlayHooksURL, options: .atomic)
            }
        } else {
            try codexBaseHooksJSON(cliPath: cliPath).write(to: overlayHooksURL, options: .atomic)
        }

        return overlayHomeURL.path
    }

    private static func prepareCopilotOverlay(
        sourceHomeURL: URL,
        overlayDirectoryURL: URL,
        cliPath: String,
        fileManager: FileManager
    ) throws -> String? {
        let overlayHomeURL = overlayDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: overlayHomeURL, withIntermediateDirectories: true)
        try symlinkDirectoryContentsSkipping(
            from: sourceHomeURL,
            to: overlayHomeURL,
            skippingNames: ["config.json"],
            fileManager: fileManager
        )

        let overlayConfigURL = overlayHomeURL.appendingPathComponent("config.json", isDirectory: false)
        let sourceConfigURL = sourceHomeURL.appendingPathComponent("config.json", isDirectory: false)
        if fileManager.fileExists(atPath: sourceConfigURL.path) {
            let rawData = try Data(contentsOf: sourceConfigURL)
            if let mergedData = try copilotMergedConfigJSON(existingData: rawData, cliPath: cliPath) {
                try mergedData.write(to: overlayConfigURL, options: .atomic)
            } else {
                try rawData.write(to: overlayConfigURL, options: .atomic)
            }
        } else {
            try copilotBaseConfigJSON(cliPath: cliPath).write(to: overlayConfigURL, options: .atomic)
        }

        return overlayHomeURL.path
    }

    private static func prepareGeminiOverlay(
        sourceSettingsURL: URL?,
        overlayDirectoryURL: URL,
        cliPath: String,
        fileManager: FileManager
    ) throws -> String? {
        let overlaySettingsURL = overlayDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        if let sourceSettingsURL, fileManager.isReadableFile(atPath: sourceSettingsURL.path) {
            let rawData = try Data(contentsOf: sourceSettingsURL)
            if let mergedData = try geminiMergedSettingsJSON(existingData: rawData, cliPath: cliPath) {
                try mergedData.write(to: overlaySettingsURL, options: .atomic)
            } else {
                try geminiBaseSettingsJSON(cliPath: cliPath).write(to: overlaySettingsURL, options: .atomic)
            }
        } else {
            try geminiBaseSettingsJSON(cliPath: cliPath).write(to: overlaySettingsURL, options: .atomic)
        }

        return overlaySettingsURL.path
    }

    private static func prepareToolDirectory(
        tool: AgentBootstrapTool,
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let launchesURL = runtimeDirectoryURL.appendingPathComponent("launch", isDirectory: true)
        try fileManager.createDirectory(at: launchesURL, withIntermediateDirectories: true)

        let paneURL = launchesURL
            .appendingPathComponent(target.worklaneID.rawValue, isDirectory: true)
            .appendingPathComponent(target.paneID.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: paneURL, withIntermediateDirectories: true)

        let toolURL = paneURL.appendingPathComponent(tool.rawValue, isDirectory: true)
        if fileManager.fileExists(atPath: toolURL.path) {
            try fileManager.removeItem(at: toolURL)
        }
        try fileManager.createDirectory(at: toolURL, withIntermediateDirectories: true)
        return toolURL
    }

    private static func codexBaseHooksJSON(cliPath: String) throws -> Data {
        let commands = [
            "SessionStart": codexHookCommand(cliPath: cliPath, event: "session-start"),
            "PreToolUse": codexHookCommand(cliPath: cliPath, event: "pre-tool-use"),
            "PostToolUse": codexHookCommand(cliPath: cliPath, event: "post-tool-use"),
            "UserPromptSubmit": codexHookCommand(cliPath: cliPath, event: "prompt-submit"),
            "Stop": codexHookCommand(cliPath: cliPath, event: "stop"),
        ]
        let hooks = Dictionary(uniqueKeysWithValues: commands.map { key, command in
            (key, [[
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 10,
                ]],
            ]])
        })
        return try compactJSONData(["hooks": hooks])
    }

    private static func codexMergedHooksJSON(existingData: Data, cliPath: String) throws -> Data? {
        guard var jsonObject = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return nil
        }
        let commands = [
            ("SessionStart", codexHookCommand(cliPath: cliPath, event: "session-start")),
            ("PreToolUse", codexHookCommand(cliPath: cliPath, event: "pre-tool-use")),
            ("PostToolUse", codexHookCommand(cliPath: cliPath, event: "post-tool-use")),
            ("UserPromptSubmit", codexHookCommand(cliPath: cliPath, event: "prompt-submit")),
            ("Stop", codexHookCommand(cliPath: cliPath, event: "stop")),
        ]

        guard var hooks = jsonObject["hooks"] as? [String: Any] else {
            return try compactJSONData(jsonObject)
        }
        for (eventName, command) in commands {
            var entries = hooks[eventName] as? [[String: Any]] ?? []
            let alreadyPresent = entries.contains { entry in
                let nestedHooks = entry["hooks"] as? [[String: Any]] ?? []
                return nestedHooks.contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }
            }
            if !alreadyPresent {
                entries.append([
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": 10,
                    ]],
                ])
            }
            hooks[eventName] = entries
        }
        jsonObject["hooks"] = hooks
        return try compactJSONData(jsonObject)
    }

    private static func copilotBaseConfigJSON(cliPath: String) throws -> Data {
        let hooks: [String: Any] = [
            "sessionStart": [copilotHookEntry(cliPath: cliPath, event: "session-start", timeout: 10)],
            "sessionEnd": [copilotHookEntry(cliPath: cliPath, event: "session-end", timeout: 10)],
            "userPromptSubmitted": [copilotHookEntry(cliPath: cliPath, event: "user-prompt-submitted", timeout: 10)],
            "preToolUse": [copilotHookEntry(cliPath: cliPath, event: "pre-tool-use", timeout: 5)],
            "postToolUse": [copilotHookEntry(cliPath: cliPath, event: "post-tool-use", timeout: 5)],
            "errorOccurred": [copilotHookEntry(cliPath: cliPath, event: "error-occurred", timeout: 10)],
        ]
        return try compactJSONData([
            "version": 1,
            "hooks": hooks,
        ])
    }

    private static func copilotMergedConfigJSON(existingData: Data, cliPath: String) throws -> Data? {
        guard let uncommentedData = stripJSONCComments(in: existingData),
              let cleanedData = stripTrailingCommas(in: uncommentedData),
              var jsonObject = try JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] else {
            return nil
        }

        jsonObject["version"] = 1
        guard var hooks = jsonObject["hooks"] as? [String: Any] else {
            return try compactJSONData(jsonObject)
        }

        let entries: [(String, String, Int)] = [
            ("sessionStart", "session-start", 10),
            ("sessionEnd", "session-end", 10),
            ("userPromptSubmitted", "user-prompt-submitted", 10),
            ("preToolUse", "pre-tool-use", 5),
            ("postToolUse", "post-tool-use", 5),
            ("errorOccurred", "error-occurred", 10),
        ]

        for (eventName, eventArgument, timeout) in entries {
            let command = copilotHookCommand(cliPath: cliPath, event: eventArgument)
            var eventEntries = hooks[eventName] as? [[String: Any]] ?? []
            let alreadyPresent = eventEntries.contains {
                ($0["type"] as? String) == "command" && ($0["bash"] as? String) == command
            }
            if !alreadyPresent {
                eventEntries.append([
                    "type": "command",
                    "bash": command,
                    "timeoutSec": timeout,
                ])
            }
            hooks[eventName] = eventEntries
        }

        jsonObject["hooks"] = hooks
        return try compactJSONData(jsonObject)
    }

    private static func geminiSystemSettingsSourceURL(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        if let overridePath = environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"]?.nilIfBlank {
            let overrideURL = URL(fileURLWithPath: overridePath, isDirectory: false)
            if fileManager.isReadableFile(atPath: overrideURL.path) {
                return overrideURL
            }
        }

        let defaultURL = URL(
            fileURLWithPath: "/Library/Application Support/GeminiCli/settings.json",
            isDirectory: false
        )
        return fileManager.isReadableFile(atPath: defaultURL.path) ? defaultURL : nil
    }

    private static func geminiBaseSettingsJSON(cliPath: String) throws -> Data {
        try compactJSONData([
            "general": [
                "enableNotifications": true,
            ],
            "hooks": geminiHookGroupsJSON(cliPath: cliPath),
        ])
    }

    private static func geminiMergedSettingsJSON(existingData: Data, cliPath: String) throws -> Data? {
        guard var jsonObject = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return nil
        }

        var general = jsonObject["general"] as? [String: Any] ?? [:]
        general["enableNotifications"] = true
        jsonObject["general"] = general

        var hooks = jsonObject["hooks"] as? [String: Any] ?? [:]
        for (eventName, matcher, timeout) in geminiHookSpecs {
            let command = geminiHookCommand(cliPath: cliPath)
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            let alreadyPresent = groups.contains { group in
                let nestedHooks = group["hooks"] as? [[String: Any]] ?? []
                return nestedHooks.contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }
            }
            if !alreadyPresent {
                groups.append(geminiHookGroup(matcher: matcher, command: command, timeout: timeout))
            }
            hooks[eventName] = groups
        }
        jsonObject["hooks"] = hooks

        return try compactJSONData(jsonObject)
    }

    private static func extractCopilotConfigDirOverride(_ arguments: [String]) -> (forwardedArguments: [String], sourceConfigDirectory: String?) {
        var forwarded: [String] = []
        var sourceConfigDirectory: String?
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--config-dir":
                if let value = iterator.next() {
                    sourceConfigDirectory = value
                } else {
                    forwarded.append(argument)
                }
            case let value where value.hasPrefix("--config-dir="):
                sourceConfigDirectory = String(value.dropFirst("--config-dir=".count))
            default:
                forwarded.append(argument)
            }
        }

        return (forwarded, sourceConfigDirectory)
    }

    private static func hasCodexNotifyOverride(_ arguments: [String]) -> Bool {
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "-c", "--config":
                guard let value = iterator.next() else {
                    continue
                }
                if value.hasPrefix("notify=") {
                    return true
                }
            case let value where value.hasPrefix("-cnotify="),
                 let value where value.hasPrefix("--config=notify="):
                return true
            default:
                continue
            }
        }

        return false
    }

    private static func directPlan(
        executablePath: String,
        arguments: [String],
        unsetEnvironment: [String] = []
    ) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: [:],
            unsetEnvironment: unsetEnvironment,
            preLaunchActions: []
        )
    }

    private static func claudeHookEntries(command: String, timeout: Int) -> [[String: Any]] {
        [[
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]],
        ]]
    }

    private static func codexHookCommand(cliPath: String, event: String) -> String {
        "\"\(shellEscapedDoubleQuoted(cliPath))\" ipc agent-event --adapter=codex \(event) || echo '{}'"
    }

    private static func copilotHookCommand(cliPath: String, event: String) -> String {
        "\"\(shellEscapedDoubleQuoted(cliPath))\" ipc agent-event --adapter=copilot \(event) || true"
    }

    private static var geminiHookSpecs: [(eventName: String, matcher: String, timeout: Int)] {
        [
            ("SessionStart", "*", 10_000),
            ("SessionEnd", "*", 1_000),
            ("BeforeAgent", "*", 10_000),
            ("AfterAgent", "*", 10_000),
            ("Notification", "*", 10_000),
            ("BeforeTool", "*", 5_000),
        ]
    }

    private static func geminiHookGroupsJSON(cliPath: String) -> [String: Any] {
        let command = geminiHookCommand(cliPath: cliPath)
        return Dictionary(uniqueKeysWithValues: geminiHookSpecs.map { spec in
            (
                spec.eventName,
                [geminiHookGroup(matcher: spec.matcher, command: command, timeout: spec.timeout)]
            )
        })
    }

    private static func geminiHookCommand(cliPath: String) -> String {
        "\"\(shellEscapedDoubleQuoted(cliPath))\" gemini-hook || echo '{}'"
    }

    private static func geminiHookGroup(matcher: String, command: String, timeout: Int) -> [String: Any] {
        [
            "matcher": matcher,
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]],
        ]
    }

    private static func copilotHookEntry(cliPath: String, event: String, timeout: Int) -> [String: Any] {
        [
            "type": "command",
            "bash": copilotHookCommand(cliPath: cliPath, event: event),
            "timeoutSec": timeout,
        ]
    }

    private static func shellEscapedDoubleQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func compactJSONString(_ object: Any) throws -> String {
        let data = try compactJSONData(object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentIPCError.invalidMessage
        }
        return string
    }

    private static func compactJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func tomlStringArrayLiteral(_ strings: [String]) -> String {
        "[\(strings.map(tomlBasicStringLiteral).joined(separator: ","))]"
    }

    private static func tomlBasicStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func symlinkDirectoryContentsSkipping(
        from sourceURL: URL,
        to destinationURL: URL,
        skippingNames: Set<String>,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        for entry in entries where !skippingNames.contains(entry.lastPathComponent) {
            let destination = destinationURL.appendingPathComponent(entry.lastPathComponent, isDirectory: false)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.createSymbolicLink(at: destination, withDestinationURL: entry)
            } catch {
                try copyItemIfPossible(at: entry, to: destination, fileManager: fileManager)
            }
        }
    }

    private static func copyDirectoryContents(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        for entry in entries {
            try copyItemIfPossible(
                at: entry,
                to: destinationURL.appendingPathComponent(entry.lastPathComponent, isDirectory: false),
                fileManager: fileManager
            )
        }
    }

    private static func copyItemIfPossible(
        at sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func stripJSONCComments(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = ""
        var iterator = text.makeIterator()
        var pending = iterator.next()
        var inString = false
        var escaping = false
        var lookahead: Character?

        func advance() {
            pending = lookahead ?? iterator.next()
            lookahead = nil
        }

        while let character = pending {
            if inString {
                output.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                advance()
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                advance()
                continue
            }

            if character == "/" {
                lookahead = iterator.next()
                if lookahead == "/" {
                    advance()
                    while let next = pending, next != "\n", next != "\r" {
                        advance()
                    }
                    continue
                }
                if lookahead == "*" {
                    advance()
                    while let next = pending {
                        if next == "*" {
                            lookahead = iterator.next()
                            if lookahead == "/" {
                                advance()
                                advance()
                                break
                            }
                        }
                        advance()
                    }
                    continue
                }
                output.append(character)
                advance()
                continue
            }

            output.append(character)
            advance()
        }

        return output.data(using: .utf8)
    }

    private static func stripTrailingCommas(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let characters = Array(text)
        var output = ""
        var inString = false
        var escaping = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output.data(using: .utf8)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
