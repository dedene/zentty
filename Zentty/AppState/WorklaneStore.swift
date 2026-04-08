import Darwin
import Foundation
import os

private let worklaneReadyLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneReady")

struct WorklaneID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct WorklaneState: Equatable, Sendable {
    let id: WorklaneID
    var title: String
    var paneStripState: PaneStripState
    var nextPaneNumber: Int
    var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState]

    init(
        id: WorklaneID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.auxiliaryStateByPaneID = auxiliaryStateByPaneID
    }


}

struct WorklanePaneContext: Equatable, Sendable {
    let pane: PaneState
    let auxiliaryState: PaneAuxiliaryState?

    var paneID: PaneID { pane.id }
    var metadata: TerminalMetadata? { auxiliaryState?.metadata }
}

struct WorklaneOpenWithContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let paneID: PaneID
    let workingDirectory: String
    let scope: PaneShellContextScope
}

struct PaneBorderContextDisplayModel: Equatable, Sendable {
    let text: String
}

struct WorklaneAuxiliaryInvalidation: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let sidebar = WorklaneAuxiliaryInvalidation(rawValue: 1 << 0)
    static let header = WorklaneAuxiliaryInvalidation(rawValue: 1 << 1)
    static let canvas = WorklaneAuxiliaryInvalidation(rawValue: 1 << 2)
    static let attention = WorklaneAuxiliaryInvalidation(rawValue: 1 << 3)
    static let openWith = WorklaneAuxiliaryInvalidation(rawValue: 1 << 4)
    static let reviewRefresh = WorklaneAuxiliaryInvalidation(rawValue: 1 << 5)
    static let surfaceActivities = WorklaneAuxiliaryInvalidation(rawValue: 1 << 6)

    static let presentationChrome: WorklaneAuxiliaryInvalidation = [.sidebar, .header, .attention]
}

extension WorklaneState {
    var focusedPaneContext: WorklanePaneContext? {
        paneContext(for: paneStripState.focusedPaneID)
    }

