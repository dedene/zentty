import AppKit
import CryptoKit
import Darwin
import Foundation
import os

private let agentLaunchLogger = Logger(
    subsystem: "be.zenjoy.zentty",
    category: "AgentLaunchBootstrap"
)

enum AgentLaunchBootstrap {
    static func makePlan(
        request: AgentIPCRequest,
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appConfigProvider: () -> AppConfig = loadAppConfig
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
        case .amp:
            return try ampPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                bundle: bundle,
                fileManager: fileManager
            )
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
        case .cursor:
            return try cursorPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                fileManager: fileManager
            )
        case .droid:
            return try droidPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
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
        case .kimi:
            return try kimiPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        case .opencode:
            return try opencodePlan(
                executablePath: resolvedOpenCodeExecutablePath(
                    executablePath,
                    fileManager: fileManager
                ),
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                bundle: bundle,
                fileManager: fileManager,
                appConfigProvider: appConfigProvider
            )
        case .pi:
            return piPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                bundle: bundle,
                fileManager: fileManager
            )
        case .grok:
            return grokPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        case .agy:
            return agyPlan(
                executablePath: executablePath,
                arguments: request.arguments,
                environment: environment,
                target: target,
                runtimeDirectoryURL: runtimeDirectoryURL,
                fileManager: fileManager
            )
        }
    }

    private static func ampPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_AMP_HOOKS_DISABLED"] == "1" {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        var setEnvironment = ["ZENTTY_AGENT_TOOL": "amp"]
        let configHomeURL = AmpPluginInstaller.defaultUserConfigHomeURL(environment: environment)
        if AmpPluginInstaller.installBundledPluginIfPossible(
            destinationConfigHomeURL: configHomeURL,
            bundle: bundle,
            fileManager: fileManager
        ) {
            setEnvironment["PLUGINS"] = "all"
        }

        if let sanitizedArguments = AmpResumeArgumentSanitizer.sanitizedAmpResumeArguments(from: arguments),
           !sanitizedArguments.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: sanitizedArguments),
           let json = String(data: data, encoding: .utf8) {
            setEnvironment["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"] = json
        }

        let sessionStartJSON = """
        {"version":1,"event":"session.start","agent":{"name":"Amp","pid":\(AgentIPCProtocol.selfPIDPlaceholder)},"context":{"launch":{"arguments":\(setEnvironment["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"] ?? "[]")}}}
        """
        let agentRunningJSON = """
        {"version":1,"event":"agent.running","agent":{"name":"Amp","pid":\(AgentIPCProtocol.selfPIDPlaceholder)},"context":{"launch":{"arguments":\(setEnvironment["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"] ?? "[]")}}}
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
                AgentLaunchAction(
                    subcommand: "agent-event",
                    arguments: [],
                    standardInput: agentRunningJSON
                ),
            ]
        )
    }

    private static func cursorPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_CURSOR_HOOKS_DISABLED"] == "1" {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        CursorHooksInstaller.installIfPossible(environment: environment, fileManager: fileManager)

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: [
                "ZENTTY_AGENT_TOOL": "cursor",
            ],
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    private static func droidPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_DROID_HOOKS_DISABLED"] == "1" {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        DroidHooksInstaller.installIfPossible(environment: environment, fileManager: fileManager)

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: [
                "ZENTTY_AGENT_TOOL": "droid",
            ],
            unsetEnvironment: [],
            preLaunchActions: []
        )
    }

    private static func piPlan(
        executablePath: String,
        arguments: [String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> AgentLaunchPlan {
        // Pi itself sets PI_CODING_AGENT=true at startup (src/cli.ts),
        // so we only need ZENTTY_AGENT_TOOL for Zentty's own recognition.
        let setEnvironment = ["ZENTTY_AGENT_TOOL": "pi"]

        var plannedArguments = arguments
        let extensionURL = bundle.resourceURL?
            .appendingPathComponent("pi", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("zentty-pi-zentty.js", isDirectory: false)
        if let extensionURL, fileManager.isReadableFile(atPath: extensionURL.path) {
            // Stack the bridge on top of the user's own pi extensions:
            // with `-e <path>` alone (no `--no-extensions`), pi merges CLI
            // extensions with globals — see pi-mono
            // packages/coding-agent/src/core/resource-loader.ts.
            plannedArguments.insert(contentsOf: ["-e", extensionURL.path], at: 0)
        } else {
            // Silent miss here leaves the sidebar stuck on "Starting" with
            // no breadcrumb. Warn so bundle misconfigurations are traceable
            // via `log stream --predicate 'category == "AgentLaunchBootstrap"'`.
            agentLaunchLogger.warning(
                "Pi bridge extension missing from bundle (path=\(extensionURL?.path ?? "<nil>", privacy: .public)); agent status will not be tracked"
            )
        }

        let sessionStartJSON = """
        {"version":1,"event":"session.start","agent":{"name":"Pi","pid":\(AgentIPCProtocol.selfPIDPlaceholder)}}
        """
        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: plannedArguments,
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

    private static func grokPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) -> AgentLaunchPlan {
        // Grok Build (early beta) discovers hooks from ~/.grok/hooks/ and .grok/hooks/
        // (project-local, may require `/hooks-trust` in the TUI).
        //
        // We automatically ensure Zentty status hooks are installed in the user's
        // ~/.grok/hooks/ on first launch (idempotent). This gives full explicit
        // hook-driven status (todo progress via TodoWrite + needs-input via ask_user_question)
        // without the user having to run `zentty install grok-hooks` manually.
        //
        // ZENTTY_GROK_HOOKS_DISABLED=1 short-circuits at AgentToolLauncher.shouldAttemptBootstrap,
        // so reaching this point already means hooks are enabled. Users who want manual
        // control can still use `zentty install/uninstall grok-hooks`.
        if let cliPath = environment["ZENTTY_CLI_BIN"] {
            try? GrokHooksInstaller.ensureInstalledForCurrentUser(cliPath: cliPath, fileManager: fileManager)
        }

        let setEnvironment: [String: String] = [
            "ZENTTY_AGENT_TOOL": "grok",
            "ZENTTY_GROK_PID": "\(getpid())"
        ]

        // Best-effort: emit a session.start via preLaunchAction so even without hooks
        // the sidebar gets a clean "Grok" entry with the right PID for crash detection.
        let sessionStartJSON = """
        {"version":1,"event":"session.start","agent":{"name":"Grok","pid":\(AgentIPCProtocol.selfPIDPlaceholder)}}
        """

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: [
                AgentLaunchAction(
                    subcommand: "agent-event",
                    arguments: ["--adapter=grok"],
                    standardInput: sessionStartJSON
                )
            ]
        )
    }

    private static func agyPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) -> AgentLaunchPlan {
        // Auto-install the status hooks into ~/.gemini/config/hooks.json on
        // launch (idempotent; only rewrites when content drifts). agy has no
        // config-dir override, so unlike most agents we can't use an
        // ephemeral overlay — we mirror Grok's persistent install instead.
        // The installed hook command no-ops outside Zentty (it guards on the
        // routing env), and ZENTTY_AGY_HOOKS_DISABLED=1 short-circuits before
        // this point in AgentToolLauncher, so reaching here means hooks are
        // wanted.
        if let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank {
            let home = environment["HOME"]?.nilIfBlank ?? NSHomeDirectory()
            try? AgyHooksInstaller.ensureInstalledForCurrentUser(cliPath: cliPath, home: home, fileManager: fileManager)
        }

        var setEnvironment: [String: String] = [
            "ZENTTY_AGENT_TOOL": "agy",
            "ZENTTY_AGY_PID": "\(getpid())",
        ]
        let argumentsJSON = (try? compactJSONString(arguments)) ?? "[]"

        // The Antigravity CLI assigns its own `conversation_id` once a
        // session opens; that real id arrives via the first hook and
        // supersedes this placeholder downstream (see `AgyCanonicalReEmitter`
        // and the agy adapter). The `zentty-placeholder-` prefix lets the
        // resume builder recognise and reject the placeholder if no real
        // id ever arrives (hooks disabled, agy crash before first hook,
        // etc.), so we never end up calling `agy --conversation <fake>`.
        let placeholderSessionID = "zentty-placeholder-\(UUID().uuidString.lowercased())"
        setEnvironment["ZENTTY_AGY_PLACEHOLDER_SESSION_ID"] = placeholderSessionID

        let sessionStartJSON = """
        {"version":1,"event":"session.start","agent":{"name":"Antigravity","pid":\(AgentIPCProtocol.selfPIDPlaceholder)},"session":{"id":"\(placeholderSessionID)"},"context":{"launch":{"arguments":\(argumentsJSON)}}}
        """
        let agentRunningJSON = """
        {"version":1,"event":"agent.running","agent":{"name":"Antigravity","pid":\(AgentIPCProtocol.selfPIDPlaceholder)},"session":{"id":"\(placeholderSessionID)"},"context":{"launch":{"arguments":\(argumentsJSON)}}}
        """

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            setEnvironment: setEnvironment,
            unsetEnvironment: [],
            preLaunchActions: [
                AgentLaunchAction(
                    subcommand: "agent-event",
                    arguments: ["--adapter=agy"],
                    standardInput: sessionStartJSON
                ),
                AgentLaunchAction(
                    subcommand: "agent-event",
                    arguments: ["--adapter=agy"],
                    standardInput: agentRunningJSON
                )
            ]
        )
    }

    private static func kimiPlan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        target: AgentIPCTarget,
        runtimeDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> AgentLaunchPlan {
        if environment["ZENTTY_KIMI_HOOKS_DISABLED"] == "1" {
            return directPlan(executablePath: executablePath, arguments: arguments)
        }

        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nilIfBlank else {
            return AgentLaunchPlan(
                executablePath: executablePath,
                arguments: arguments,
                setEnvironment: [
                    "ZENTTY_AGENT_TOOL": "kimi",
                ],
                unsetEnvironment: [],
                preLaunchActions: []
            )
        }

        let (forwardedArguments, configSource) = parseKimiConfig(arguments: arguments, environment: environment)
        let overlayDirectoryURL = try prepareToolDirectory(
            tool: .kimi,
            target: target,
            runtimeDirectoryURL: runtimeDirectoryURL,
            fileManager: fileManager
        )
        let overlayConfigURL = overlayDirectoryURL.appendingPathComponent("config.toml", isDirectory: false)
        let existingConfig = try kimiConfigContents(from: configSource, fileManager: fileManager)
        let mergedConfig = try KimiHooksInstaller.mergedConfigText(existingConfig: existingConfig, cliPath: cliPath)
        try mergedConfig.write(to: overlayConfigURL, atomically: true, encoding: .utf8)

        return AgentLaunchPlan(
            executablePath: executablePath,
            arguments: ["--config-file", overlayConfigURL.path] + forwardedArguments,
            setEnvironment: [
                "ZENTTY_AGENT_TOOL": "kimi",
            ],
            unsetEnvironment: [],
            preLaunchActions: []
        )
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
                "SessionStart": claudeSessionStartHookEntries(command: hookCommand, timeout: 10),
                "Stop": claudeHookEntries(command: hookCommand, timeout: 10),
                "SessionEnd": claudeHookEntries(command: hookCommand, timeout: 1),
                "Notification": claudeHookEntries(command: hookCommand, timeout: 10),
                "PermissionRequest": claudeHookEntries(command: hookCommand, timeout: 10),
                "UserPromptSubmit": claudeHookEntries(command: hookCommand, timeout: 10),
                "PreToolUse": claudePreToolUseHookEntries(command: hookCommand, timeout: 5),
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

        let setEnvironment = ["ZENTTY_AGENT_TOOL": "codex"]
        let unsetEnvironment = codexUnsetEnvironment(environment: environment)
        var plannedArguments = arguments
        plannedArguments.insert(contentsOf: codexHookConfigArguments(cliPath: cliPath) + [
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
            unsetEnvironment: unsetEnvironment,
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
        fileManager: FileManager,
        appConfigProvider: () -> AppConfig
    ) throws -> AgentLaunchPlan {
        var setEnvironment = ["ZENTTY_AGENT_TOOL": "opencode"]
        let sourceConfigPath = opencodeSourceConfigDirectoryPath(
            environment: environment,
            fileManager: fileManager
        )
        setEnvironment["ZENTTY_OPENCODE_BASE_CONFIG_DIR"] = sourceConfigPath
        let appConfig = appConfigProvider()

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
            let overlayRoots = OpenCodeOverlayLayout.overlayRoots(for: overlayDirectoryURL)
            let overlayConfigURL = appConfig.appearance.syncOpenCodeThemeWithTerminal
                ? overlayRoots.configDirectoryURL
                : overlayDirectoryURL.appendingPathComponent("config", isDirectory: true)
            try fileManager.createDirectory(at: overlayConfigURL, withIntermediateDirectories: true)
            if let sourceConfigPath = sourceConfigPath.nilIfBlank,
               fileManager.fileExists(atPath: sourceConfigPath) {
                try copyDirectoryContents(
                    from: URL(fileURLWithPath: sourceConfigPath, isDirectory: true),
                    to: overlayConfigURL,
                    skippingNames: appConfig.appearance.syncOpenCodeThemeWithTerminal ? ["themes"] : [],
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
            try OpenCodeThemeSync.apply(
                toOverlayConfigDirectory: overlayConfigURL,
                appConfig: appConfig,
                configEnvironment: GhosttyConfigEnvironment(appConfigProvider: { appConfig }),
                effectiveAppearance: NSApp?.effectiveAppearance ?? NSAppearance(named: .darkAqua) ?? NSAppearance.current,
                themeDirectories: GhosttyThemeLibrary.resolverThemeDirectories(),
                fileManager: fileManager
            )
            if appConfig.appearance.syncOpenCodeThemeWithTerminal {
                try prepareOpenCodeStateOverlay(
                    sourceStateDirectoryURL: opencodeSourceStateDirectoryURL(environment: environment),
                    overlayStateDirectoryURL: overlayRoots.stateDirectoryURL,
                    fileManager: fileManager
                )
                setEnvironment["XDG_CONFIG_HOME"] = overlayRoots.configHomeURL.path
                setEnvironment["XDG_STATE_HOME"] = overlayRoots.stateHomeURL.path
                setEnvironment["OPENCODE_TUI_CONFIG"] = overlayConfigURL
                    .appendingPathComponent("tui.json", isDirectory: false)
                    .path
            }
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

    private static func resolvedOpenCodeExecutablePath(
        _ executablePath: String,
        fileManager: FileManager
    ) -> String {
        let executableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
        guard executableURL.lastPathComponent == "opencode" else {
            return executablePath
        }

        let candidateExecutableURLs = [executableURL, executableURL.resolvingSymlinksInPath()]
        for candidateExecutableURL in candidateExecutableURLs {
            let siblingBinaryURL = candidateExecutableURL
                .deletingLastPathComponent()
                .appendingPathComponent(".opencode", isDirectory: false)
            if fileManager.isExecutableFile(atPath: siblingBinaryURL.path) {
                return siblingBinaryURL.path
            }
        }

        return executablePath
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

    private static func kimiConfigContents(
        from source: KimiConfigSource,
        fileManager: FileManager
    ) throws -> String {
        switch source {
        case let .inline(configText):
            return configText
        case let .defaultFile(url):
            guard fileManager.fileExists(atPath: url.path) else {
                return ""
            }
            return try String(contentsOf: url, encoding: .utf8)
        case let .explicitFile(url):
            guard fileManager.fileExists(atPath: url.path) else {
                throw CocoaError(
                    .fileNoSuchFile,
                    userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedDescriptionKey: "Kimi config file not found at \(url.path)",
                    ]
                )
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
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

    private static func opencodeSourceStateDirectoryURL(environment: [String: String]) -> URL {
        let basePath = environment["XDG_STATE_HOME"]?.nilIfBlank
            ?? URL(fileURLWithPath: environment["HOME"]?.nilIfBlank ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .path
        return URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    private static func opencodeSourceConfigDirectoryPath(
        environment: [String: String],
        fileManager: FileManager
    ) -> String {
        if let explicitPath = environment["ZENTTY_OPENCODE_BASE_CONFIG_DIR"]?.nilIfBlank {
            return explicitPath
        }
        if let explicitPath = environment["OPENCODE_CONFIG_DIR"]?.nilIfBlank {
            return explicitPath
        }

        let fallbackPaths = [
            environment["XDG_CONFIG_HOME"]?.nilIfBlank.map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("opencode", isDirectory: true)
                    .path
            },
            URL(fileURLWithPath: environment["HOME"]?.nilIfBlank ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .path,
        ].compactMap { $0 }

        return fallbackPaths.first { fileManager.fileExists(atPath: $0) } ?? ""
    }

    private static func prepareOpenCodeStateOverlay(
        sourceStateDirectoryURL: URL,
        overlayStateDirectoryURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: overlayStateDirectoryURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: sourceStateDirectoryURL.path) {
            try copyDirectoryContents(
                from: sourceStateDirectoryURL,
                to: overlayStateDirectoryURL,
                fileManager: fileManager
            )
        }
        try scrubOpenCodeThemeState(in: overlayStateDirectoryURL, fileManager: fileManager)
    }

    private static func scrubOpenCodeThemeState(in stateDirectoryURL: URL, fileManager: FileManager) throws {
        let kvURL = stateDirectoryURL.appendingPathComponent("kv.json", isDirectory: false)
        guard fileManager.fileExists(atPath: kvURL.path) else {
            return
        }
        guard let data = try? Data(contentsOf: kvURL),
              var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        jsonObject.removeValue(forKey: "theme")
        jsonObject.removeValue(forKey: "theme_mode")
        jsonObject.removeValue(forKey: "theme_mode_lock")

        let cleaned = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        try cleaned.write(to: kvURL, options: .atomic)
    }

    private struct CodexHookTrustState {
        var key: String
        var trustedHash: String
    }

    private struct CodexHookSpec {
        var eventName: String
        var eventKey: String
        var eventArgument: String
        var timeout: Int
    }

    private static var codexHookSpecs: [CodexHookSpec] {
        [
            CodexHookSpec(eventName: "SessionStart", eventKey: "session_start", eventArgument: "session-start", timeout: 10),
            CodexHookSpec(eventName: "PreToolUse", eventKey: "pre_tool_use", eventArgument: "pre-tool-use", timeout: 10),
            CodexHookSpec(eventName: "PermissionRequest", eventKey: "permission_request", eventArgument: "permission-request", timeout: 10),
            CodexHookSpec(eventName: "PostToolUse", eventKey: "post_tool_use", eventArgument: "post-tool-use", timeout: 10),
            CodexHookSpec(eventName: "UserPromptSubmit", eventKey: "user_prompt_submit", eventArgument: "prompt-submit", timeout: 10),
            CodexHookSpec(eventName: "Stop", eventKey: "stop", eventArgument: "stop", timeout: 10),
        ]
    }

    private static func codexHookConfigArguments(cliPath: String) -> [String] {
        var configValues = ["features.hooks=true"]
        let trustStates = codexHookSpecs.map { spec in
            let command = codexHookCommand(cliPath: cliPath, event: spec.eventArgument)
            configValues.append(codexHookEventConfig(spec: spec, command: command))
            return codexHookTrustState(
                spec: spec,
                matcher: nil,
                command: command,
                timeout: spec.timeout
            )
        }
        configValues.append(codexHookStateConfig(trustStates))
        return configValues.flatMap { ["-c", $0] }
    }

    private static func codexHookEventConfig(spec: CodexHookSpec, command: String) -> String {
        let commandValue = tomlBasicStringLiteral(command)
        return "hooks.\(spec.eventName)=[{hooks=[{type=\"command\",command=\(commandValue),timeout=\(spec.timeout)}]}]"
    }

    private static func codexHookStateConfig(_ states: [CodexHookTrustState]) -> String {
        let entries = states.map { state in
            "\(tomlBasicStringLiteral(state.key))={trusted_hash=\(tomlBasicStringLiteral(state.trustedHash))}"
        }
        return "hooks.state={\(entries.joined(separator: ","))}"
    }

    private static func codexHookTrustState(
        spec: CodexHookSpec,
        matcher: String?,
        command: String,
        timeout: Int
    ) -> CodexHookTrustState {
        CodexHookTrustState(
            key: "/<session-flags>/config.toml:\(spec.eventKey):0:0",
            trustedHash: codexHookTrustedHash(
                eventKey: spec.eventKey,
                matcher: matcher,
                command: command,
                timeout: timeout
            )
        )
    }

    private static func codexHookTrustedHash(
        eventKey: String,
        matcher: String?,
        command: String,
        timeout: Int
    ) -> String {
        var identity = CodexCanonicalJSON.object([
            "event_name": .string(eventKey),
            "hooks": .array([
                .object([
                    "async": .bool(false),
                    "command": .string(command),
                    "timeout": .number(timeout),
                    "type": .string("command"),
                ]),
            ]),
        ])
        if let matcher {
            identity["matcher"] = .string(matcher)
        }

        let digest = SHA256.hash(data: Data(identity.serialized().utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
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
        guard let uncommentedData = JSONCRelaxedParse.stripComments(in: existingData),
              let cleanedData = JSONCRelaxedParse.stripTrailingCommas(in: uncommentedData),
              var jsonObject = try JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] else {
            return nil
        }

        jsonObject["version"] = 1
        var hooks = jsonObject["hooks"] as? [String: Any] ?? [:]

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

    private static func codexUnsetEnvironment(environment: [String: String]) -> [String] {
        guard let codexHome = environment["CODEX_HOME"]?.nilIfBlank,
              isZenttyLaunchCachePath(codexHome) else {
            return []
        }
        return ["CODEX_HOME"]
    }

    private static func isZenttyLaunchCachePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
        guard components.count >= 3 else {
            return false
        }
        for index in 0...(components.count - 3) {
            if components[index] == "Library",
               components[index + 1] == "Caches",
               components[index + 2] == "Zentty" {
                return true
            }
        }
        return false
    }

    private static func parseKimiConfig(
        arguments: [String],
        environment: [String: String]
    ) -> (forwardedArguments: [String], source: KimiConfigSource) {
        var forwarded = [String]()
        var iterator = arguments.makeIterator()
        var source: KimiConfigSource = .defaultFile(KimiHooksInstaller.defaultUserConfigURL(
            home: environment["HOME"]?.nilIfBlank ?? NSHomeDirectory()
        ))

        while let argument = iterator.next() {
            switch argument {
            case "--config-file":
                if let value = iterator.next() {
                    source = .explicitFile(URL(fileURLWithPath: value, isDirectory: false))
                } else {
                    forwarded.append(argument)
                }
            case let value where value.hasPrefix("--config-file="):
                source = .explicitFile(
                    URL(
                        fileURLWithPath: String(value.dropFirst("--config-file=".count)),
                        isDirectory: false
                    )
                )
            case "--config":
                if let value = iterator.next() {
                    source = .inline(value)
                } else {
                    forwarded.append(argument)
                }
            case let value where value.hasPrefix("--config="):
                source = .inline(String(value.dropFirst("--config=".count)))
            default:
                forwarded.append(argument)
            }
        }

        return (forwarded, source)
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

    private static func claudeSessionStartHookEntries(command: String, timeout: Int) -> [[String: Any]] {
        ["startup", "resume", "clear", "compact"].map { matcher in
            [
                "matcher": matcher,
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                ]],
            ]
        }
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

    private static func claudePreToolUseHookEntries(command: String, timeout: Int) -> [[String: Any]] {
        ["AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit"].map { matcher in
            [
                "matcher": matcher,
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                ]],
            ]
        }
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
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\u{08}":
                output.append("\\b")
            case "\t":
                output.append("\\t")
            case "\n":
                output.append("\\n")
            case "\u{0C}":
                output.append("\\f")
            case "\r":
                output.append("\\r")
            case "\"":
                output.append("\\\"")
            case "\\":
                output.append("\\\\")
            case _ where scalar.value < 0x20:
                output.append(String(format: "\\u%04x", scalar.value))
            default:
                output.append(String(scalar))
            }
        }
        output.append("\"")
        return output
    }

    private indirect enum CodexCanonicalJSON {
        case object([String: CodexCanonicalJSON])
        case array([CodexCanonicalJSON])
        case string(String)
        case number(Int)
        case bool(Bool)

        subscript(key: String) -> CodexCanonicalJSON? {
            get {
                guard case let .object(values) = self else {
                    return nil
                }
                return values[key]
            }
            set {
                guard case var .object(values) = self else {
                    return
                }
                values[key] = newValue
                self = .object(values)
            }
        }

        func serialized() -> String {
            switch self {
            case let .object(values):
                let members = values.keys.sorted().map { key in
                    "\(Self.escapedString(key)):\(values[key]?.serialized() ?? "null")"
                }
                return "{\(members.joined(separator: ","))}"
            case let .array(values):
                return "[\(values.map { $0.serialized() }.joined(separator: ","))]"
            case let .string(value):
                return Self.escapedString(value)
            case let .number(value):
                return String(value)
            case let .bool(value):
                return value ? "true" : "false"
            }
        }

        private static func escapedString(_ value: String) -> String {
            var output = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"":
                    output.append("\\\"")
                case "\\":
                    output.append("\\\\")
                case "\u{08}":
                    output.append("\\b")
                case "\u{0C}":
                    output.append("\\f")
                case "\n":
                    output.append("\\n")
                case "\r":
                    output.append("\\r")
                case "\t":
                    output.append("\\t")
                case _ where scalar.value < 0x20:
                    output.append(String(format: "\\u%04x", scalar.value))
                default:
                    output.append(String(scalar))
                }
            }
            output.append("\"")
            return output
        }
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
        try copyDirectoryContents(
            from: sourceURL,
            to: destinationURL,
            skippingNames: [],
            fileManager: fileManager
        )
    }

    private static func copyDirectoryContents(
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

    private static func loadAppConfig() -> AppConfig {
        let fileURL = AppConfigStore.defaultFileURL()
        guard
            let source = try? String(contentsOf: fileURL, encoding: .utf8),
            let config = AppConfigTOML.decode(source)
        else {
            return .default
        }

        return config
    }
}

private enum KimiConfigSource {
    case defaultFile(URL)
    case explicitFile(URL)
    case inline(String)
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
