import AppKit
import Foundation

/// Pane lifecycle and layout commands: respawn-pane, select-pane, kill-pane,
/// kill-window, select-layout, resize-pane.
extension TmuxCompatIPCHandler {
    // MARK: - respawn-pane

    struct RespawnPaneRequest: Equatable {
        let target: String?
        let command: String?
        let workingDirectory: String?
        let environment: [String]
        let kill: Bool
    }

    @MainActor
    static func handleRespawnPane(
        arguments: [String],
        context: inout TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        // Claude Code's exact `-k -t <pane> -- <command>` launch of a deferred
        // placeholder pane keeps its dedicated fast path. That shape on a pane
        // that already runs is refused, so a repeated launch cannot replace a
        // running teammate.
        let resolver = context.resolver
        if let launchRequest = respawnPaneLaunchRequest(
            arguments: arguments,
            resolvePane: { selector in resolver.pane(selector).map { PaneID($0.pane.id) } }
        ), let location = context.topology.location(ofPane: launchRequest.paneID.rawValue) {
            guard context.windowController.launchDeferredPane(
                id: launchRequest.paneID,
                in: WorklaneID(location.window.id),
                nativeCommand: launchRequest.nativeCommand
            ) else {
                throw TmuxCompatIPCError.targetNotDeferred(launchRequest.paneID)
            }
            return AgentIPCResponseResult()
        }
        return try respawnLivePane(respawnPaneRequest(arguments: arguments), context: &context)
    }

    static func respawnPaneRequest(arguments: [String]) -> RespawnPaneRequest {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-c", "-e", "-t"], boolFlags: ["-k"])
        return RespawnPaneRequest(
            target: parsed.value("-t"),
            command: commandText(from: parsed.positionals),
            workingDirectory: parsed.value("-c"),
            environment: parsed.values("-e"),
            kill: parsed.hasFlag("-k")
        )
    }

    /// General `respawn-pane`: a deferred pane is launched with the command;
    /// a live pane is replaced (only with `-k`, as in tmux) by a new pane in
    /// the same column that takes over its tmux id, so the tool keeps
    /// addressing it as before. Only panes a tool may close are replaced
    /// (see `mayClosePane`); others are left alone.
    @MainActor
    private static func respawnLivePane(
        _ request: RespawnPaneRequest,
        context: inout TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let location = try context.pane(request.target)
        let oldPaneID = PaneID(location.pane.id)
        let worklaneID = WorklaneID(location.window.id)
        let nativeCommand = request.command.flatMap { shellWrappedGhosttyCommand($0) }

        if location.pane.isLaunchDeferred, let nativeCommand {
            guard context.windowController.launchDeferredPane(id: oldPaneID, in: worklaneID, nativeCommand: nativeCommand) else {
                throw TmuxCompatIPCError.targetNotDeferred(oldPaneID)
            }
            return AgentIPCResponseResult()
        }
        guard request.kill else {
            throw TmuxCompatIPCError.paneStillActive("%\(location.pane.number)")
        }
        let key = worklaneID.rawValue
        let state = TmuxCompatSessionState.shared
        guard mayClosePane(
            oldPaneID.rawValue,
            callerPaneID: context.target.paneID.rawValue,
            anchor: TmuxCompatStoreIO.load().anchors[key],
            isShimCreated: state.isShimCreatedPane
        ) else {
            tmuxLogger.warning("respawn-pane -k left pane \(oldPaneID.rawValue, privacy: .public) alone: not a tmux-created pane")
            return AgentIPCResponseResult()
        }

        let workingDirectory = request.workingDirectory.map { directory in
            TmuxFormatRenderer.render(
                directory,
                context: context.formatContext(window: location.window, pane: location.pane, template: directory)
            )
        }
        var sessionRequest = TerminalSessionRequest(
            workingDirectory: workingDirectory ?? location.pane.workingDirectory,
            nativeCommand: nativeCommand,
            waitAfterNativeCommand: nativeCommand != nil
        )
        sessionRequest.environmentVariables = shimPaneEnvironment(
            assignments: request.environment,
            requestEnvironment: context.requestEnvironment,
            topology: context.topology
        )
        sessionRequest.environmentVariables["TMUX_PANE"] = "%\(location.pane.number)"
        let focusedPaneID = context.windowController.focusedPaneID(in: worklaneID)
        guard let newPaneID = context.windowController.splitWithLayout(
            in: worklaneID,
            placement: .afterFocused,
            isHorizontal: false,
            layout: .none,
            targetPaneID: oldPaneID,
            preserveFocusPaneID: focusedPaneID == oldPaneID ? nil : focusedPaneID,
            sessionRequest: sessionRequest
        ) else {
            throw TmuxCompatIPCError.createFailed("respawn-pane")
        }

        // The replacement inherits whether the shim created the pane: a
        // user's pane stays the user's, out of `kill-window`'s reach.
        let wasShimCreated = state.isShimCreatedPane(oldPaneID.rawValue)
        state.rebindPane(from: oldPaneID.rawValue, to: newPaneID.rawValue)
        state.forgetPane(oldPaneID.rawValue)
        if wasShimCreated {
            state.recordShimPane(newPaneID.rawValue, startCommand: request.command)
        } else {
            state.recordStartCommand(newPaneID.rawValue, startCommand: request.command)
        }
        TmuxCompatStoreIO.mutate { store in
            store.replacePane(oldPaneID.rawValue, with: newPaneID.rawValue, inWorklane: key)
        }
        // The anchor must point at the replacement before the old pane
        // closes, or closing a leader would cascade-close its teammates.
        context.windowController.refreshTeamAnchors()
        if !location.pane.title.isEmpty {
            context.windowController.setPaneTitle(id: newPaneID, title: location.pane.title)
        }
        context.windowController.closePane(id: oldPaneID)
        context.windowController.refreshTeamAnchors()
        return AgentIPCResponseResult()
    }

