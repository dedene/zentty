import AppKit
import Foundation
import OSLog

let tmuxLogger = Logger(subsystem: "be.zenjoy.zentty", category: "tmux-compat")

struct RespawnPaneLaunchRequest: Equatable {
    let paneID: PaneID
    let nativeCommand: String
}

enum TmuxCompatIPCError: LocalizedError {
    case invalidRespawnPane
    case targetNotDeferred(PaneID)
    case targetUnavailable
    case paneNotFound(String)
    case windowNotFound(String)
    case sessionNotFound(String)
    case paneStillActive(String)
    case createFailed(String)

    /// Messages for the tmux-shaped cases match tmux's own wording; tools
    /// match on `can't find pane` / `can't find session`.
    var errorDescription: String? {
        switch self {
        case .invalidRespawnPane:
            "Unsupported respawn-pane arguments; expected -k -t <pane> -- <command>."
        case let .targetNotDeferred(paneID):
            "Cannot respawn pane %\(paneID.rawValue): it is not awaiting a launch command."
        case .targetUnavailable:
            "Cannot route tmux command: the target Zentty worklane or pane is no longer available."
        case let .paneNotFound(target):
            "can't find pane: \(target)"
        case let .windowNotFound(target):
            "can't find window: \(target)"
        case let .sessionNotFound(target):
            "can't find session: \(target)"
        case let .paneStillActive(paneID):
            "respawn pane failed: pane \(paneID) still active"
        case let .createFailed(command):
            "\(command): create pane failed"
        }
    }
}

/// Translates tmux commands from tmux-based agent orchestrators (Claude Code
/// agent teams and similar tools) into Zentty window-controller and worklane
/// operations, so their teammate panes stay inside Zentty's layout model.
/// Sequences, `if-shell` and `run-shell` are handled by the CLI
/// (`TmuxCommandRunner`); every command that reaches this handler is one
/// tmux command.
enum TmuxCompatIPCHandler {
    /// How long a request that needs a pane's pid waits for the pane's shell
    /// to report it.
    private static let panePIDWaitAttempts = 20
    private static let panePIDWaitInterval: TimeInterval = 0.1

    static func handle(
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let rawSubcommand = request.subcommand else {
            throw AgentIPCError.invalidMessage
        }
        let subcommand = TmuxCommandLine.canonicalName(rawSubcommand)

        tmuxLogger.debug(
            "tmux \(subcommand, privacy: .public) args=\(request.arguments.joined(separator: " "), privacy: .public)"
        )

        if subcommand == "wait-for" {
            trace(event: "ipc_wait_for", request: request, fields: ["phase": "local"])
            return handleWaitFor(arguments: request.arguments, environment: request.environment)
        }

        var captured = AgentIPCResponseResult()
        var dispatchError: Error?
        for attempt in 0..<panePIDWaitAttempts {
            let allowsPending = attempt < panePIDWaitAttempts - 1
            dispatchError = nil
            DispatchQueue.main.sync {
                MainActorShim.assumeIsolated {
                    do {
                        captured = try Self.dispatch(
                            subcommand: subcommand,
                            arguments: request.arguments,
                            standardInput: request.standardInput,
                            environment: request.environment,
                            target: target,
                            allowsPendingPanePID: allowsPending
                        )
                    } catch {
                        dispatchError = error
                    }
                }
            }
            guard dispatchError is TmuxCompatPendingPanePID else {
                break
            }
            Thread.sleep(forTimeInterval: panePIDWaitInterval)
        }
        if let dispatchError {
            trace(event: "ipc_error", request: request, fields: ["error": String(describing: dispatchError)])
            throw dispatchError
        }
        trace(
            event: "ipc_result",
            request: request,
            fields: [
                "stdout_bytes": "\(captured.stdout?.utf8.count ?? 0)",
                "pane_count": "\(captured.paneList?.count ?? 0)",
            ]
        )
        return captured
    }

    @MainActor
    private static func dispatch(
        subcommand: String,
        arguments: [String],
        standardInput: String?,
        environment: [String: String],
        target: AgentIPCTarget,
        allowsPendingPanePID: Bool
    ) throws -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let windowController = resolveWindowController(for: target, appDelegate: appDelegate) else {
            return try unresolvedTargetResult(for: subcommand)
        }
        var context = TmuxCompatRequestContext(
            target: target,
            windowController: windowController,
            requestEnvironment: environment,
            allowsPendingPanePID: allowsPendingPanePID
        )

