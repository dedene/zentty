import Darwin
import Foundation

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
    case layoutResized(WorklaneID)
    case auxiliaryStateUpdated(WorklaneID, PaneID, WorklaneAuxiliaryInvalidation)
    case activeWorklaneChanged
    case worklaneListChanged
}

struct WorklaneChangeSubscription {
    fileprivate let id: UUID
    fileprivate static let legacyID = UUID()
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
    private var layoutContext: PaneLayoutContext
    private var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedPaneReference: PaneReference?
    private var lastFocusedLocalPaneReference: PaneReference?
    private var lastFocusedLocalWorkingDirectory: String?
    var cachedGitContextByPath: [String: PaneGitContext] = [:]
    var knownNonRepositoryPaths: Set<String> = []
    var pendingGitContextPaths: Set<String> = []
    var waitingPaneReferencesByPath: [String: Set<PaneReference>] = [:]
    private let processEnvironment: [String: String]

    private(set) var activeWorklaneID: WorklaneID

    private var subscribers: [(id: UUID, handler: (WorklaneChange) -> Void)] = []
    private var isBatching = false

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
        worklanes: [WorklaneState] = [],
        layoutContext: PaneLayoutContext = .fallback,
        activeWorklaneID: WorklaneID? = nil,
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.gitContextResolver = gitContextResolver
        self.layoutContext = layoutContext
        self.processEnvironment = processEnvironment
        let initialWorklanes = worklanes.isEmpty
            ? WorklaneStore.defaultWorklanes(
                layoutContext: layoutContext,
                processEnvironment: processEnvironment
            )
            : worklanes
        let requestedActiveWorklaneID = activeWorklaneID ?? initialWorklanes.first?.id ?? WorklaneID("worklane-main")
        let resolvedActiveWorklaneID = initialWorklanes.contains(where: { $0.id == requestedActiveWorklaneID })
            ? requestedActiveWorklaneID
            : initialWorklanes.first?.id ?? WorklaneID("worklane-main")
        self.worklanes = initialWorklanes
        self.activeWorklaneID = resolvedActiveWorklaneID
        normalizeAllPanePresentationState()
        refreshLastFocusedLocalWorkingDirectory()
        refreshAllPaneGitContexts()
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
        let viewportScaleFactor = Self.viewportScaleFactor(
            from: previousLayoutContext.viewportWidth,
            to: layoutContext.viewportWidth
        )

        for index in worklanes.indices {
            if worklanes[index].paneStripState.updateLayoutSizing(layoutContext.sizing) {
                didUpdateWorklaneState = true
            }

            if worklanes[index].paneStripState.updateSinglePaneWidth(layoutContext.singlePaneWidth) {
                didUpdateWorklaneState = true
                continue
            }

            if let viewportScaleFactor,
               worklanes[index].paneStripState.scalePaneWidths(by: viewportScaleFactor) {
                didUpdateWorklaneState = true
            }
        }