    var paneContextsPrioritizingFocus: [WorklanePaneContext] {
        let panes = paneStripState.panes
        guard
            let focusedPaneID = paneStripState.focusedPaneID,
            let focusedPaneIndex = panes.firstIndex(where: { $0.id == focusedPaneID })
        else {
            return panes.map { WorklanePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
        }

        var orderedPanes = panes
        if focusedPaneIndex != 0 {
            let focusedPane = orderedPanes.remove(at: focusedPaneIndex)
            orderedPanes.insert(focusedPane, at: 0)
        }

        return orderedPanes.map { WorklanePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
    }

    func paneContext(for paneID: PaneID?) -> WorklanePaneContext? {
        guard
            let paneID,
            let pane = paneStripState.panes.first(where: { $0.id == paneID })
        else {
            return nil
        }

        return WorklanePaneContext(pane: pane, auxiliaryState: auxiliaryStateByPaneID[paneID])
    }

    var paneBorderContextDisplayByPaneID: [PaneID: PaneBorderContextDisplayModel] {
        auxiliaryStateByPaneID.compactMapValues { $0.shellContext?.displayModel }
    }
}

private extension PaneShellContext {
    var displayModel: PaneBorderContextDisplayModel? {
        switch scope {
        case .local:
            guard let compactPath = Self.compactPath(path, home: home) else {
                return nil
            }
            if compactPath == "~" {
                let identity = [user, host].compactMap { $0 }.joined(separator: "@")
                if !identity.isEmpty {
                    return PaneBorderContextDisplayModel(text: "\(identity):\(compactPath)")
                }
            }
            return PaneBorderContextDisplayModel(text: compactPath)
        case .remote:
            let identity = [user, host]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                .joined(separator: "@")
            let compactPath = Self.compactPath(path, home: home)

            if !identity.isEmpty, let compactPath, !compactPath.isEmpty {
                return PaneBorderContextDisplayModel(text: "\(identity) \(compactPath)")
            }

            if !identity.isEmpty {
                return PaneBorderContextDisplayModel(text: identity)
            }

            if let compactPath, !compactPath.isEmpty {
                return PaneBorderContextDisplayModel(text: compactPath)
            }

            return nil
        }
    }

    static func compactPath(_ path: String?, home: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        guard let home, !home.isEmpty, path.hasPrefix(home) else {
            return path
        }

        if path == home {
            return "~"
        }

        return path.replacingOccurrences(of: home, with: "~", options: [.anchored])
    }
}

enum WorklaneChange: Equatable, Sendable {
    case paneStructure(WorklaneID)
    case focusChanged(WorklaneID)
    case layoutResized(WorklaneID, animation: WorklaneLayoutResizeAnimation)
    case auxiliaryStateUpdated(WorklaneID, PaneID, WorklaneAuxiliaryInvalidation)
    /// Emitted by WorklaneStore.updateMetadata's volatile-title fast path when
    /// a codex pane's terminal title changes in a way that the classifier
    /// recognizes as `.volatileTitleOnly`. Consumers should call the surgical
    /// sidebar/chrome label setters (not a full render) to update the UI
    /// without re-running summary builders or auxiliary invalidation.
    case volatileAgentTitleUpdated(worklaneID: WorklaneID, paneID: PaneID)
    case activeWorklaneChanged
    case worklaneListChanged
    case historyChanged
}

enum WorklaneLayoutResizeAnimation: Equatable, Sendable {
    case immediate
    case splitCurve
}

struct WorklaneChangeSubscription {
    fileprivate let id: UUID
    fileprivate static let legacyID = UUID()
}

struct WorklaneRuntimeIdentity: Sendable {
    var nextOpaqueValue: @Sendable () -> String

    static let live = WorklaneRuntimeIdentity {
        UUID().uuidString.lowercased()
    }

    func makeWorklaneID() -> WorklaneID {
        WorklaneID("wl_\(nextOpaqueValue())")
    }

    func makePaneID() -> PaneID {
        PaneID("pn_\(nextOpaqueValue())")
    }
}

@MainActor
final class WorklaneStore {
    struct PaneReference: Hashable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private struct PaneLaunchContext {
        let path: String
        let scope: PaneShellContextScope?
    }

    var worklanes: [WorklaneState]
    let gitContextResolver: any PaneGitContextResolving
    let terminalDiagnostics: TerminalDiagnostics
    private(set) var layoutContext: PaneLayoutContext
    private var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedPaneReference: PaneReference?
    private var lastFocusedLocalPaneReference: PaneReference?
    private var lastFocusedLocalWorkingDirectory: String?
    var cachedGitContextByPath: [String: PaneGitContext] = [:]
    var knownNonRepositoryPaths: Set<String> = []
    var pendingGitContextPaths: Set<String> = []
    var waitingPaneReferencesByPath: [String: Set<PaneReference>] = [:]
    private var pendingReadyStatusTasks: [PaneReference: Task<Void, Never>] = [:]
    private let processEnvironment: [String: String]
    private let readyStatusDebounceInterval: TimeInterval
    let windowID: WindowID
    let runtimeIdentity: WorklaneRuntimeIdentity
    let focusHistoryController = PaneFocusHistoryController()
    private var isNavigatingHistory = false

    var activeWorklaneID: WorklaneID

    private var subscribers: [(id: UUID, handler: (WorklaneChange) -> Void)] = []
    private var isBatching = false

    /// Per-pane timestamp of the last emitted `.volatileAgentTitleUpdated`
    /// notification. Used by the volatile-title fast path to coalesce volatile
    /// ticks for non-active worklanes to ~0.5 Hz, reducing main-thread churn
    /// when multiple background worklanes run agents simultaneously. Active
    /// worklanes bypass the throttle so their spinner never visibly lags.
    var lastVolatileNotifyAt: [PaneID: Date] = [:]
    static let hiddenVolatileNotifyMinInterval: TimeInterval = 2.0

    @discardableResult
    func subscribe(_ handler: @escaping (WorklaneChange) -> Void) -> WorklaneChangeSubscription {
        let id = UUID()
        subscribers.append((id: id, handler: handler))
        return WorklaneChangeSubscription(id: id)
    }

    func unsubscribe(_ subscription: WorklaneChangeSubscription) {
        subscribers.removeAll { $0.id == subscription.id }
    }

    /// Deprecated compatibility shim — use subscribe() for new code.
    var onChange: ((WorklaneChange) -> Void)? {
        get { nil }
        set {
            subscribers.removeAll { $0.id == WorklaneChangeSubscription.legacyID }
            if let handler = newValue {
                subscribers.append((id: WorklaneChangeSubscription.legacyID, handler: handler))
            }
        }
    }

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        worklanes: [WorklaneState] = [],
        layoutContext: PaneLayoutContext = .fallback,
        activeWorklaneID: WorklaneID? = nil,
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        readyStatusDebounceInterval: TimeInterval = 0.25,
        runtimeIdentity: WorklaneRuntimeIdentity = .live,
        terminalDiagnostics: TerminalDiagnostics = .shared
    ) {
        self.windowID = windowID
        self.gitContextResolver = gitContextResolver
        self.terminalDiagnostics = terminalDiagnostics
        self.layoutContext = layoutContext
        self.processEnvironment = processEnvironment
        self.readyStatusDebounceInterval = readyStatusDebounceInterval
        self.runtimeIdentity = runtimeIdentity
        let initialWorklanes = worklanes.isEmpty
            ? WorklaneStore.defaultWorklanes(
                windowID: windowID,
                layoutContext: layoutContext,
                processEnvironment: processEnvironment,
                runtimeIdentity: runtimeIdentity
            )
            : worklanes
        let requestedActiveWorklaneID = activeWorklaneID ?? initialWorklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        let resolvedActiveWorklaneID = initialWorklanes.contains(where: { $0.id == requestedActiveWorklaneID })
            ? requestedActiveWorklaneID
            : initialWorklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        self.worklanes = initialWorklanes
        self.activeWorklaneID = resolvedActiveWorklaneID
        normalizeAllPanePresentationState()
        refreshLastFocusedLocalWorkingDirectory()
        refreshAllPaneGitContexts()

        focusHistoryController.onChange = { [weak self] in
            self?.notify(.historyChanged)
        }
    }

    var activeWorklane: WorklaneState? {
        get {
            worklanes.first { $0.id == activeWorklaneID }
        }
        set {
            guard let newValue, let index = worklanes.firstIndex(where: { $0.id == newValue.id }) else {
                return
            }

            worklanes[index] = newValue
        }
    }

    enum PaneCloseReason {
        case runningProcess
        case sessionHistory
    }

    func paneCloseConfirmationReason(_ paneID: PaneID) -> PaneCloseReason? {
        for worklane in worklanes {
            guard let aux = worklane.auxiliaryStateByPaneID[paneID] else { continue }
            return quitConfirmationReason(for: aux)
        }
        return nil
    }

    var anyPaneRequiresQuitConfirmation: Bool {
        worklanes.contains { worklane in
            worklane.auxiliaryStateByPaneID.values.contains {
                quitConfirmationReason(for: $0) != nil
            }
        }
    }

    private func quitConfirmationReason(for auxiliaryState: PaneAuxiliaryState) -> PaneCloseReason? {
        if auxiliaryState.shellActivityState == .commandRunning
            || auxiliaryState.terminalProgress?.state.indicatesActivity == true {
            return .runningProcess
        }

        if auxiliaryState.hasCommandHistory {
            return .sessionHistory
        }

        return nil
    }

    // MARK: - Focus History Navigation

    private var currentPaneReference: PaneReference? {
        guard let worklane = activeWorklane,
              let paneID = worklane.paneStripState.focusedPaneID else { return nil }
        return PaneReference(worklaneID: worklane.id, paneID: paneID)
    }

    private var allLivePaneReferences: Set<PaneReference> {
        Set(worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map {
                PaneReference(worklaneID: worklane.id, paneID: $0.id)
            }
        })
    }

