import AppKit

/// The canvas geometry + pane-strip presentation surface the pane command
/// executor needs, kept as a narrow protocol so the executor stays testable
/// without a live `AppCanvasView`.
@MainActor
protocol PaneCanvasGeometry: AnyObject {
    var boundsSize: CGSize { get }
    var leadingVisibleInset: CGFloat { get }
    func settlePaneStripPresentationNow()
    func centerFocusedInteriorPaneOnNextRender()
    func clearPendingPaneStripTargetOffsetOverride()
    func shiftPaneStripTargetOffsetOnNextRender(by: CGFloat)
}

extension AppCanvasView: PaneCanvasGeometry {
    var boundsSize: CGSize { bounds.size }
}

/// Owns pane-level commands: keyboard/IPC-driven splits, grids, resizes,
/// arrangement presets, and pane/worklane close flows. It talks to the worklane
/// store and the canvas geometry, and reaches back into the view controller only
/// through `UIHooks` (close confirmation, toast, window close).
@MainActor
final class PaneCommandExecutor {
    private enum PaneResize {
        static let minimumColumns: CGFloat = 5
        static let minimumRows: CGFloat = 5
    }

    struct UIHooks {
        var presentClosePaneConfirmation: (WorklaneStore.PaneCloseReason, @escaping () -> Void) -> Void
        var showToast: (String) -> Void
        var requestWindowClose: () -> Void
    }

    private let worklaneStore: WorklaneStore
    private let configStore: AppConfigStore
    private let runtimeRegistry: PaneRuntimeRegistry
    private let canvas: any PaneCanvasGeometry
    private let hooks: UIHooks

    init(
        worklaneStore: WorklaneStore,
        configStore: AppConfigStore,
        runtimeRegistry: PaneRuntimeRegistry,
        canvas: any PaneCanvasGeometry,
        hooks: UIHooks
    ) {
        self.worklaneStore = worklaneStore
        self.configStore = configStore
        self.runtimeRegistry = runtimeRegistry
        self.canvas = canvas
        self.hooks = hooks
    }

