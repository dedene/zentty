import Foundation
import OSLog

private let agentTeamsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "agent-teams")

enum WorklaneSessionEnvironment {
    private static let generatedTemplateEnvironmentKeys: Set<String> = [
        "PATH",
        "ZDOTDIR",
        "PROMPT_COMMAND",
        "GHOSTTY_LOG",
        "XDG_DATA_DIRS",
    ]

    static func make(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil,
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool = false
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WINDOW_ID": windowID.rawValue,
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]

        if let initialWorkingDirectory = trimmed(initialWorkingDirectory) {
            environment["ZENTTY_INITIAL_WORKING_DIRECTORY"] = initialWorkingDirectory
        }

        if let connectionInfo = AgentIPCServer.shared.connectionInfo(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID
        ) {
            environment["ZENTTY_INSTANCE_SOCKET"] = connectionInfo.socketPath
            environment["ZENTTY_PANE_TOKEN"] = connectionInfo.paneToken
            environment["ZENTTY_CLI_BIN"] = connectionInfo.cliPath
            environment[AgentStatusTransport.instanceIDEnvironmentKey] = connectionInfo.instanceID
        }

        if let wrapperDirectories = AgentStatusHelper.wrapperDirectoryPaths() {
            environment["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = wrapperDirectories.joined(separator: ":")
        }

        if let supportDirectory = AgentStatusHelper.wrapperSupportDirectoryPath(in: .main) {
            let currentPath = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let pathEntries = currentPath.split(separator: ":").map(String.init)
            environment["PATH"] = pathEntries.contains(supportDirectory)
                ? currentPath
                : ([supportDirectory] + pathEntries).joined(separator: ":")
        }

        if agentTeamsEnabled {
            applyAgentTeamsInjection(
                environment: &environment,
                processEnvironment: processEnvironment,
                worklaneID: worklaneID,
                paneID: paneID
            )
        }

        if let shellIntegrationDirectory = AgentStatusHelper.shellIntegrationDirectoryPath() {
            environment["ZENTTY_SHELL_INTEGRATION_DIR"] = shellIntegrationDirectory
            environment["ZENTTY_SHELL_INTEGRATION"] = "1"
            environment["ZDOTDIR"] = shellIntegrationDirectory

            if let currentZDOTDIR = processEnvironment["ZDOTDIR"], !currentZDOTDIR.isEmpty {
                environment["ZENTTY_ORIGINAL_ZDOTDIR"] = currentZDOTDIR
            }

            if let currentPromptCommand = processEnvironment["PROMPT_COMMAND"], !currentPromptCommand.isEmpty {
                environment["ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND"] = currentPromptCommand
            }

            environment["PROMPT_COMMAND"] = ". \"\(shellIntegrationDirectory)/zentty-bash-integration.bash\""

            // fish and nushell discover their integration files through XDG_DATA_DIRS.
            // We inject it for every pane because make() does not know the shell type
            // here; only fish/nu read it (bash/zsh load via ZDOTDIR/PROMPT_COMMAND). The
            // fish/nu integration scripts strip this entry back out early at load, so
            // their sessions and children see a clean value — bash/zsh never read it.
            // The "/usr/local/share:/usr/share" fallback when XDG_DATA_DIRS is unset is
            // deliberate: collapsing it to only our dir breaks XDG-aware apps (cf. Ghostty
            // ghostty-org/ghostty#2711, where GTK apps crashed).
            let xdgDir = shellIntegrationDirectory
            environment["ZENTTY_SHELL_INTEGRATION_XDG_DIR"] = xdgDir
            let currentXdg = processEnvironment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            let xdgEntries = currentXdg
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != xdgDir }
            environment["XDG_DATA_DIRS"] = ([xdgDir] + xdgEntries).joined(separator: ":")
            if let orig = processEnvironment["XDG_DATA_DIRS"], !orig.isEmpty {
                environment["ZENTTY_ORIGINAL_XDG_DATA_DIRS"] = orig
            }
        }

        if let ghosttyLog = processEnvironment["GHOSTTY_LOG"], !ghosttyLog.isEmpty {
            environment["GHOSTTY_LOG"] = ghosttyLog
        } else {
            environment["GHOSTTY_LOG"] = "macos,no-stderr"
        }

        return environment
    }

    static func templateSafeOverrides(from environment: [String: String]) -> [String: String] {
        environment.reduce(into: [:]) { safeEnvironment, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !key.hasPrefix("ZENTTY_"),
                  !generatedTemplateEnvironmentKeys.contains(key) else {
                return
            }
            safeEnvironment[key] = entry.value
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func applyAgentTeamsInjection(
        environment: inout [String: String],
        processEnvironment: [String: String],
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        if let existing = processEnvironment["TMUX"], !existing.isEmpty {
            agentTeamsLogger.info(
                "Skipping tmux shim injection: TMUX already set to \(existing, privacy: .public)"
            )
            return
        }

        guard let shimDirectory = AgentStatusHelper.tmuxShimDirectoryPath() else {
            agentTeamsLogger.warning("Skipping tmux shim injection: bundled shim directory unavailable")
            return
        }

        environment["ZENTTY_TMUX_SHIM_DIR"] = shimDirectory

        let currentPath = environment["PATH"] ?? processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let pathEntries = currentPath.split(separator: ":").map(String.init)
        if !pathEntries.contains(shimDirectory) {
            environment["PATH"] = ([shimDirectory] + pathEntries).joined(separator: ":")
        }

        environment["TMUX"] = "/tmp/zentty-claude-teams/\(worklaneID.rawValue),0,\(paneID.rawValue)"
        environment["TMUX_PANE"] = "%\(paneID.rawValue)"
        environment["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        environment["ZENTTY_TMUX_COMPAT_TRACE_PATH"] = processEnvironment["ZENTTY_TMUX_COMPAT_TRACE_PATH"]
            ?? defaultTmuxCompatTracePath()
    }

    private static func defaultTmuxCompatTracePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: true)
            .appendingPathComponent("tmux-compat-trace.jsonl", isDirectory: false)
            .path
    }
}