    /// Claude Code's exact deferred-launch shape: `-k -t <pane> -- <command>`
    /// with a single command argument. Anything else returns nil and goes
    /// through the general respawn path.
    static func respawnPaneLaunchRequest(
        arguments: [String],
        resolvePane: (String) -> PaneID?,
        loginShellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> RespawnPaneLaunchRequest? {
        guard arguments.count == 5,
              arguments[0] == "-k",
              arguments[1] == "-t",
              !arguments[2].isEmpty,
              arguments[3] == "--"
        else {
            return nil
        }
        let command = arguments[4]
        guard let paneID = resolvePane(arguments[2]),
              let nativeCommand = shellWrappedGhosttyCommand(command, loginShellPath: loginShellPath)
        else {
            return nil
        }
        return RespawnPaneLaunchRequest(paneID: paneID, nativeCommand: nativeCommand)
    }

    // MARK: - select-pane

    @MainActor
    static func handleSelectPane(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t", "-T", "-P"],
            boolFlags: ["-D", "-d", "-e", "-g", "-L", "-l", "-M", "-m", "-R", "-U", "-Z"]
        )
        let location = try context.pane(parsed.value("-t"))
        let paneID = PaneID(location.pane.id)
        // Selecting records tmux's active pane without moving the user's
        // keyboard focus; the user decides which pane they type into.
        TmuxCompatStoreIO.mutate { store in
            store.activePaneIDs[location.window.id] = paneID.rawValue
        }
        if let title = parsed.value("-T") {
            context.windowController.setPaneTitle(id: paneID, title: title)
        }
        return AgentIPCResponseResult()
    }

    // MARK: - kill-pane / kill-window

    @MainActor
    static func handleKillPane(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-t"], boolFlags: ["-a"])
        let location = try context.pane(parsed.value("-t"))
        guard !parsed.hasFlag("-a") else {
            // `kill-pane -a` closes every *other* pane in the window, which in
            // Zentty would include the user's own panes. Not honoured.
            tmuxLogger.warning("kill-pane -a is not supported by the tmux shim")
            return AgentIPCResponseResult()
        }
        guard mayClosePane(
            location.pane.id,
            callerPaneID: context.target.paneID.rawValue,
            anchor: TmuxCompatStoreIO.load().anchors[location.window.id],
            isShimCreated: TmuxCompatSessionState.shared.isShimCreatedPane
        ) else {
            // tmux tools clean up with loops over `list-panes`; in Zentty that
            // list holds the user's own panes, which a tool must not close.
            tmuxLogger.warning("kill-pane left pane \(location.pane.id, privacy: .public) alone: not a tmux-created pane")
            return AgentIPCResponseResult()
        }
        closeTmuxPane(PaneID(location.pane.id), worklaneID: location.window.id, windowController: context.windowController)
        return AgentIPCResponseResult()
    }

