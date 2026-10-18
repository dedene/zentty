import AppKit
import Darwin
import Foundation

/// Everything one tmux-compat request needs on the main actor: the caller,
/// its window controller, and a tmux-shaped snapshot of that window.
@MainActor
struct TmuxCompatRequestContext {
    let target: AgentIPCTarget
    let windowController: MainWindowController
    let requestEnvironment: [String: String]
    /// False on the last attempt: a request waiting for a pane's pid then
    /// renders without it instead of retrying.
    let allowsPendingPanePID: Bool
    private(set) var topology: TmuxTopology

    init(
        target: AgentIPCTarget,
        windowController: MainWindowController,
        requestEnvironment: [String: String],
        allowsPendingPanePID: Bool
    ) {
        self.target = target
        self.windowController = windowController
        self.requestEnvironment = requestEnvironment
        self.allowsPendingPanePID = allowsPendingPanePID
        self.topology = TmuxCompatTopologyBuilder.make(windowController: windowController)
    }

    var resolver: TmuxTargetResolver {
        TmuxTargetResolver(topology: topology, callerPaneID: target.paneID.rawValue)
    }

    mutating func refresh() {
        topology = TmuxCompatTopologyBuilder.make(windowController: windowController)
    }

    /// Resolves a pane target, failing like tmux when it names nothing.
    func pane(_ selector: String?) throws -> (window: TmuxTopology.Window, pane: TmuxTopology.Pane) {
        guard let location = resolver.pane(selector) else {
            throw TmuxCompatIPCError.paneNotFound(selector ?? "%\(target.paneID.rawValue)")
        }
        return location
    }

    func window(_ selector: String?) throws -> TmuxTopology.Window {
        guard let window = resolver.window(selector) else {
            throw TmuxCompatIPCError.windowNotFound(selector ?? "")
        }
        return window
    }

    func formatContext(
        window: TmuxTopology.Window,
        pane: TmuxTopology.Pane,
        template: String
    ) -> [String: String] {
        TmuxFormatContext.pane(
            pane,
            window: window,
            in: topology,
            options: mergedOptions(paneID: pane.id, windowKey: window.optionsKey),
            currentCommand: template.contains("pane_current_command")
                ? TmuxPaneProcess.currentCommand(rootPID: pane.pid)
                : nil
        )
    }

    func formatContext(window: TmuxTopology.Window) -> [String: String] {
        var context = TmuxFormatContext.window(window, in: topology)
        for (name, value) in mergedOptions(paneID: nil, windowKey: window.optionsKey) {
            context[name] = value
        }
        return context
    }

    /// Throws `TmuxCompatPendingPanePID` when the template needs the pid of a
    /// pane the shim just created and whose shell has not reported it yet,
    /// so the handler can retry shortly. Older panes without a pid render
    /// with an empty `pane_pid` right away.
    func requirePanePIDIfNeeded(_ template: String, panes: [TmuxTopology.Pane]) throws {
        guard allowsPendingPanePID, template.contains("pane_pid") else {
            return
        }
        let state = TmuxCompatSessionState.shared
        if panes.contains(where: { pane in
            pane.pid == nil && !pane.isLaunchDeferred && state.isRecentShimPane(pane.id, within: 5)
        }) {
            throw TmuxCompatPendingPanePID()
        }
    }

    /// Options visible from a pane, inherited global -> session -> window -> pane.
    private func mergedOptions(paneID: String?, windowKey: String) -> [String: String] {
        let state = TmuxCompatSessionState.shared
        var merged = state.options(in: .global)
        merged.merge(state.options(in: .session(topology.session.id))) { _, new in new }
        merged.merge(state.options(in: .window(windowKey))) { _, new in new }
        if let paneID {
            merged.merge(state.options(in: .pane(paneID))) { _, new in new }
        }
        return merged
    }
}

struct TmuxCompatPendingPanePID: Error {}

@MainActor
enum TmuxCompatTopologyBuilder {
    /// Size reported for a pane whose surface does not exist yet.
    private static let fallbackGridSize = (columns: 80, rows: 24)