    private var paneReferencesInSidebarOrder: [PaneReference] {
        worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map { pane in
                PaneReference(worklaneID: worklane.id, paneID: pane.id)
            }
        }
    }

    func navigateBack() {
        guard let current = currentPaneReference else { return }
        guard let target = focusHistoryController.navigateBack(
            current: current,
            allPaneIDs: allLivePaneReferences
        ) else { return }

        isNavigatingHistory = true
        defer { isNavigatingHistory = false }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    func navigateForward() {
        guard let current = currentPaneReference else { return }
        guard let target = focusHistoryController.navigateForward(
            current: current,
            allPaneIDs: allLivePaneReferences
        ) else { return }

        isNavigatingHistory = true
        defer { isNavigatingHistory = false }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    private func recordFocusTransition(from previous: PaneReference?) {
        guard !isNavigatingHistory, let previous else { return }
        focusHistoryController.recordFocusChange(from: previous)
    }

    private func focusPaneBySidebarOrder(offset: Int) {
        let paneReferences = paneReferencesInSidebarOrder
        guard paneReferences.count > 1,
              let current = currentPaneReference,
              let currentIndex = paneReferences.firstIndex(of: current) else {
            return
        }

        let nextIndex = (currentIndex + offset + paneReferences.count) % paneReferences.count
        let target = paneReferences[nextIndex]
        guard target != current else {
            return
        }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    var focusedOpenWithContext: WorklaneOpenWithContext? {
        guard let worklane = activeWorklane else {
            return nil
        }

        return focusedOpenWithContext(in: worklane)
    }

    var state: PaneStripState {
        activeWorklane?.paneStripState ?? .pocDefault
    }

    func updateLayoutContext(_ layoutContext: PaneLayoutContext) {
        let previousLayoutContext = self.layoutContext
        self.layoutContext = layoutContext
        var didUpdateWorklaneState = false
        let readableWidthScaleFactor = Self.readableWidthScaleFactor(
            from: previousLayoutContext,
            to: layoutContext
        )

        for index in worklanes.indices {
            if worklanes[index].paneStripState.updateLayoutSizing(layoutContext.sizing) {
                didUpdateWorklaneState = true
            }

            if worklanes[index].paneStripState.updateSingleColumnWidth(layoutContext.singlePaneWidth) {
                didUpdateWorklaneState = true
                continue
            }

            if let readableWidthScaleFactor,
               worklanes[index].paneStripState.scalePaneWidths(by: readableWidthScaleFactor) {
                didUpdateWorklaneState = true
            }
        }

        if didUpdateWorklaneState {
            notifyLayoutResized(animation: .immediate)
        }
    }

    func updatePaneViewportHeight(_ height: CGFloat) {
        paneViewportHeight = max(1, height)
    }

    func send(_ command: PaneCommand) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousPaneRef = currentPaneReference
        let changeType: WorklaneChange

        switch command {
        case .split, .splitHorizontally, .splitAfterFocusedPane:
            insertNewPaneHorizontally(into: &worklane, placement: .afterFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .splitVertically:
            insertNewPaneVertically(into: &worklane)
            changeType = .paneStructure(activeWorklaneID)
        case .splitBeforeFocusedPane:
            insertNewPaneHorizontally(into: &worklane, placement: .beforeFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .closeFocusedPane:
            _ = closeFocusedPane()
            return
        case .focusPreviousPaneBySidebarOrder:
            focusPaneBySidebarOrder(offset: -1)
            return
        case .focusNextPaneBySidebarOrder:
            focusPaneBySidebarOrder(offset: 1)
            return
        case .focusLeft:
            worklane.paneStripState.moveFocusLeft()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusRight:
            worklane.paneStripState.moveFocusRight()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusUp:
            if worklane.paneStripState.isFocusedPaneAtTopOfColumn {
                selectPreviousWorklane()
                return
            }
            worklane.paneStripState.moveFocusUp()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusDown:
            if worklane.paneStripState.isFocusedPaneAtBottomOfColumn {
                selectNextWorklane()
                return
            }
            worklane.paneStripState.moveFocusDown()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusFirst, .focusFirstColumn:
            worklane.paneStripState.moveFocusToFirstColumn()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusLast, .focusLastColumn:
            worklane.paneStripState.moveFocusToLastColumn()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .resizeLeft,
            .resizeRight,
            .resizeUp,
            .resizeDown,
            .arrangeHorizontally,
            .arrangeVertically,
            .arrangeGoldenRatio,
            .resetLayout,
            .toggleZoomOut:
            activeWorklane = worklane
            return
        }

        activeWorklane = worklane

        let newPaneRef = currentPaneReference
        if previousPaneRef != newPaneRef {
            recordFocusTransition(from: previousPaneRef)
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(changeType)
    }

    func markDividerInteraction(_ divider: PaneDivider) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState.markDividerInteraction(divider)
        activeWorklane = worklane
    }

    func resizeDivider(
        _ divider: PaneDivider,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resizeDivider(
            divider,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .immediate)
    }

    func resize(
        _ target: PaneResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resize(
            target,
            delta: delta,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .immediate)
    }

    func equalizeDivider(
        _ divider: PaneDivider,
        availableSize: CGSize
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.equalizeDivider(divider, availableSize: availableSize) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    @discardableResult
    func resizeFocusedPane(
        in axis: PaneResizeAxis,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> Bool {
        guard var worklane = activeWorklane else {
            return false
        }

        guard worklane.paneStripState.resizeFocusedPane(
            in: axis,
            delta: delta,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return false
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
        return true
    }

    func restorePaneLayout(_ paneStripState: PaneStripState) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState = paneStripState
        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func resetActiveWorklaneLayout() {
        guard var worklane = activeWorklane else {
            return
        }

        var columns = worklane.paneStripState.columns
        guard !columns.isEmpty else {
            return
        }

        let defaultColumnWidth = layoutContext.newPaneWidth
        let firstColumnWidth = columns.count == 1
            ? layoutContext.singlePaneWidth
            : (layoutContext.firstPaneWidthAfterSingleSplit ?? defaultColumnWidth)
        for index in columns.indices {
            let width: CGFloat
            if index == 0 {
                width = firstColumnWidth
            } else if columns.count == 2, layoutContext.firstPaneWidthAfterSingleSplit != nil {
                width = firstColumnWidth
            } else {
                width = defaultColumnWidth
            }
            columns[index].width = width
            columns[index].resetPaneHeights()
        }

        worklane.paneStripState = PaneStripState(
            columns: columns,
            focusedColumnID: worklane.paneStripState.focusedColumnID,
            layoutSizing: layoutContext.sizing
        )
        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneHorizontally(
        _ arrangement: PaneHorizontalArrangement,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeHorizontally(
            arrangement,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneVertically(_ arrangement: PaneVerticalArrangement) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeVertically(arrangement) else {
            return
        }

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneGoldenWidth(
        focusWide: Bool,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeGoldenWidth(focusWide: focusWide) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneGoldenHeight(
        focusTall: Bool,
        availableSize: CGSize
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeGoldenHeight(
            focusTall: focusTall,
            availableSize: availableSize
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    private func insertNewPaneHorizontally(into worklane: inout WorklaneState, placement: PanePlacement) {
        let existingColumnCount = worklane.paneStripState.columns.count
        let sourceWidth = worklane.paneStripState.focusedColumn?.width
            ?? worklane.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &worklane, existingPaneCount: existingColumnCount)
        insertedPane.width = sourceWidth

        if existingColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            worklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        worklane.paneStripState.insertPaneHorizontally(insertedPane, placement: placement)
    }

    private func insertNewPaneVertically(into worklane: inout WorklaneState) {
        let existingPaneCount = worklane.paneStripState.panes.count
        let sourceWidth = worklane.paneStripState.focusedColumn?.width
            ?? worklane.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &worklane, existingPaneCount: existingPaneCount)
        insertedPane.width = sourceWidth
        _ = worklane.paneStripState.insertPaneVertically(
            insertedPane,
            availableHeight: paneViewportHeight
        )
    }

    func selectWorklane(id: WorklaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == id }) else {
            return
        }

        let previousPaneRef = currentPaneReference
        clearReadyStatusForFocusedPane(in: &worklanes[index])
        activeWorklaneID = id
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func selectNextWorklane() {
        guard worklanes.count > 1,
              let currentIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return
        }

        let nextIndex = (currentIndex + 1) % worklanes.count
        selectWorklane(id: worklanes[nextIndex].id)
    }

    func selectPreviousWorklane() {
        guard worklanes.count > 1,
              let currentIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return
        }

        let previousIndex = (currentIndex - 1 + worklanes.count) % worklanes.count
        selectWorklane(id: worklanes[previousIndex].id)
    }

    func createWorklane() {
        let previousPaneRef = currentPaneReference
        let newIndex = nextWorklaneNumber()
        let title = "WS \(newIndex)"
        let id = runtimeIdentity.makeWorklaneID()
        let workingDirectory = resolveWorkingDirectoryForNewWorklane()
        let configInheritanceSourcePaneID = resolveConfigInheritanceSourcePaneIDForNewWorklane()

        worklanes.append(
            Self.makeDefaultWorklane(
                id: id,
                title: title,
                windowID: windowID,
                layoutContext: layoutContext,
                workingDirectory: workingDirectory,
                surfaceContext: .tab,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                processEnvironment: processEnvironment,
                runtimeIdentity: runtimeIdentity
            )
        )
        activeWorklaneID = id
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
    }

    func focusPane(id: PaneID) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousWorklane = worklane
        let previousPaneRef = currentPaneReference
        let wasFocusedPaneID = worklane.paneStripState.focusedPaneID
        let hadReadyStatus = worklane.auxiliaryStateByPaneID[id]?.raw.showsReadyStatus == true
            || worklane.auxiliaryStateByPaneID[id]?.raw.wantsReadyStatus == true
        if wasFocusedPaneID == id, !hadReadyStatus {
            return
        }

        worklane.paneStripState.focusPane(id: id)
        clearReadyStatusIfNeeded(for: id, in: &worklane)
        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        if wasFocusedPaneID == id {
            let impacts = auxiliaryInvalidation(for: id, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(activeWorklaneID, id, impacts))
            }
        } else {
            recordFocusTransition(from: previousPaneRef)
            notify(.focusChanged(activeWorklaneID))
        }
    }

    func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            return
        }

        let previousPaneRef = currentPaneReference
        worklanes[index].paneStripState.focusPane(id: paneID)
        clearReadyStatusIfNeeded(for: paneID, in: &worklanes[index])
        activeWorklaneID = worklaneID
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func closeActiveWorklane() {
        guard removeActiveWorklaneIfPossible() else {
            return
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
    }

    enum PaneCloseResult {
        case closed
        case closeWindow
        case notFound
    }

    func closePaneFromShellExit(id paneID: PaneID) -> PaneCloseResult {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return .notFound
        }

        var worklane = worklanes[worklaneIndex]

        if worklane.paneStripState.panes.count == 1 {
            if worklanes.count == 1 {
                worklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
                worklanes[worklaneIndex] = worklane
                return .closeWindow
            }

            let removedID = worklane.id
            worklanes.remove(at: worklaneIndex)
            if activeWorklaneID == removedID {
                let replacementIndex = min(max(worklaneIndex - 1, 0), worklanes.count - 1)
                activeWorklaneID = worklanes[replacementIndex].id
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
            return .closed
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        if let removal = worklane.paneStripState.removePane(id: paneID, singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removal.pane.id, in: &worklane)
            applyColumnWidthNormalization(
                &worklane,
                previousColumnCount: previousColumnCount,
                singleColumnWidth: layoutContext.singlePaneWidth
            )
        }
        worklanes[worklaneIndex] = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(worklane.id))
        return .closed
    }

    func closeFocusedPane() -> PaneCloseResult {
        guard let paneID = activeWorklane?.paneStripState.focusedPaneID else {
            return .notFound
        }

        return closePane(id: paneID)
    }

    @discardableResult
    func closePane(id: PaneID) -> PaneCloseResult {
        guard var worklane = activeWorklane else {
            return .notFound
        }

        let previousPaneRef = currentPaneReference
        worklane.paneStripState.focusPane(id: id)
        guard worklane.paneStripState.panes.contains(where: { $0.id == id }) else {
            return .notFound
        }

        if worklane.paneStripState.columns.count == 1,
           worklane.paneStripState.panes.count == 1 {
            if worklanes.count == 1 {
                return .closeWindow
            }

            guard removeActiveWorklaneIfPossible() else {
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return .closed
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
            return .closed
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        if let removedPane = worklane.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removedPane.id, in: &worklane)
            applyColumnWidthNormalization(
                &worklane,
                previousColumnCount: previousColumnCount,
                singleColumnWidth: layoutContext.singlePaneWidth
            )
        }

        activeWorklane = worklane

        // Record the previous focus only if the closed pane was not the one
        // we were already focused on. When closing a non-focused pane from the
        // sidebar, previousPaneRef is the real focus origin (alive) and should
        // be recorded so back returns there.
        let newPaneRef = currentPaneReference
        if let previousPaneRef, previousPaneRef.paneID != id, previousPaneRef != newPaneRef {
            recordFocusTransition(from: previousPaneRef)
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
        return .closed
    }

    #if DEBUG
    func replaceWorklanes(_ worklanes: [WorklaneState], activeWorklaneID: WorklaneID? = nil) {
        self.worklanes = worklanes
        let fallbackID = activeWorklaneID ?? worklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        self.activeWorklaneID = worklanes.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : worklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        normalizeAllPanePresentationState()
        refreshLastFocusedLocalWorkingDirectory()
        refreshAllPaneGitContexts()
        notify(.worklaneListChanged)
    }
    #endif

    private func makePane(in worklane: inout WorklaneState, existingPaneCount: Int) -> PaneState {
        defer {
            worklane.nextPaneNumber += 1
        }

        let title = "pane \(worklane.nextPaneNumber)"
        let paneID = runtimeIdentity.makePaneID()
        let focusedPaneID = worklane.paneStripState.focusedPaneID
        let launchContext = focusedPaneID.flatMap { resolveLaunchContext(for: $0, in: worklane) }
        let workingDirectory = launchContext?.path
            ?? lastFocusedLocalWorkingDirectory
            ?? Self.defaultWorkingDirectory()
        let inheritFromPaneID = sourcePaneIDForSessionInheritance(in: worklane)
        let configInheritanceSourcePaneID = sourcePaneIDForConfigInheritance(in: worklane)

        let initialShellContext = seededShellContext(
            launchContext: launchContext,
            sourceShellContext: inheritFromPaneID.flatMap { worklane.auxiliaryStateByPaneID[$0]?.shellContext },
            fallbackWorkingDirectory: workingDirectory
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: title,
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: inheritFromPaneID == nil ? workingDirectory : nil
        )
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            raw: initialRaw,
            presentation: initialPresentation
        )

        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: inheritFromPaneID,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                surfaceContext: .split,
                environmentVariables: sessionEnvironment(
                    worklaneID: worklane.id,
                    paneID: paneID,
                    initialWorkingDirectory: inheritFromPaneID == nil ? workingDirectory : nil
                )
            ),
            width: layoutContext.newPaneWidth(existingPaneCount: existingPaneCount)
        )
    }

    /// Create a new pane in the given worklane with an explicit working directory.
    /// Used by duplicate-pane operations where the CWD comes from the source pane.
    func makePaneWithDirectory(
        in worklane: inout WorklaneState,
        existingPaneCount: Int,
        workingDirectory: String?,
        sourceShellContext: PaneShellContext? = nil
    ) -> PaneState {
        defer { worklane.nextPaneNumber += 1 }

        let title = "pane \(worklane.nextPaneNumber)"
        let paneID = runtimeIdentity.makePaneID()
        let resolvedDirectory = workingDirectory ?? Self.defaultWorkingDirectory()
        let configSource = sourcePaneIDForConfigInheritance(in: worklane)

        let initialShellContext = seededShellContext(
            launchContext: sourceShellContext.map {
                PaneLaunchContext(path: resolvedDirectory, scope: $0.scope)
            },
            sourceShellContext: sourceShellContext,
            fallbackWorkingDirectory: resolvedDirectory
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: title,
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: resolvedDirectory
        )
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            raw: initialRaw,
            presentation: initialPresentation
        )

        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: resolvedDirectory,
                inheritFromPaneID: nil,
                configInheritanceSourcePaneID: configSource,
                surfaceContext: .split,
                environmentVariables: sessionEnvironment(
                    worklaneID: worklane.id,
                    paneID: paneID,
                    initialWorkingDirectory: resolvedDirectory
                )
            ),
            width: layoutContext.newPaneWidth(existingPaneCount: existingPaneCount)
        )
    }

    private func seededShellContext(
        launchContext: PaneLaunchContext?,
        sourceShellContext: PaneShellContext?,
        fallbackWorkingDirectory: String
    ) -> PaneShellContext {
        let resolvedPath = launchContext?.path ?? sourceShellContext?.path ?? fallbackWorkingDirectory

        if sourceShellContext?.scope == .remote || launchContext?.scope == .remote {
            return PaneShellContext(
                scope: .remote,
                path: resolvedPath,
                home: sourceShellContext?.home,
                user: sourceShellContext?.user,
                host: sourceShellContext?.host,
                gitBranch: sourceShellContext?.gitBranch
            )
        }

        return PaneShellContext(
            scope: .local,
            path: resolvedPath,
            home: processEnvironment["HOME"],
            user: processEnvironment["USER"],
            host: nil
        )
    }

    private static func defaultWorklanes(
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String],
        runtimeIdentity: WorklaneRuntimeIdentity
    ) -> [WorklaneState] {
        [
            makeDefaultWorklane(
                id: runtimeIdentity.makeWorklaneID(),
                title: "MAIN",
                windowID: windowID,
                layoutContext: layoutContext,
                workingDirectory: Self.defaultWorkingDirectory(),
                surfaceContext: .window,
                processEnvironment: processEnvironment,
                runtimeIdentity: runtimeIdentity
            ),
        ]
    }

    private static func makeDefaultWorklane(
        id: WorklaneID,
        title: String,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        workingDirectory: String,
        surfaceContext: TerminalSurfaceContext,
        configInheritanceSourcePaneID: PaneID? = nil,
        processEnvironment: [String: String],
        runtimeIdentity: WorklaneRuntimeIdentity
    ) -> WorklaneState {
        let shellPaneID = runtimeIdentity.makePaneID()
        let initialShellContext = PaneShellContext(
            scope: .local,
            path: workingDirectory,
            home: processEnvironment["HOME"],
            user: processEnvironment["USER"],
            host: nil
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: workingDirectory
        )
        return WorklaneState(
            id: id,
            title: title,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: shellPaneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory,
                            configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                            surfaceContext: surfaceContext,
                            environmentVariables: Self.sessionEnvironment(
                                windowID: windowID,
                                worklaneID: id,
                                paneID: shellPaneID,
                                initialWorkingDirectory: workingDirectory,
                                processEnvironment: processEnvironment
                            )
                        ),
                        width: layoutContext.singlePaneWidth
                    ),
                ],
                focusedPaneID: shellPaneID,
                layoutSizing: layoutContext.sizing
            ),
            auxiliaryStateByPaneID: [
                shellPaneID: PaneAuxiliaryState(
                    raw: initialRaw,
                    presentation: initialPresentation
                ),
            ]
        )
    }

    func batchUpdate(_ body: () -> Void) {
        isBatching = true
        body()
        isBatching = false
    }

    /// Internal — called by WorklaneStore extension files to dispatch change notifications.
    /// Not intended for use outside WorklaneStore and its extensions.
    func notify(_ change: WorklaneChange) {
        guard !isBatching else { return }
        for subscriber in subscribers {
            subscriber.handler(change)
        }
    }

    private func notifyLayoutResized(animation: WorklaneLayoutResizeAnimation) {
        notify(.layoutResized(activeWorklaneID, animation: animation))
    }

    private func sessionEnvironment(
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil
    ) -> [String: String] {
        Self.sessionEnvironment(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            initialWorkingDirectory: initialWorkingDirectory,
            processEnvironment: processEnvironment
        )
    }

    private static func sessionEnvironment(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil,
        processEnvironment: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WINDOW_ID": windowID.rawValue,
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]
        if let initialWorkingDirectory = trimmedWorkingDirectory(initialWorkingDirectory) {
            environment["ZENTTY_INITIAL_WORKING_DIRECTORY"] = initialWorkingDirectory
        }
        if let helperPath = AgentStatusHelper.binaryPath() {
            environment["ZENTTY_AGENT_BIN"] = helperPath
        }
        if let agentSignalCommand = AgentStatusHelper.agentSignalCommand() {
            environment["ZENTTY_AGENT_SIGNAL_COMMAND"] = agentSignalCommand
        }
        if let claudeHookCommand = AgentStatusHelper.claudeHookCommand() {
            environment["ZENTTY_CLAUDE_HOOK_COMMAND"] = claudeHookCommand
        }
        if let wrapperDirectories = AgentStatusHelper.wrapperDirectoryPaths() {
            environment["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = wrapperDirectories.joined(separator: ":")
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
        }
        if let ghosttyLog = processEnvironment["GHOSTTY_LOG"], !ghosttyLog.isEmpty {
            environment["GHOSTTY_LOG"] = ghosttyLog
        } else {
            environment["GHOSTTY_LOG"] = "macos,no-stderr"
        }
        return environment
    }

    private func sourcePaneIDForSessionInheritance(in worklane: WorklaneState) -> PaneID? {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return nil
        }

        if let paneContext = worklane.auxiliaryStateByPaneID[focusedPaneID]?.shellContext {
            return paneContext.scope == .remote ? focusedPaneID : nil
        }

        guard let pane = pane(for: focusedPaneID, in: worklane) else {
            return nil
        }

        return pane.sessionRequest.inheritFromPaneID == nil ? nil : focusedPaneID
    }

    private func sourcePaneIDForConfigInheritance(in worklane: WorklaneState) -> PaneID? {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID,
              pane(for: focusedPaneID, in: worklane) != nil else {
            return nil
        }

        return focusedPaneID
    }

    private func resolveLaunchContext(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> PaneLaunchContext? {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )

        return terminalLocation.workingDirectory.map {
            PaneLaunchContext(path: $0, scope: terminalLocation.scope)
        }
    }

    func localReviewWorkingDirectory(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> String? {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )
        guard terminalLocation.scope != .remote else {
            return nil
        }

        return terminalLocation.workingDirectory
    }

    func focusedOpenWithContext(in worklane: WorklaneState) -> WorklaneOpenWithContext? {
        guard
            let focusedPaneID = worklane.paneStripState.focusedPaneID,
            let launchContext = resolveLaunchContext(for: focusedPaneID, in: worklane),
            canTreatLaunchContextAsLocal(launchContext, for: focusedPaneID, in: worklane)
        else {
            return nil
        }

        return WorklaneOpenWithContext(
            worklaneID: worklane.id,
            paneID: focusedPaneID,
            workingDirectory: launchContext.path,
            scope: .local
        )
    }

    private func canTreatLaunchContextAsLocal(
        _ launchContext: PaneLaunchContext,
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> Bool {
        switch launchContext.scope {
        case .local:
            return true
        case .remote:
            return false
        case nil:
            return nonInheritedSessionWorkingDirectory(for: paneID, in: worklane) != nil
        }
    }

    func refreshLastFocusedLocalWorkingDirectory() {
        guard
            let worklane = activeWorklane,
            let focusedPaneID = worklane.paneStripState.focusedPaneID
        else {
            lastFocusedPaneReference = nil
            return
        }

        lastFocusedPaneReference = PaneReference(worklaneID: worklane.id, paneID: focusedPaneID)
        updateLastFocusedLocalWorkingDirectory(using: focusedPaneID, in: worklane)
    }

    func refreshLastFocusedLocalWorkingDirectoryIfNeeded(
        worklane: WorklaneState,
        paneID: PaneID
    ) {
        guard worklane.id == activeWorklaneID, worklane.paneStripState.focusedPaneID == paneID else {
            return
        }

        updateLastFocusedLocalWorkingDirectory(using: paneID, in: worklane)
    }

    private func updateLastFocusedLocalWorkingDirectory(
        using paneID: PaneID,
        in worklane: WorklaneState
    ) {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )
        guard terminalLocation.scope != .remote,
              let workingDirectory = terminalLocation.workingDirectory else {
            return
        }

        lastFocusedLocalPaneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        lastFocusedLocalWorkingDirectory = workingDirectory
    }

    private func clearReadyStatusForFocusedPane(in worklane: inout WorklaneState) {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return
        }

        clearReadyStatusIfNeeded(for: focusedPaneID, in: &worklane)
    }

    func clearReadyStatusIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        cancelPendingReadyStatus(for: paneReference)

        guard worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true
            || worklane.auxiliaryStateByPaneID[paneID]?.raw.wantsReadyStatus == true
        else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.wantsReadyStatus = false
        worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = false
        let worklaneIDRaw = worklane.id.rawValue
        worklaneReadyLogger.debug(
            "Cleared ready status worklane=\(worklaneIDRaw, privacy: .public) pane=\(paneID.rawValue, privacy: .public)"
        )
        recomputePresentation(for: paneID, in: &worklane)
    }

    func requestReadyStatusIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
        auxiliaryState.raw.wantsReadyStatus = true
        let shouldSchedule = auxiliaryState.raw.showsReadyStatus == false
        if shouldSchedule,
           readyStatusDebounceInterval <= 0,
           readyStatusMayBecomeVisible(in: auxiliaryState) {
            auxiliaryState.raw.showsReadyStatus = true
        }
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        let worklaneIDRaw = worklane.id.rawValue
        let showsReadyImmediately = auxiliaryState.raw.showsReadyStatus
        worklaneReadyLogger.debug(
            "Requested ready status worklane=\(worklaneIDRaw, privacy: .public) pane=\(paneID.rawValue, privacy: .public) immediate=\(showsReadyImmediately, privacy: .public)"
        )

        guard shouldSchedule else {
            cancelPendingReadyStatus(for: paneReference)
            return
        }

        guard readyStatusDebounceInterval > 0 else {
            cancelPendingReadyStatus(for: paneReference)
            return
        }

        scheduleReadyStatusReveal(for: paneReference)
    }

    func cancelPendingReadyStatus(for paneReference: PaneReference) {
        pendingReadyStatusTasks[paneReference]?.cancel()
        pendingReadyStatusTasks[paneReference] = nil
    }

    private func scheduleReadyStatusReveal(for paneReference: PaneReference) {
        cancelPendingReadyStatus(for: paneReference)

        let debounceInterval = readyStatusDebounceInterval
        guard debounceInterval > 0 else {
            commitReadyStatusReveal(for: paneReference)
            return
        }

        pendingReadyStatusTasks[paneReference] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else {
                return
            }

            self?.commitReadyStatusReveal(for: paneReference)
        }
    }

    private func commitReadyStatusReveal(for paneReference: PaneReference) {
        pendingReadyStatusTasks[paneReference] = nil

        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == paneReference.worklaneID }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneReference.paneID],
              readyStatusMayBecomeVisible(in: auxiliaryState),
              auxiliaryState.raw.showsReadyStatus == false
        else {
            return
        }

        auxiliaryState.raw.showsReadyStatus = true
        worklane.auxiliaryStateByPaneID[paneReference.paneID] = auxiliaryState
        worklaneReadyLogger.debug(
            "Committed ready status worklane=\(paneReference.worklaneID.rawValue, privacy: .public) pane=\(paneReference.paneID.rawValue, privacy: .public)"
        )
        recomputePresentation(for: paneReference.paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane

        let impacts = auxiliaryInvalidation(
            for: paneReference.paneID,
            previousWorklane: previousWorklane,
            nextWorklane: worklane
        )
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneReference.paneID, impacts))
        }
    }

    private func readyStatusMayBecomeVisible(in auxiliaryState: PaneAuxiliaryState) -> Bool {
        guard auxiliaryState.raw.wantsReadyStatus else {
            return false
        }

        if let agentStatus = auxiliaryState.agentStatus,
           agentStatus.state == .idle,
           agentStatus.hasObservedRunning {
            return true
        }

        guard let notificationText = WorklaneContextFormatter.trimmed(
            auxiliaryState.raw.lastDesktopNotificationText
        )?.lowercased() else {
            return false
        }

        return notificationText.contains("agent run complete")
            || notificationText.contains("agent ready")
            || notificationText.contains("agent turn complete")
    }

    private func resolveWorkingDirectoryForNewWorklane() -> String {
        if let lastFocusedPaneReference,
           let worklane = worklanes.first(where: { $0.id == lastFocusedPaneReference.worklaneID }),
           let launchContext = resolveLaunchContext(for: lastFocusedPaneReference.paneID, in: worklane),
           launchContext.scope != .remote {
            return launchContext.path
        }

        return lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
    }

    private func resolveConfigInheritanceSourcePaneIDForNewWorklane() -> PaneID? {
        guard let lastFocusedLocalPaneReference,
              let worklane = worklanes.first(where: { $0.id == lastFocusedLocalPaneReference.worklaneID }),
              pane(for: lastFocusedLocalPaneReference.paneID, in: worklane) != nil else {
            return nil
        }

        return lastFocusedLocalPaneReference.paneID
    }

    func nonInheritedSessionWorkingDirectory(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> String? {
        guard let pane = pane(for: paneID, in: worklane),
              pane.sessionRequest.inheritFromPaneID == nil else {
            return nil
        }

        return Self.trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
    }

    private func pane(for paneID: PaneID, in worklane: WorklaneState) -> PaneState? {
        worklane.paneStripState.panes.first { $0.id == paneID }
    }

    private static func defaultWorkingDirectory() -> String {
        NSHomeDirectory()
    }

    private static func trimmedWorkingDirectory(_ workingDirectory: String?) -> String? {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return nil
        }

        return workingDirectory
    }

    private static func readableWidthScaleFactor(
        from previousLayoutContext: PaneLayoutContext,
        to nextLayoutContext: PaneLayoutContext
    ) -> CGFloat? {
        let previousReadableWidth = previousLayoutContext.sizing.readableWidth(
            for: previousLayoutContext.viewportWidth,
            leadingVisibleInset: previousLayoutContext.leadingVisibleInset
        )
        let nextReadableWidth = nextLayoutContext.sizing.readableWidth(
            for: nextLayoutContext.viewportWidth,
            leadingVisibleInset: nextLayoutContext.leadingVisibleInset
        )
        guard previousReadableWidth > 0, nextReadableWidth > 0 else {
            return nil
        }

        return nextReadableWidth / previousReadableWidth
    }

    func nextWorklaneNumber() -> Int {
        let maxExisting = worklanes.compactMap { worklane -> Int? in
            let normalizedTitle = worklane.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedTitle.hasPrefix("WS "),
                  let n = Int(normalizedTitle.dropFirst(3)) else { return nil }
            return n
        }.max() ?? 0
        return maxExisting + 1
    }

    @discardableResult
    private func removeActiveWorklaneIfPossible() -> Bool {
        guard worklanes.count > 1, let activeIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return false
        }

        worklanes.remove(at: activeIndex)
        let replacementIndex = min(max(activeIndex - 1, 0), worklanes.count - 1)
        activeWorklaneID = worklanes[replacementIndex].id
        return true
    }
}

private extension WorklaneStore {
    func normalizeAllPanePresentationState() {
        for worklaneIndex in worklanes.indices {
            let paneIDs = worklanes[worklaneIndex].paneStripState.panes.map(\.id)
            for paneID in paneIDs {
                recomputePresentation(for: paneID, in: &worklanes[worklaneIndex])
            }
        }
    }

    func refreshAllPaneGitContexts() {
        for worklane in worklanes {
            for pane in worklane.paneStripState.panes {
                refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: pane.id))
            }
        }
    }
}