        switch subcommand {
        case "split-window":
            return try handleCreatePane(.split, arguments: arguments, context: &context)
        case "new-window":
            return try handleCreatePane(.window, arguments: arguments, context: &context)
        case "new-session":
            return try handleNewSession(arguments: arguments, context: &context)
        case "send-keys":
            return try handleSendKeys(arguments: arguments, standardInput: standardInput, context: context)
        case "respawn-pane":
            return try handleRespawnPane(arguments: arguments, context: &context)
        case "set-option":
            return try handleSetOption(arguments: arguments, impliedScope: nil, context: context)
        case "set-window-option":
            return try handleSetOption(arguments: arguments, impliedScope: "-w", context: context)
        case "show-options":
            return try handleShowOptions(arguments: arguments, impliedScope: nil, context: context)
        case "show-window-options":
            return try handleShowOptions(arguments: arguments, impliedScope: "-w", context: context)
        case "select-pane":
            return try handleSelectPane(arguments: arguments, context: context)
        case "kill-pane":
            return try handleKillPane(arguments: arguments, context: context)
        case "kill-window":
            return try handleKillWindow(arguments: arguments, context: context)
        case "list-panes":
            return try handleListPanes(arguments: arguments, context: context)
        case "list-windows":
            return try handleListWindows(arguments: arguments, context: context)
        case "list-sessions":
            return handleListSessions(arguments: arguments, context: context)
        case "has-session":
            return try handleHasSession(arguments: arguments, context: context)
        case "display-message":
            return try handleDisplayMessage(arguments: arguments, context: context)
        case "select-layout":
            return try handleSelectLayout(arguments: arguments, context: context)
        case "resize-pane":
            return try handleResizePane(arguments: arguments, context: context)
        case "show-buffer", "save-buffer":
            return handleSaveBuffer(arguments: arguments)
        case "set-buffer", "load-buffer":
            return handleSetBuffer(arguments: arguments, standardInput: standardInput)
        case "capture-pane":
            return try handleCapturePane(arguments: arguments, context: context)
        case "display-popup":
            throw AgentIPCError.unsupportedSubcommand("popup")
        case "kill-session", "kill-server":
            // Zentty's "session" is the user's whole window. Closing it on a
            // tool's cleanup call would take unrelated panes with it, so these
            // are acknowledged without closing anything.
            return AgentIPCResponseResult()
        default:
            // select-window, rename-window, last-pane, start-server,
            // set-hook, set-environment, switch-client, refresh-client, ...:
            // Zentty owns focus, naming and presentation, so these are
            // acknowledged as no-ops.
            tmuxLogger.debug("Acknowledging tmux subcommand without action: \(subcommand, privacy: .public)")
            return AgentIPCResponseResult()
        }
    }

    static func unresolvedTargetResult(for subcommand: String) throws -> AgentIPCResponseResult {
        switch TmuxCommandLine.canonicalName(subcommand) {
        case "split-window", "new-window", "respawn-pane":
            throw TmuxCompatIPCError.targetUnavailable
        default:
            return AgentIPCResponseResult()
        }
    }

    @MainActor
    static func resolveWindowController(
        for target: AgentIPCTarget,
        appDelegate: AppDelegate
    ) -> MainWindowController? {
        let exactController = target.windowID
            .flatMap(appDelegate.windowController(with:))
            .flatMap { controller in
                controller.containsPane(worklaneID: target.worklaneID, paneID: target.paneID) ? controller : nil
            }
        let paneOwner = appDelegate.orderedWindowControllersForDiscovery().first { controller in
            controller.containsPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
        return exactController
            ?? paneOwner
            ?? appDelegate.windowController(containingWorklane: target.worklaneID)
    }

    // MARK: - split-window / new-window / new-session

    enum PaneCreationKind {
        case split
        case window
        case session

        var commandName: String {
            switch self {
            case .split: "split-window"
            case .window: "new-window"
            case .session: "new-session"
            }
        }

        /// What `-P` prints without `-F`. tmux prints positional targets
        /// (`session:index.pane-index`); here they would shift whenever the
        /// user adds or closes a pane, so the defaults name the created pane
        /// or its pane-group window by id, in the same target grammar.
        var defaultPrintFormat: String {
            switch self {
            case .split: "#{session_name}:#{window_id}.#{pane_id}"
            case .window, .session: "#{session_name}:#{window_id}"
            }
        }

        /// new-window and new-session make a window of their own: the
        /// created pane starts a pane group.
        var startsPaneGroup: Bool {
            self != .split
        }
    }

    static let createPaneValueFlags: Set<String> = ["-c", "-e", "-F", "-l", "-n", "-p", "-s", "-t", "-x", "-y"]
    static let createPaneBoolFlags: Set<String> = ["-A", "-a", "-b", "-D", "-d", "-E", "-f", "-h", "-I", "-k", "-P", "-S", "-v", "-X", "-Z"]

    @MainActor
    private static func handleNewSession(
        arguments: [String],
        context: inout TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        // Tools only create detached sessions when they are not inside tmux.
        // Without `-P` nobody reads the result, so nothing is created; with
        // `-P` the caller wants a pane it can drive, which becomes a teammate
        // pane like `new-window`.
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: createPaneValueFlags, boolFlags: createPaneBoolFlags)
        guard parsed.hasFlag("-P") else {
            return AgentIPCResponseResult()
        }
        return try handleCreatePane(.session, arguments: arguments, context: &context)
    }

    @MainActor
    private static func handleCreatePane(
        _ kind: PaneCreationKind,
        arguments: [String],
        context: inout TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: createPaneValueFlags, boolFlags: createPaneBoolFlags)
        let anchorTarget: (window: TmuxTopology.Window, pane: TmuxTopology.Pane)
        switch kind {
        case .split:
            anchorTarget = try context.pane(parsed.value("-t"))
        case .window, .session:
            // `-t` names a window or session here. A teammate column is
            // anchored on the caller when it lives in that window.
            let window = kind == .session ? try context.window(nil) : try context.window(parsed.value("-t"))
            let caller = context.topology.location(ofPane: context.target.paneID.rawValue)
                .flatMap { $0.window.id == window.id ? $0.pane : nil }
            guard let pane = caller ?? window.activePane else {
                throw TmuxCompatIPCError.windowNotFound(parsed.value("-t") ?? "")
            }
            anchorTarget = (window, pane)
        }

        let worklaneID = WorklaneID(anchorTarget.window.id)
        let key = worklaneID.rawValue
        let preExisting = TmuxCompatStoreIO.load().anchors[key]
        var startupRequest = splitWindowStartupRequest(arguments: arguments, parsed: parsed)
        if let directory = parsed.value("-c") {
            startupRequest.workingDirectory = TmuxFormatRenderer.render(
                directory,
                context: context.formatContext(window: anchorTarget.window, pane: anchorTarget.pane, template: directory)
            )
        }
        startupRequest.environmentVariables = shimPaneEnvironment(
            assignments: parsed.values("-e"),
            requestEnvironment: context.requestEnvironment,
            topology: context.topology
        )
        let leaderPaneID = PaneID(preExisting?.leaderPaneID ?? anchorTarget.pane.id)

        // Snapshot the leader's column width BEFORE any split-window layout
        // disruption, but only on the team's first split (preExisting == nil).
        // Restored when the last teammate is killed so the pre-team layout
        // returns even when other columns existed alongside the leader.
        let preTeamLeaderColumnWidth: CGFloat? = preExisting == nil
            ? context.windowController.columnWidthForPane(id: leaderPaneID, in: worklaneID)
            : nil

        let newPaneID: PaneID?
        if preExisting == nil {
            // First teammate for this worklane: a new column right of the
            // leader at golden ratio, keeping the leader visually anchored.
            newPaneID = context.windowController.splitWithLayout(
                in: worklaneID,
                placement: .afterFocused,
                isHorizontal: true,
                layout: .golden,
                targetPaneID: leaderPaneID,
                preserveFocusPaneID: leaderPaneID,
                sessionRequest: startupRequest
            )
        } else {
            // Later teammates stack inside the existing teammate column
            // without moving the user's focus away from the leader.
            let stackTarget = preExisting?.columnPaneIDs.last.map(PaneID.init) ?? leaderPaneID
            newPaneID = context.windowController.splitWithLayout(
                in: worklaneID,
                placement: .afterFocused,
                isHorizontal: false,
                layout: .equal,
                targetPaneID: stackTarget,
                preserveFocusPaneID: leaderPaneID,
                sessionRequest: startupRequest
            )
        }

        guard let newPaneID else {
            throw TmuxCompatIPCError.createFailed(kind.commandName)
        }

        let state = TmuxCompatSessionState.shared
        state.recordShimPane(newPaneID.rawValue, startCommand: commandText(from: parsed.positionals))
        if kind.startsPaneGroup {
            state.assignPaneGroup(
                newPaneID.rawValue,
                group: TmuxCompatSessionState.paneGroupKey(creatorPaneID: newPaneID.rawValue)
            )
        } else if let group = anchorTarget.window.groupKey {
            // A split inside a pane group's window stays in that window.
            state.assignPaneGroup(newPaneID.rawValue, group: group)
        }
        TmuxCompatStoreIO.mutate { store in
            if var updatedAnchor = store.anchors[key] {
                updatedAnchor.columnPaneIDs.append(newPaneID.rawValue)
                store.anchors[key] = updatedAnchor
            } else {
                store.anchors[key] = WorklaneAnchor(
                    leaderPaneID: leaderPaneID.rawValue,
                    columnPaneIDs: [newPaneID.rawValue],
                    preTeamLeaderColumnWidth: preTeamLeaderColumnWidth
                )
            }
            // A new window's pane is active in its own window already; only a
            // split moves the active pane of the window it splits.
            if !parsed.hasFlag("-d"), !kind.startsPaneGroup {
                store.activePaneIDs[key] = newPaneID.rawValue
            }
        }
        context.windowController.refreshTeamAnchors()
        context.windowController.resizeColumnContainingPane(
            id: leaderPaneID,
            in: worklaneID,
            toFraction: goldenWideFraction
        )
        if let name = parsed.value("-n"), !name.isEmpty {
            context.windowController.setPaneTitle(id: newPaneID, title: name)
        }

        guard parsed.hasFlag("-P") else {
            return AgentIPCResponseResult()
        }
        context.refresh()
        let template = parsed.formatTemplate ?? kind.defaultPrintFormat
        guard let created = context.topology.location(ofPane: newPaneID.rawValue) else {
            return AgentIPCResponseResult(stdout: "%\(TmuxCompatSessionState.shared.paneNumber(for: newPaneID.rawValue))\n")
        }
        let rendered = TmuxFormatRenderer.render(
            template,
            context: context.formatContext(window: created.window, pane: created.pane, template: template)
        )
        return AgentIPCResponseResult(stdout: rendered + "\n")
    }

    /// Environment for a pane the shim creates: the shim environment (so the
    /// teammate can drive tmux too; `TMUX_PANE` and `PATH` are finished in
    /// `WorklaneStore` once the pane id exists) plus `-e` assignments.
    @MainActor
    static func shimPaneEnvironment(
        assignments: [String],
        requestEnvironment: [String: String],
        topology: TmuxTopology
    ) -> [String: String] {
        var environment: [String: String] = [:]
        if let shimDirectory = AgentStatusHelper.tmuxShimDirectoryPath() {
            environment[TmuxShimEnvironment.markerKey] = "1"
            environment[TmuxShimEnvironment.shimDirectoryKey] = shimDirectory
            environment["TMUX"] = TmuxShimEnvironment.tmuxValue(
                socketPath: topology.socketPath,
                serverPID: topology.serverPID,
                sessionNumber: topology.session.number
            )
            if let tracePath = requestEnvironment[TmuxShimEnvironment.tracePathKey], !tracePath.isEmpty {
                environment[TmuxShimEnvironment.tracePathKey] = tracePath
            }
        }
        let assigned = TmuxShimEnvironment.environmentAssignments(assignments)
        environment.merge(assigned) { _, new in new }
        if !assigned.isEmpty {
            environment[TmuxShimEnvironment.toolAssignedKeysKey] = assigned.keys.sorted().joined(separator: ",")
        }
        return environment
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static var goldenWideFraction: CGFloat {
        let phi = (1 + sqrt(CGFloat(5))) / 2
        return phi / (1 + phi)
    }
}
