import Foundation
import OSLog

private let agentTeamsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "agent-teams")

enum TerminalColorEnvironment {
    static let trueColor = "truecolor"

    /// Resolves the COLORTERM value to inherit, falling back to `trueColor`
    /// when the inherited value is missing or blank.
    static func colorTerm(inheritedFrom environment: [String: String]) -> String {
        nonBlank(environment["COLORTERM"]) ?? trueColor
    }

    static func nonBlank(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

enum WorklaneSessionEnvironment {
    private static let generatedTemplateEnvironmentKeys: Set<String> = [
        "PATH",
        "ZDOTDIR",
        "PROMPT_COMMAND",
        "GHOSTTY_LOG",
        "COLORTERM",
        "XDG_DATA_DIRS",
        "Q_TERM_PATH",
        // tmux identity is per pane and per app run: a restored pane gets a
        // fresh one, never the `%N` of whichever pane holds it now.
        "TMUX",
        "TMUX_PANE",
        TmuxShimEnvironment.claudeAgentTeamsKey,
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

        applyIPCConnection(to: &environment, windowID: windowID, worklaneID: worklaneID, paneID: paneID)

        var allWrapperDirectories = AgentStatusHelper.wrapperDirectoryPaths() ?? []
        allWrapperDirectories += AgentManifestWrapperMaterializer.materializedDirectories
        if !allWrapperDirectories.isEmpty {
            environment["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = allWrapperDirectories.joined(separator: ":")
        }

        if let supportDirectory = AgentStatusHelper.wrapperSupportDirectoryPath(in: .main) {
            environment["ZENTTY_WRAPPER_SUPPORT_DIR"] = supportDirectory
            let currentPath = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let pathEntries = currentPath.split(separator: ":").map(String.init)
            environment["PATH"] = pathEntries.contains(supportDirectory)
                ? currentPath
                : ([supportDirectory] + pathEntries).joined(separator: ":")
        }

        let manifestTable = AgentManifestRegistry.provider().shellTable
        if !manifestTable.isEmpty {
            environment["ZENTTY_AGENT_MANIFEST_TABLE"] = manifestTable
        }

        environment["COLORTERM"] = TerminalColorEnvironment.colorTerm(inheritedFrom: processEnvironment)

        if agentTeamsEnabled {
            applyAgentTeamsInjection(
                environment: &environment,
                processEnvironment: processEnvironment,
                windowID: windowID,
                paneID: paneID
            )
        }

        applyShellIntegration(to: &environment, processEnvironment: processEnvironment)

        return environment
    }

    /// Environment for a quick-action overlay's shell. It gets the shell
    /// integration and its own IPC identity, so the overlay can follow the
    /// shell's directory, branch and activity, but none of the pane's agent
    /// wrappers, manifest table or agent-teams shim: overlays are not panes.
    static func overlay(
        windowID: WindowID,
        worklaneID: WorklaneID,
        overlayID: PaneID,
        processEnvironment: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WINDOW_ID": windowID.rawValue,
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": overlayID.rawValue,
        ]
        applyIPCConnection(to: &environment, windowID: windowID, worklaneID: worklaneID, paneID: overlayID)
        environment["COLORTERM"] = TerminalColorEnvironment.colorTerm(inheritedFrom: processEnvironment)
        applyShellIntegration(to: &environment, processEnvironment: processEnvironment)
        return environment
    }

    private static func applyIPCConnection(
        to environment: inout [String: String],
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        guard let connectionInfo = AgentIPCServer.shared.connectionInfo(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID
        ) else { return }
        environment["ZENTTY_INSTANCE_SOCKET"] = connectionInfo.socketPath
        environment["ZENTTY_PANE_TOKEN"] = connectionInfo.paneToken
        environment["ZENTTY_CLI_BIN"] = connectionInfo.cliPath
        environment[AgentStatusTransport.instanceIDEnvironmentKey] = connectionInfo.instanceID
    }

    private static func applyShellIntegration(
        to environment: inout [String: String],
        processEnvironment: [String: String]
    ) {
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

            if let kiroTermWrapper = AgentStatusHelper.kiroTermWrapperPath() {
                // Kiro CLI's shell pre-block execs the pane shell into kiro-cli-term, which then
                // spawns a fresh shell. It honours a pre-set Q_TERM_PATH, so route it through our
                // wrapper, which re-exports ZDOTDIR/PROMPT_COMMAND/XDG_DATA_DIRS before exec'ing the
                // real figterm (dedene/zentty#95).
                if let existing = TerminalColorEnvironment.nonBlank(processEnvironment["Q_TERM_PATH"]), existing != kiroTermWrapper {
                    environment["ZENTTY_ORIGINAL_Q_TERM_PATH"] = existing
                }
                environment["Q_TERM_PATH"] = kiroTermWrapper
            }
        }

        if let ghosttyLog = processEnvironment["GHOSTTY_LOG"], !ghosttyLog.isEmpty {
            environment["GHOSTTY_LOG"] = ghosttyLog
        } else {
            environment["GHOSTTY_LOG"] = "macos,no-stderr"
        }
    }

    static func templateSafeOverrides(from environment: [String: String]) -> [String: String] {
        // `-e NAME=VALUE` assignments a tmux tool passed may carry tokens;
        // they belong to that run, not to a saved workspace.
        let toolAssignedKeys = TmuxShimEnvironment.toolAssignedKeys(in: environment)
        return environment.reduce(into: [:]) { safeEnvironment, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !key.hasPrefix("ZENTTY_"),
                  !generatedTemplateEnvironmentKeys.contains(key),
                  !toolAssignedKeys.contains(key) else {
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
        windowID: WindowID,
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

        let state = TmuxCompatSessionState.shared
        TmuxShimEnvironment.apply(
            to: &environment,
            shimDirectory: shimDirectory,
            tmux: TmuxShimEnvironment.tmuxValue(
                socketPath: tmuxSocketPath,
                serverPID: ProcessInfo.processInfo.processIdentifier,
                sessionNumber: state.sessionNumber(for: windowID.rawValue)
            ),
            tmuxPane: TmuxShimEnvironment.paneValue(paneNumber: state.paneNumber(for: paneID.rawValue)),
            tracePath: processEnvironment[TmuxShimEnvironment.tracePathKey] ?? defaultTmuxCompatTracePath(),
            fallbackPath: processEnvironment["PATH"]
        )
        environment[TmuxShimEnvironment.claudeAgentTeamsKey] = "1"
    }

    /// Panes created through the tmux shim carry the creator's shim
    /// environment (see `TmuxShimEnvironment.inheritedKeys`); give them their
    /// own `TMUX_PANE` once their pane id is known. A `TMUX_PANE` that is
    /// already set wins: Agent Teams panes get theirs in `make`, and a
    /// `respawn-pane` replacement keeps the id of the pane it replaces.
    static func applyTmuxPaneIdentity(to environment: inout [String: String], paneID: PaneID) {
        guard environment[TmuxShimEnvironment.markerKey] == "1" else {
            return
        }
        if let shimDirectory = environment[TmuxShimEnvironment.shimDirectoryKey], !shimDirectory.isEmpty,
           let path = environment["PATH"] {
            environment["PATH"] = TmuxShimEnvironment.prependingShim(shimDirectory, to: path)
        }
        if environment["TMUX_PANE"]?.isEmpty ?? true {
            environment["TMUX_PANE"] = TmuxShimEnvironment.paneValue(
                paneNumber: TmuxCompatSessionState.shared.paneNumber(for: paneID.rawValue)
            )
        }
    }

    /// `$TMUX` / `#{socket_path}` for this app run.
    static var tmuxSocketPath: String {
        TmuxShimEnvironment.socketPath(instanceID: AgentIPCServer.shared.instanceID)
    }

    private static func defaultTmuxCompatTracePath() -> String {
        ZenttyBuildFlavor.current
            .stateDirectoryURL(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("tmux-compat-trace.jsonl", isDirectory: false)
            .path
    }
}