    static func make(windowController: MainWindowController) -> TmuxTopology {
        let state = TmuxCompatSessionState.shared
        let workspace = windowController.discoveryWorkspaceState
        let activePaneIDs = TmuxCompatStoreIO.load().activePaneIDs
        let windowID = windowController.windowID.rawValue

        var worklaneWindows: [TmuxTopology.Window] = []
        var groupWindows: [TmuxTopology.Window] = []
        var nextGroupIndex = workspace.worklanes.count
        for (worklaneIndex, worklane) in workspace.worklanes.enumerated() {
            let window = makeWindow(
                worklane: worklane,
                index: worklaneIndex,
                isActive: worklane.id == workspace.activeWorklaneID,
                activePaneID: activePaneIDs[worklane.id.rawValue],
                windowController: windowController,
                state: state
            )
            let split = TmuxTopology.splittingPaneGroups(
                window,
                focusedPaneID: worklane.paneStripState.focusedPaneID?.rawValue,
                groupOf: state.paneGroup(for:),
                groupNumber: state.windowNumber(for:),
                nextGroupIndex: &nextGroupIndex
            )
            worklaneWindows.append(split.worklane)
            groupWindows.append(contentsOf: split.groups)
        }
        let windows = worklaneWindows + groupWindows

        return TmuxTopology(
            session: TmuxTopology.Session(
                id: windowID,
                number: state.sessionNumber(for: windowID),
                name: "zentty",
                created: state.sessionCreatedTimestamp(for: windowID),
                windows: windows
            ),
            socketPath: WorklaneSessionEnvironment.tmuxSocketPath,
            serverPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private static func makeWindow(
        worklane: WorklaneState,
        index: Int,
        isActive: Bool,
        activePaneID: String?,
        windowController: MainWindowController,
        state: TmuxCompatSessionState
    ) -> TmuxTopology.Window {
        let strip = worklane.paneStripState
        let knownActive = activePaneID.flatMap { id in strip.panes.contains(where: { $0.id.rawValue == id }) ? id : nil }
        let resolvedActive = knownActive ?? strip.focusedPaneID?.rawValue

        var panes: [TmuxTopology.Pane] = []
        var left = 0
        var windowRows = 0
        for column in strip.columns {
            var top = 0
            var columnCells = 0
            for pane in column.panes {
                let grid = windowController.terminalGridSize(for: pane.id) ?? fallbackGridSize
                let columns = grid.columns
                let rows = grid.rows
                let auxiliary = worklane.auxiliaryStateByPaneID[pane.id]
                panes.append(TmuxTopology.Pane(
                    id: pane.id.rawValue,
                    number: state.paneNumber(for: pane.id.rawValue),
                    index: panes.count,
                    title: WorklaneContextFormatter.trimmed(pane.customTitle) ?? pane.title,
                    workingDirectory: auxiliary?.shellContext?.path ?? pane.sessionRequest.workingDirectory,
                    isActive: pane.id.rawValue == resolvedActive,
                    pid: state.pinnedPanePID(for: pane.id.rawValue, observed: auxiliary?.raw.paneRootPID),
                    columns: columns,
                    rows: rows,
                    left: left,
                    top: top,
                    startCommand: state.startCommand(for: pane.id.rawValue) ?? pane.sessionRequest.command ?? "",
                    isLaunchDeferred: pane.sessionRequest.isLaunchDeferred
                ))
                top += rows + 1
                columnCells = max(columnCells, columns)
            }
            windowRows = max(windowRows, max(top - 1, 0))
            left += columnCells + 1
        }

        return TmuxTopology.Window(
            id: worklane.id.rawValue,
            number: state.windowNumber(for: worklane.id.rawValue),
            index: index,
            name: worklane.title ?? "worklane-\(index)",
            isActive: isActive,
            panes: panes,
            columns: max(left - 1, 1),
            rows: max(windowRows, 1)
        )
    }
}

/// `pane_current_command`: the name of the pane's foreground process.
enum TmuxPaneProcess {
    static func currentCommand(rootPID: Int32?) -> String {
        guard let rootPID, rootPID > 0,
              let root = DarwinProcessInspector.foregroundInfo(rootPID) else {
            return ""
        }
        let foregroundGroup = root.foregroundProcessGroupID
        if foregroundGroup > 0, foregroundGroup != rootPID,
           let leader = DarwinProcessInspector.foregroundInfo(foregroundGroup) {
            return leader.name
        }
        return root.name
    }
}