    private func handleHorizontalKeyboardResize(delta: CGFloat) {
        guard let action = worklaneStore.focusedHorizontalKeyboardResizeAction(for: delta) else {
            return
        }
        switch action {
        case .interior:
            let shouldCenterMiddlePane =
                shouldCenterFocusedInteriorPaneAfterHorizontalKeyboardResize()
            if shouldCenterMiddlePane {
                canvas.centerFocusedInteriorPaneOnNextRender()
            }
            let didResize = worklaneStore.resizeFocusedPane(
                in: .horizontal,
                delta: delta,
                availableSize: canvas.boundsSize,
                leadingVisibleInset: canvas.leadingVisibleInset,
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
            )
            if shouldCenterMiddlePane, !didResize {
                canvas.clearPendingPaneStripTargetOffsetOverride()
            }
        case .edge(let target):
            let appliedWidthDelta = worklaneStore.resize(
                .horizontalEdge(target),
                delta: delta,
                availableSize: canvas.boundsSize,
                leadingVisibleInset: canvas.leadingVisibleInset,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
            if target.edge == .left, abs(appliedWidthDelta) > 0.001 {
                canvas.shiftPaneStripTargetOffsetOnNextRender(by: appliedWidthDelta)
            }
        }
    }

    func handlePaneCommand(_ command: PaneCommand) {
        switch command {
        case .resizeLeft:
            canvas.settlePaneStripPresentationNow()
            handleHorizontalKeyboardResize(delta: -keyboardResizeStep(for: .horizontal))
        case .resizeRight:
            canvas.settlePaneStripPresentationNow()
            handleHorizontalKeyboardResize(delta: keyboardResizeStep(for: .horizontal))
        case .resizeUp:
            canvas.settlePaneStripPresentationNow()
            worklaneStore.resizeFocusedPane(
                in: .vertical,
                delta: resolvedVerticalKeyboardResizeDelta(keyboardResizeStep(for: .vertical)),
                availableSize: canvas.boundsSize,
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
            )
        case .resizeDown:
            canvas.settlePaneStripPresentationNow()
            worklaneStore.resizeFocusedPane(
                in: .vertical,
                delta: resolvedVerticalKeyboardResizeDelta(-keyboardResizeStep(for: .vertical)),
                availableSize: canvas.boundsSize,
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
            )
        case .arrangeHorizontally(let arrangement):
            canvas.settlePaneStripPresentationNow()
            worklaneStore.arrangeActiveWorklaneHorizontally(
                arrangement,
                availableWidth: canvas.boundsSize.width,
                leadingVisibleInset: canvas.leadingVisibleInset
            )
        case .arrangeVertically(let arrangement):
            canvas.settlePaneStripPresentationNow()
            worklaneStore.arrangeActiveWorklaneVertically(arrangement)
        case .arrangeGoldenRatio(let preset):
            canvas.settlePaneStripPresentationNow()
            switch preset {
            case .focusWide, .focusNarrow:
                worklaneStore.arrangeActiveWorklaneGoldenWidth(
                    focusWide: preset == .focusWide,
                    availableWidth: canvas.boundsSize.width,
                    leadingVisibleInset: canvas.leadingVisibleInset
                )
            case .focusTall, .focusShort:
                worklaneStore.arrangeActiveWorklaneGoldenHeight(
                    focusTall: preset == .focusTall,
                    availableSize: canvas.boundsSize
                )
            }
        case .resetLayout:
            worklaneStore.resetActiveWorklaneLayout()
        case .closeFocusedPane:
            let focusedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID
            if configStore.current.confirmations.confirmBeforeClosingPane,
                let focusedPaneID,
                let reason = worklaneStore.paneCloseConfirmationReason(focusedPaneID)
            {
                hooks.presentClosePaneConfirmation(reason) { [weak self] in
                    self?.closeFocusedPane()
                }
            } else {
                closeFocusedPane()
            }
        case .restoreClosedPane:
            performRestoreClosedPane()
        default:
            worklaneStore.send(command)
        }
    }

    func closePane(id paneID: PaneID) {
        handlePaneCloseResult(worklaneStore.closePane(id: paneID))
    }

    private func performRestoreClosedPane() {
        if let result = worklaneStore.restoreClosedPane() {
            showRestoreToast(message: result.toastMessage)
        } else {
            showRestoreToast(message: "No recently closed pane to restore")
        }
    }

    private func showRestoreToast(message: String) {
        hooks.showToast(message)
    }

    private func closeFocusedPane() {
        handlePaneCloseResult(worklaneStore.closeFocusedPane())
    }

    func handlePaneCloseResult(_ result: WorklaneStore.PaneCloseResult) {
        switch result {
        case .closed, .notFound:
            return
        case .closeWindow:
            hooks.requestWindowClose()
        }
    }

    private func shouldCenterFocusedInteriorPaneAfterHorizontalKeyboardResize() -> Bool {
        guard
            let state = worklaneStore.activeWorklane?.paneStripState,
            let focusedColumnID = state.focusedColumnID,
            let focusedColumnIndex = state.columns.firstIndex(where: { $0.id == focusedColumnID })
        else {
            return false
        }

        return state.columns.count > 2
            && focusedColumnIndex > 0
            && focusedColumnIndex + 1 < state.columns.count
    }

    private func keyboardResizeStep(for axis: PaneResizeAxis) -> CGFloat {
        let minimumSizesByPaneID = paneMinimumSizesByPaneID()
        guard let focusedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID,
            let minimumSize = minimumSizesByPaneID[focusedPaneID]
        else {
            switch axis {
            case .horizontal:
                return max(1, PaneMinimumSize.fallback.width / PaneResize.minimumColumns)
            case .vertical:
                return max(1, PaneMinimumSize.fallback.height / PaneResize.minimumRows)
            }
        }

        switch axis {
        case .horizontal:
            return max(1, minimumSize.width / PaneResize.minimumColumns)
        case .vertical:
            return max(1, minimumSize.height / PaneResize.minimumRows)
        }
    }

    private func resolvedVerticalKeyboardResizeDelta(_ delta: CGFloat) -> CGFloat {
        guard
            worklaneStore.activeWorklane?.paneStripState.shouldInvertVerticalKeyboardResizeDelta()
                == true
        else {
            return delta
        }

        return -delta
    }

    func paneMinimumSizesByPaneID() -> [PaneID: PaneMinimumSize] {
        guard let worklane = worklaneStore.activeWorklane else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: worklane.paneStripState.panes.map { pane in
                let runtime = runtimeRegistry.runtime(for: pane)
                let minimumWidth =
                    runtime.cellWidth > 0
                    ? max(
                        PaneMinimumSize.fallback.width,
                        runtime.cellWidth * PaneResize.minimumColumns)
                    : PaneMinimumSize.fallback.width
                let minimumHeight =
                    runtime.cellHeight > 0
                    ? max(
                        PaneMinimumSize.fallback.height, runtime.cellHeight * PaneResize.minimumRows
                    )
                    : PaneMinimumSize.fallback.height
                return (pane.id, PaneMinimumSize(width: minimumWidth, height: minimumHeight))
            })
    }

