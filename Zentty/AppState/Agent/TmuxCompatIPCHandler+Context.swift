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
                focusedPaneID: worklane.focusedPaneID?.rawValue,
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
        let knownActive = activePaneID.flatMap { id in worklane.containsPane(id: PaneID(id)) ? id : nil }
        let resolvedActive = knownActive ?? worklane.focusedPaneID?.rawValue

        let geometry = TmuxWindowGeometry.make(
            columns: strip.columns.map { $0.panes.map(\.id) },
            floats: worklane.floatingPanes.map(\.pane.id),
            gridSize: { windowController.terminalGridSize(for: $0) ?? fallbackGridSize }
        )
        let panesByID = Dictionary(
            worklane.allPanes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var panes: [TmuxTopology.Pane] = []
        for placement in geometry.placements {
            guard let pane = panesByID[placement.paneID] else { continue }
            let auxiliary = worklane.auxiliaryStateByPaneID[pane.id]
            panes.append(TmuxTopology.Pane(
                id: pane.id.rawValue,
                number: state.paneNumber(for: pane.id.rawValue),
                index: panes.count,
                title: WorklaneContextFormatter.trimmed(pane.customTitle) ?? pane.title,
                workingDirectory: auxiliary?.shellContext?.path ?? pane.sessionRequest.workingDirectory,
                isActive: pane.id.rawValue == resolvedActive,
                pid: state.pinnedPanePID(for: pane.id.rawValue, observed: auxiliary?.raw.paneRootPID),
                columns: placement.columns,
                rows: placement.rows,
                left: placement.left,
                top: placement.top,
                startCommand: state.startCommand(for: pane.id.rawValue) ?? pane.sessionRequest.command ?? "",
                isLaunchDeferred: pane.sessionRequest.isLaunchDeferred
            ))
        }

        return TmuxTopology.Window(
            id: worklane.id.rawValue,
            number: state.windowNumber(for: worklane.id.rawValue),
            index: index,
            name: worklane.title ?? "worklane-\(index)",
            isActive: isActive,
            panes: panes,
            columns: geometry.columns,
            rows: geometry.rows
        )
    }
}

/// Where each pane of a worklane sits in its tmux window, in cells. Strip
/// columns run left to right with a one-cell separator, panes stacked top to
/// bottom in each. Floats are listed after the strip at `0,0` with their own
/// size and stay out of the window size, so `window_width` and pane edges
/// describe the strip only. A float-only worklane takes its largest float's
/// size.
enum TmuxWindowGeometry {
    struct Placement: Equatable {
        let paneID: PaneID
        let left: Int
        let top: Int
        let columns: Int
        let rows: Int
    }

    struct Layout: Equatable {
        let placements: [Placement]
        let columns: Int
        let rows: Int
    }

    static func make(
        columns: [[PaneID]],
        floats: [PaneID],
        gridSize: (PaneID) -> (columns: Int, rows: Int)
    ) -> Layout {
        var placements: [Placement] = []
        var left = 0
        var windowRows = 0
        for column in columns {
            var top = 0
            var columnCells = 0
            for paneID in column {
                let grid = gridSize(paneID)
                placements.append(Placement(paneID: paneID, left: left, top: top, columns: grid.columns, rows: grid.rows))
                top += grid.rows + 1
                columnCells = max(columnCells, grid.columns)
            }
            windowRows = max(windowRows, max(top - 1, 0))
            left += columnCells + 1
        }
        var windowColumns = max(left - 1, 0)
        for paneID in floats {
            let grid = gridSize(paneID)
            placements.append(Placement(paneID: paneID, left: 0, top: 0, columns: grid.columns, rows: grid.rows))
            if columns.allSatisfy(\.isEmpty) {
                windowColumns = max(windowColumns, grid.columns)
                windowRows = max(windowRows, grid.rows)
            }
        }
        return Layout(placements: placements, columns: max(windowColumns, 1), rows: max(windowRows, 1))
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