        if didUpdateWorklaneState {
            notify(.layoutResized(activeWorklaneID))
        }
    }

    func updatePaneViewportHeight(_ height: CGFloat) {
        paneViewportHeight = max(1, height)
    }

    func send(_ command: PaneCommand) {
        guard var worklane = activeWorklane else {
            return
        }

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
            if worklane.paneStripState.columns.count == 1,
               worklane.paneStripState.panes.count == 1 {
                guard removeActiveWorklaneIfPossible() else {
                    refreshLastFocusedLocalWorkingDirectory()
                    notify(.paneStructure(activeWorklaneID))
                    return
                }
                refreshLastFocusedLocalWorkingDirectory()
                notify(.worklaneListChanged)
                return
            }

            if let removedPane = worklane.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
                clearPaneState(for: removedPane.id, in: &worklane)
            }
            changeType = .paneStructure(activeWorklaneID)
        case .focusLeft:
            worklane.paneStripState.moveFocusLeft()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusRight:
            worklane.paneStripState.moveFocusRight()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusUp:
            worklane.paneStripState.moveFocusUp()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusDown:
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
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown, .resetLayout:
            activeWorklane = worklane
            return
        }

        activeWorklane = worklane
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
        notify(.layoutResized(activeWorklaneID))
    }

    func resize(
        _ target: PaneResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resize(
            target,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notify(.layoutResized(activeWorklaneID))
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
        notify(.layoutResized(activeWorklaneID))
    }

    func resizeFocusedPane(
        in axis: PaneResizeAxis,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resizeFocusedPane(
            in: axis,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notify(.layoutResized(activeWorklaneID))
    }

    func restorePaneLayout(_ paneStripState: PaneStripState) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState = paneStripState
        activeWorklane = worklane
        notify(.layoutResized(activeWorklaneID))
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
            columns[index].width = index == 0 ? firstColumnWidth : defaultColumnWidth
            columns[index].resetPaneHeights()
        }

        worklane.paneStripState = PaneStripState(
            columns: columns,
            focusedColumnID: worklane.paneStripState.focusedColumnID,
            layoutSizing: layoutContext.sizing
        )
        activeWorklane = worklane
        notify(.layoutResized(activeWorklaneID))
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

        clearReadyStatusForFocusedPane(in: &worklanes[index])
        activeWorklaneID = id
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
        let newIndex = worklanes.count + 1
        let title = "WS \(newIndex)"
        let id = WorklaneID("worklane-\(newIndex)")
        let workingDirectory = resolveWorkingDirectoryForNewWorklane()
        let configInheritanceSourcePaneID = resolveConfigInheritanceSourcePaneIDForNewWorklane()

        worklanes.append(
            Self.makeDefaultWorklane(
                id: id,
                title: title,
                layoutContext: layoutContext,
                workingDirectory: workingDirectory,
                surfaceContext: .tab,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                processEnvironment: processEnvironment
            )
        )
        activeWorklaneID = id
        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
    }

    func focusPane(id: PaneID) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousWorklane = worklane
        let wasFocusedPaneID = worklane.paneStripState.focusedPaneID
        let hadReadyStatus = worklane.auxiliaryStateByPaneID[id]?.raw.showsReadyStatus == true
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
            notify(.focusChanged(activeWorklaneID))
        }
    }

    func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            return
        }

        worklanes[index].paneStripState.focusPane(id: paneID)
        clearReadyStatusIfNeeded(for: paneID, in: &worklanes[index])
        activeWorklaneID = worklaneID
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

    func closePane(id: PaneID) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState.focusPane(id: id)
        if worklane.paneStripState.columns.count == 1,
           worklane.paneStripState.panes.count == 1 {
            guard removeActiveWorklaneIfPossible() else {
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
            return
        }

        if let removedPane = worklane.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removedPane.id, in: &worklane)
        }

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
    }

    #if DEBUG
    func replaceWorklanes(_ worklanes: [WorklaneState], activeWorklaneID: WorklaneID? = nil) {
        self.worklanes = worklanes
        let fallbackID = activeWorklaneID ?? worklanes.first?.id ?? WorklaneID("worklane-main")
        self.activeWorklaneID = worklanes.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : worklanes.first?.id ?? WorklaneID("worklane-main")
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
        let paneID = PaneID("\(worklane.id.rawValue)-pane-\(worklane.nextPaneNumber)")
        let workingDirectory = resolveWorkingDirectoryForNewPane(in: worklane)
        let inheritFromPaneID = sourcePaneIDForSessionInheritance(in: worklane)
        let configInheritanceSourcePaneID = sourcePaneIDForConfigInheritance(in: worklane)
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

    private static func defaultWorklanes(
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String]
    ) -> [WorklaneState] {
        [
            makeDefaultWorklane(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                layoutContext: layoutContext,
                workingDirectory: Self.defaultWorkingDirectory(),
                surfaceContext: .window,
                processEnvironment: processEnvironment
            ),
        ]
    }

    private static func makeDefaultWorklane(
        id: WorklaneID,
        title: String,
        layoutContext: PaneLayoutContext,
        workingDirectory: String,
        surfaceContext: TerminalSurfaceContext,
        configInheritanceSourcePaneID: PaneID? = nil,
        processEnvironment: [String: String]
    ) -> WorklaneState {
        let shellPaneID = PaneID("\(id.rawValue)-shell")
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
            )
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

    private func sessionEnvironment(
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil
    ) -> [String: String] {
        Self.sessionEnvironment(
            worklaneID: worklaneID,
            paneID: paneID,
            initialWorkingDirectory: initialWorkingDirectory,
            processEnvironment: processEnvironment
        )
    }

    private static func sessionEnvironment(
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil,
        processEnvironment: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [
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
        if let wrapperBinPath = AgentStatusHelper.wrapperBinPath() {
            environment["ZENTTY_WRAPPER_BIN_DIR"] = wrapperBinPath
            let currentPath = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(wrapperBinPath):\(currentPath)"
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

    private func resolveWorkingDirectoryForNewPane(in worklane: WorklaneState) -> String {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
        }

        return resolveLaunchContext(for: focusedPaneID, in: worklane)?.path
            ?? lastFocusedLocalWorkingDirectory
            ?? Self.defaultWorkingDirectory()
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
        let paneContext = worklane.auxiliaryStateByPaneID[paneID]?.shellContext
        let metadataWorkingDirectory = Self.trimmedWorkingDirectory(
            worklane.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
        )
        let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)

        if let paneContext {
            return resolvedWorkingDirectory(
                metadataWorkingDirectory: metadataWorkingDirectory,
                paneContext: paneContext,
                requestWorkingDirectory: requestWorkingDirectory
            )
                .map { PaneLaunchContext(path: $0, scope: paneContext.scope) }
        }

        return (metadataWorkingDirectory ?? requestWorkingDirectory)
            .map { PaneLaunchContext(path: $0, scope: nil) }
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

    private func refreshLastFocusedLocalWorkingDirectory() {
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
        if let paneContext = worklane.auxiliaryStateByPaneID[paneID]?.shellContext {
            guard paneContext.scope == .local else {
                return
            }

            let metadataWorkingDirectory = Self.trimmedWorkingDirectory(
                worklane.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
            )
            let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
            lastFocusedLocalPaneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
            lastFocusedLocalWorkingDirectory = resolvedWorkingDirectory(
                metadataWorkingDirectory: metadataWorkingDirectory,
                paneContext: paneContext,
                requestWorkingDirectory: requestWorkingDirectory
            )
            return
        }

        if let nonInheritedSessionWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane) {
            lastFocusedLocalPaneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
            lastFocusedLocalWorkingDirectory = nonInheritedSessionWorkingDirectory
        }
    }

    private func clearReadyStatusForFocusedPane(in worklane: inout WorklaneState) {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return
        }

        clearReadyStatusIfNeeded(for: focusedPaneID, in: &worklane)
    }

    private func clearReadyStatusIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        guard worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = false
        recomputePresentation(for: paneID, in: &worklane)
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

    private func nonInheritedSessionWorkingDirectory(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> String? {
        guard let pane = pane(for: paneID, in: worklane),
              pane.sessionRequest.inheritFromPaneID == nil else {
            return nil
        }

        return Self.trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
    }

    private func resolvedWorkingDirectory(
        metadataWorkingDirectory: String?,
        paneContext: PaneShellContext,
        requestWorkingDirectory: String?
    ) -> String? {
        let contextWorkingDirectory = Self.trimmedWorkingDirectory(paneContext.path)

        if paneContext.scope == .local,
           metadataWorkingDirectory == requestWorkingDirectory,
           let contextWorkingDirectory {
            return contextWorkingDirectory
        }

        return metadataWorkingDirectory ?? contextWorkingDirectory ?? requestWorkingDirectory
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

    private static func viewportScaleFactor(
        from previousViewportWidth: CGFloat,
        to nextViewportWidth: CGFloat
    ) -> CGFloat? {
        guard previousViewportWidth > 0, nextViewportWidth > 0 else {
            return nil
        }

        return nextViewportWidth / previousViewportWidth
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