    // MARK: - Pane IPC

    @discardableResult
    func splitWithLayout(
        placement: PanePlacement,
        isHorizontal: Bool,
        layout: SplitLayoutAction,
        targetPaneID: PaneID? = nil,
        preserveFocusPaneID: PaneID? = nil,
        sessionRequest: TerminalSessionRequest? = nil
    ) -> PaneID? {
        canvas.settlePaneStripPresentationNow()
        return worklaneStore.splitWithLayout(
            placement: placement,
            isHorizontal: isHorizontal,
            layout: layout,
            availableWidth: canvas.boundsSize.width,
            leadingVisibleInset: canvas.leadingVisibleInset,
            availableSize: canvas.boundsSize,
            minimumSizeByPaneID: paneMinimumSizesByPaneID(),
            targetPaneID: targetPaneID,
            preserveFocusPaneID: preserveFocusPaneID,
            sessionRequest: sessionRequest
        )
    }

    @discardableResult
    func applyGrid(
        sourcePaneID: PaneID,
        rows: Int,
        columns: Int,
        command: String?,
        includeSource: Bool,
        focus: GridFocus
    ) throws -> GridApplicationResult {
        canvas.settlePaneStripPresentationNow()
        return try worklaneStore.applyGrid(
            sourcePaneID: sourcePaneID,
            rows: rows,
            columns: columns,
            command: command,
            includeSource: includeSource,
            focus: focus
        )
    }

    @discardableResult
    func createWorklaneForGrid() -> WorklaneID {
        worklaneStore.createWorklane()
    }

    func gridWindowWorkspaceState(
        inheritingFrom sourcePaneID: PaneID,
        destinationWindowID: WindowID
    ) -> WindowWorkspaceState? {
        worklaneStore.gridWindowWorkspaceState(
            inheritingFrom: sourcePaneID,
            destinationWindowID: destinationWindowID
        )
    }

    func focusPaneByID(_ paneID: PaneID, in worklaneID: WorklaneID) {
        worklaneStore.selectWorklane(id: worklaneID)
        worklaneStore.focusPane(id: paneID)
    }

    @discardableResult
    func launchDeferredPane(id paneID: PaneID, nativeCommand: String) -> Bool {
        worklaneStore.launchDeferredPane(id: paneID, nativeCommand: nativeCommand)
    }

    @discardableResult
    func setPaneTitle(id paneID: PaneID, title: String) -> Bool {
        worklaneStore.setPaneTitle(id: paneID, title: title)
    }

    @discardableResult
    func setWorklaneColor(_ color: WorklaneColor?, on id: WorklaneID) -> Bool {
        worklaneStore.setColor(color, on: id)
    }

    @discardableResult
    func setWorklaneTitle(_ title: String?, on id: WorklaneID) -> Bool {
        worklaneStore.setTitle(title, on: id)
    }

    @discardableResult
    func setPaneCustomTitle(_ title: String?, on paneID: PaneID) -> Bool {
        worklaneStore.setPaneCustomTitle(title, on: paneID)
    }