    /// Closes one pane and keeps the teammate-column bookkeeping in step.
    /// `WorklaneStore.closePane(id:)` already cascade-closes the column when
    /// the leader goes; a teammate only needs its column membership pruned,
    /// and the last one restores the leader's pre-team width.
    @MainActor
    static func closeTmuxPane(_ paneID: PaneID, worklaneID key: String, windowController: MainWindowController) {
        var dissolvedTeamLeader: (paneID: PaneID, snapshotWidth: CGFloat)?
        TmuxCompatStoreIO.mutate { store in
            if var anchor = store.anchors[key],
               anchor.leaderPaneID != paneID.rawValue {
                anchor.columnPaneIDs.removeAll(where: { $0 == paneID.rawValue })
                if anchor.columnPaneIDs.isEmpty {
                    // Last teammate torn down: the team is dissolved. Drop the
                    // anchor so the leader marker disappears even if the
                    // leader keeps running.
                    if let snapshot = anchor.preTeamLeaderColumnWidth {
                        dissolvedTeamLeader = (PaneID(anchor.leaderPaneID), snapshot)
                    }
                    store.anchors.removeValue(forKey: key)
                } else {
                    store.anchors[key] = anchor
                }
            }
            if store.activePaneIDs[key] == paneID.rawValue {
                store.activePaneIDs.removeValue(forKey: key)
            }
        }
        TmuxCompatSessionState.shared.forgetPane(paneID.rawValue)
        windowController.closePane(id: paneID)
        windowController.refreshTeamAnchors()
        if let dissolved = dissolvedTeamLeader {
            windowController.resizeColumnContainingPaneToWidth(
                id: dissolved.paneID,
                width: dissolved.snapshotWidth
            )
        }
    }

    /// `kill-window` closes the panes the shim created in that tmux window
    /// (a worklane, or a pane group a `new-window` call made) and leaves the
    /// lead pane, other windows' panes and the user's own panes alone.
    @MainActor
    static func handleKillWindow(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-t"], boolFlags: ["-a"])
        let window = try context.window(parsed.value("-t"))
        let doomed = panesToCloseForKillWindow(
            window,
            anchor: TmuxCompatStoreIO.load().anchors[window.id],
            isShimCreated: TmuxCompatSessionState.shared.isShimCreatedPane
        )
        for paneID in doomed {
            closeTmuxPane(PaneID(paneID), worklaneID: window.id, windowController: context.windowController)
        }
        return AgentIPCResponseResult()
    }

    // MARK: - which panes a tool may close

    /// A tool may close or replace its own pane and panes the shim created
    /// (or the team column recorded), never the user's other panes.
    static func mayClosePane(
        _ paneID: String,
        callerPaneID: String,
        anchor: WorklaneAnchor?,
        isShimCreated: (String) -> Bool
    ) -> Bool {
        paneID == callerPaneID
            || isShimCreated(paneID)
            || anchor?.columnPaneIDs.contains(paneID) == true
    }

    /// The panes `kill-window` closes in `window`: shim-created or team
    /// column panes of that window only, never the team's lead.
    static func panesToCloseForKillWindow(
        _ window: TmuxTopology.Window,
        anchor: WorklaneAnchor?,
        isShimCreated: (String) -> Bool
    ) -> [String] {
        window.panes.map(\.id).filter { paneID in
            paneID != anchor?.leaderPaneID
                && (isShimCreated(paneID) || anchor?.columnPaneIDs.contains(paneID) == true)
        }
    }

    // MARK: - select-layout / resize-pane

    @MainActor
    static func handleSelectLayout(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        // Zentty keeps its own lead + teammate-column layout. Layout presets
        // only rebalance the teammate stack and the lead/teammate split.
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-t"], boolFlags: ["-E", "-n", "-o", "-p"])
        let window = try context.window(parsed.value("-t"))
        let preset = parsed.positionals.first ?? "main-vertical"
        guard ["main-vertical", "even-vertical", "tiled", "main-horizontal", "even-horizontal"].contains(preset) else {
            return AgentIPCResponseResult()
        }
        context.windowController.equalizeFocusedColumnPaneHeights()
        if let leaderPaneID = TmuxCompatStoreIO.load().anchors[window.id]?.leaderPaneID {
            context.windowController.resizeColumnContainingPane(
                id: PaneID(leaderPaneID),
                in: WorklaneID(window.id),
                toFraction: goldenWideFraction
            )
        }
        return AgentIPCResponseResult()
    }

    @MainActor
    static func handleResizePane(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t", "-x", "-y"],
            boolFlags: ["-D", "-L", "-M", "-R", "-T", "-U", "-Z"]
        )
        let location = try context.pane(parsed.value("-t"))
        guard let width = parsed.value("-x"),
              width.hasSuffix("%"),
              let anchor = TmuxCompatStoreIO.load().anchors[location.window.id] else {
            return AgentIPCResponseResult()
        }

        // Tools emit `resize-pane -x 30%` after `main-vertical`. Keep the
        // lead/teammate split at Zentty's golden ratio instead of applying
        // the exact tmux width hint.
        context.windowController.resizeColumnContainingPane(
            id: PaneID(anchor.leaderPaneID),
            in: WorklaneID(location.window.id),
            toFraction: goldenWideFraction
        )
        return AgentIPCResponseResult()
    }
}