    func resizeFocusedColumnToFraction(_ fraction: CGFloat) {
        canvas.settlePaneStripPresentationNow()
        worklaneStore.resizeFocusedColumnToFraction(
            fraction,
            availableWidth: canvas.boundsSize.width,
            leadingVisibleInset: canvas.leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
    }

    func resizeColumnContainingPane(id paneID: PaneID, toFraction fraction: CGFloat) {
        canvas.settlePaneStripPresentationNow()
        worklaneStore.resizeColumnContainingPane(
            id: paneID,
            toFraction: fraction,
            availableWidth: canvas.boundsSize.width,
            leadingVisibleInset: canvas.leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
    }

    func columnWidthForPane(id paneID: PaneID, in worklaneID: WorklaneID) -> CGFloat? {
        worklaneStore.columnWidthForPane(id: paneID, in: worklaneID)
    }

    func resizeColumnContainingPaneToWidth(id paneID: PaneID, width: CGFloat) {
        canvas.settlePaneStripPresentationNow()
        let availableWidth = canvas.boundsSize.width
        let leadingVisibleInset = canvas.leadingVisibleInset
        canvas.centerFocusedInteriorPaneOnNextRender()
        let didResize = worklaneStore.resizeColumnContainingPanePreservingNeighbors(
            id: paneID,
            toWidth: width,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
        if !didResize {
            canvas.clearPendingPaneStripTargetOffsetOverride()
        }
    }

    func resizeFocusedPaneHeightToFraction(_ fraction: CGFloat) {
        worklaneStore.resizeFocusedPaneHeightToFraction(fraction)
    }

    func equalizeFocusedColumnPaneHeights() {
        worklaneStore.equalizeFocusedColumnPaneHeights()
    }

    func paneListEntries(for worklaneID: WorklaneID) -> [PaneListEntry] {
        guard let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }

        var entries: [PaneListEntry] = []
        var index = 1
        for (columnIndex, column) in worklane.paneStripState.columns.enumerated() {
            for pane in column.panes {
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                let isFocused = worklane.paneStripState.focusedPaneID == pane.id
                entries.append(
                    PaneListEntry(
                        index: index,
                        id: pane.id.rawValue,
                        column: columnIndex + 1,
                        title: WorklaneContextFormatter.trimmed(pane.customTitle) ?? pane.title,
                        workingDirectory: auxiliaryState?.shellContext?.path,
                        isFocused: isFocused,
                        agentTool: auxiliaryState?.agentStatus?.tool.displayName,
                        agentStatus: auxiliaryState?.agentStatus?.state.rawValue
                    ))
                index += 1
            }
        }
        return entries
    }

    func taskManagerPaneSources(windowID: WindowID, windowTitle: String) -> [TaskManagerPaneSource] {
        worklaneStore.worklanes.enumerated().flatMap { worklaneIndex, worklane in
            worklane.paneStripState.panes.map { pane in
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                return TaskManagerPaneSource(
                    windowID: windowID,
                    windowTitle: windowTitle,
                    worklaneID: worklane.id,
                    worklaneTitle: worklane.title ?? "Worklane \(worklaneIndex + 1)",
                    paneID: pane.id,
                    paneTitle: WorklaneContextFormatter.trimmed(pane.customTitle)
                        ?? auxiliaryState?.presentation.visibleIdentityText
                        ?? pane.title,
                    statusText: taskManagerStatusText(for: auxiliaryState),
                    rootPID: auxiliaryState?.raw.paneRootPID,
                    isRemote: auxiliaryState?.shellContext?.scope == .remote,
                    currentWorkingDirectory: PaneTerminalLocationResolver.snapshot(
                        metadata: auxiliaryState?.metadata,
                        shellContext: auxiliaryState?.shellContext,
                        requestWorkingDirectory: pane.sessionRequest.workingDirectory
                    ).workingDirectory
                )
            }
        }
    }

    private func taskManagerStatusText(for auxiliaryState: PaneAuxiliaryState?) -> String? {
        if let agentStatus = auxiliaryState?.agentStatus {
            return "\(agentStatus.tool.displayName) \(agentStatus.state.rawValue)"
        }

        switch auxiliaryState?.shellActivityState {
        case .commandRunning:
            return "Running"
        case .promptIdle:
            return "Idle"
        case .unknown, nil:
            return nil
        }
    }

    func resolvePaneID(_ target: String, in worklaneID: WorklaneID) -> PaneID? {
        guard let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }) else {
            return nil
        }

        if target.hasPrefix("pn_") {
            let paneID = PaneID(target)
            if worklane.paneStripState.panes.contains(where: { $0.id == paneID }) {
                return paneID
            }
            return nil
        }

        if let displayIndex = Int(target), displayIndex >= 1 {
            let allPanes = worklane.paneStripState.columns.flatMap(\.panes)
            if displayIndex <= allPanes.count {
                return allPanes[displayIndex - 1].id
            }
        }

        return nil
    }
}
