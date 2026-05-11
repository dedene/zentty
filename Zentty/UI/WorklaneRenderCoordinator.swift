import AppKit
import QuartzCore

@MainActor
protocol RenderEnvironmentProviding: AnyObject {
    var renderTheme: ZenttyTheme { get }
    var renderSidebarWidth: CGFloat { get }
    func renderLeadingInset(sidebarWidth: CGFloat) -> CGFloat
    var renderWindowState: (isVisible: Bool, isKeyWindow: Bool) { get }
    func renderSidebarSyncNeeded()
}

@MainActor
protocol WorklaneRenderCoordinatorScheduledHandle: AnyObject {
    func cancel()
}

@MainActor
private final class TimerWorklaneRenderCoordinatorScheduledHandle: WorklaneRenderCoordinatorScheduledHandle {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class WorklaneRenderCoordinator {
    private enum ReviewPolling {
        static let interval: TimeInterval = 30
    }

    typealias ReviewPollingScheduler = @MainActor (
        _ interval: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any WorklaneRenderCoordinatorScheduledHandle

    struct ViewBindings {
        let sidebarView: SidebarView
        let windowChromeView: WindowChromeView
        let appCanvasView: AppCanvasView
    }

    let worklaneStore: WorklaneStore
    let runtimeRegistry: PaneRuntimeRegistry
    let reviewStateResolver: WorklaneReviewStateResolver
    let windowID: WindowID
    private let terminalDiagnostics: TerminalDiagnostics
    private let configStore: AppConfigStore?

    private let attentionNotificationCoordinator: WorklaneAttentionNotificationCoordinator

    private var views: ViewBindings?
    private var reviewPollingHandle: (any WorklaneRenderCoordinatorScheduledHandle)?
    private var reviewPollingTarget: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)?
    private var hasBootstrappedReviewState = false
    private var needsRuntimeSynchronization = true
    private var worklaneStoreSubscription: WorklaneChangeSubscription?
    private let reviewPollingScheduler: ReviewPollingScheduler

    weak var environment: RenderEnvironmentProviding?

    /// Worklanes whose surfaces should be kept un-occluded even though they
    /// aren't the active worklane — used by Worklane Peek so neighbor lane
    /// previews keep streaming live instead of freezing on a still frame.
    /// Default returns an empty set (nothing peek-visible).
    var peekVisibleWorklaneIDsProvider: () -> Set<WorklaneID> = { [] }
    var sidebarFocusOverrideProvider: () -> WorklaneSidebarFocusOverride? = { nil }

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        worklaneStore: WorklaneStore,
        runtimeRegistry: PaneRuntimeRegistry,
        notificationStore: NotificationStore,
        configStore: AppConfigStore? = nil,
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        reviewPollingScheduler: @escaping ReviewPollingScheduler = WorklaneRenderCoordinator.defaultReviewPollingScheduler,
        terminalDiagnostics: TerminalDiagnostics = .shared
    ) {
        self.windowID = windowID
        self.worklaneStore = worklaneStore
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.reviewPollingScheduler = reviewPollingScheduler
        self.terminalDiagnostics = terminalDiagnostics
        self.configStore = configStore
        self.attentionNotificationCoordinator = WorklaneAttentionNotificationCoordinator(
            notificationStore: notificationStore,
            configStore: configStore
        )
    }

    deinit {
        MainActor.assumeIsolated {
            cancelReviewPolling()
            if let worklaneStoreSubscription {
                worklaneStore.unsubscribe(worklaneStoreSubscription)
            }
        }
    }

    func bind(to views: ViewBindings) {
        self.views = views
    }

    func startObserving() {
        guard worklaneStoreSubscription == nil else {
            return
        }

        worklaneStoreSubscription = worklaneStore.subscribe { [weak self] change in
            self?.handleWorklaneChange(change)
        }
    }

    // MARK: - Public render API

    func render(animated: Bool = false) {
        renderCurrentWorklane(animated: animated)
    }

    func renderCanvas(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        renderCanvasForCurrentWorklane(
            leadingVisibleInsetOverride: leadingVisibleInsetOverride,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    func updateSurfaceActivities() {
        updateReviewPolling()
        updateRuntimeSurfaceActivities()
    }

    func renderSidebar() {
        guard let views else {
            return
        }

        renderSidebar(in: views)
    }

    #if DEBUG
    var reviewPollingTargetForTesting: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)? {
        reviewPollingTarget
    }
    #endif

    // MARK: - Internal

    private var currentTheme: ZenttyTheme {
        environment?.renderTheme ?? ZenttyTheme.fallback(for: nil)
    }

    private var currentPaneSettings: AppConfig.Panes {
        configStore?.current.panes ?? .default
    }

    private var activePaneID: PaneID? {
        worklaneStore.activeWorklane?.paneStripState.focusedPaneID
    }

    private func renderSidebar(in views: ViewBindings) {
        terminalDiagnostics.recordRender(.sidebar, activePaneID: activePaneID)
        views.sidebarView.render(
            summaries: WorklaneSidebarSummaryBuilder.summaries(
                for: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                focusOverride: sidebarFocusOverrideProvider()
            ),
            theme: currentTheme
        )
        environment?.renderSidebarSyncNeeded()
    }

    private func handleWorklaneChange(_ change: WorklaneChange) {
        switch change {
        case .paneStructure:
            needsRuntimeSynchronization = true
            renderCurrentWorklane(animated: true)
            updateRuntimeSurfaceActivities()
        case .focusChanged:
            renderCurrentWorklane(animated: true)
            updateRuntimeSurfaceActivities()
        case .layoutResized(_, let animation):
            renderCurrentWorklane(animated: animation == .splitCurve)
        case .worklaneListChanged:
            needsRuntimeSynchronization = true
            renderCurrentWorklane(animated: false)
            updateRuntimeSurfaceActivities()
            bootstrapReviewRefresh(force: true)
        case .activeWorklaneChanged:
            renderCurrentWorklane(animated: false)
            updateRuntimeSurfaceActivities()
            bootstrapReviewRefresh(force: true)
        case .auxiliaryStateUpdated(let worklaneID, let paneID, let impacts):
            handleAuxiliaryStateUpdate(worklaneID: worklaneID, paneID: paneID, impacts: impacts)
        case .volatileAgentTitleUpdated(let worklaneID, let paneID):
            handleVolatileAgentTitleUpdate(worklaneID: worklaneID, paneID: paneID)
        case .teamAnchorsChanged(let worklaneID):
            if worklaneID == worklaneStore.activeWorklaneID {
                renderCanvasForCurrentWorklane(animated: false)
            }
        case .historyChanged:
            break
        }
    }

    private func handleVolatileAgentTitleUpdate(
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        guard let views,
              let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }),
              let metadata = worklane.auxiliaryStateByPaneID[paneID]?.metadata,
              let titleText = WorklaneContextFormatter.trimmed(metadata.title)
        else {
            return
        }

        views.sidebarView.setVolatilePaneTitle(
            worklaneID: worklaneID,
            paneID: paneID,
            text: titleText
        )

        if worklaneID == worklaneStore.activeWorklaneID,
           worklane.paneStripState.focusedPaneID == paneID {
            views.windowChromeView.setFocusedLabelText(titleText)
        }
    }

    private func renderCurrentWorklane(animated: Bool = false) {
        ZenttyPerformanceSignposts.interval("WorklaneRenderCurrent") {
            guard let views else {
                return
            }

            terminalDiagnostics.recordRender(.full, activePaneID: activePaneID)
            worklaneStore.batchUpdate { [self] in
                if needsRuntimeSynchronization {
                    runtimeRegistry.synchronize(with: worklaneStore.worklanes)
                    needsRuntimeSynchronization = false
                }
                renderSidebar(in: views)

                guard let worklane = worklaneStore.activeWorklane else {
                    terminalDiagnostics.recordRender(.header, activePaneID: activePaneID)
                    renderWindowChrome(
                        WorklaneChromeSummary(
                        attention: nil,
                        focusedLabel: nil,
                        branch: nil,
                        pullRequest: nil,
                        reviewChips: []
                        ),
                        in: views
                    )
                    return
                }

                let headerSummary = WorklaneHeaderSummaryBuilder.summary(for: worklane)
                terminalDiagnostics.recordRender(.header, activePaneID: activePaneID)
                renderWindowChrome(headerSummary, in: views)
                renderCanvasForCurrentWorklane(animated: animated)
                let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
                attentionNotificationCoordinator.update(
                    windowID: windowID,
                    worklanes: worklaneStore.worklanes,
                    activeWorklaneID: worklaneStore.activeWorklaneID,
                    windowIsKey: windowState.isKeyWindow
                )
                updateReviewPolling()
            }
            bootstrapReviewRefresh(force: false)
        }
    }

    private func renderCanvasForCurrentWorklane(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        ZenttyPerformanceSignposts.interval("WorklaneRenderCanvas") {
            guard let views, let worklane = worklaneStore.activeWorklane else {
                return
            }

            guard !views.appCanvasView.paneStripView.isDragActive
                  || views.appCanvasView.paneStripView.isDropSettling else {
                return
            }

            let sidebarWidth = environment?.renderSidebarWidth ?? SidebarWidthPreference.defaultWidth
            let effectiveInset = leadingVisibleInsetOverride
                ?? environment?.renderLeadingInset(sidebarWidth: sidebarWidth)
                ?? 0
            let paneSettings = currentPaneSettings

            terminalDiagnostics.recordRender(.canvas, activePaneID: worklane.paneStripState.focusedPaneID)
            let teamAnchor = worklaneStore.teamAnchorByWorklaneID[worklane.id]
            let leaderPaneID = teamAnchor.map { PaneID($0.leaderPaneID) }
            let memberPaneIDs: Set<PaneID> = teamAnchor
                .map { Set($0.columnPaneIDs.map(PaneID.init)) }
                ?? []
            views.appCanvasView.render(
                state: worklane.paneStripState,
                metadataByPaneID: worklane.auxiliaryStateByPaneID.compactMapValues(\.metadata),
                paneBorderContextByPaneID: worklane.paneBorderContextDisplayByPaneID(
                    leaderPaneID: leaderPaneID,
                    memberPaneIDs: memberPaneIDs
                ),
                showsPaneLabels: paneSettings.showLabels,
                inactivePaneOpacity: paneSettings.inactiveOpacity,
                worklaneColor: worklane.color,
                theme: currentTheme,
                leadingVisibleInset: effectiveInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        }
    }

    private func updateRuntimeSurfaceActivities() {
        ZenttyPerformanceSignposts.interval("WorklaneUpdateSurfaceActivities") {
            guard !worklaneStore.worklanes.isEmpty else {
                return
            }

            let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
            runtimeRegistry.updateSurfaceActivities(
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsVisible: windowState.isVisible,
                windowIsKey: windowState.isKeyWindow,
                peekVisibleWorklaneIDs: peekVisibleWorklaneIDsProvider()
            )
        }
    }

    private func updateReviewPolling() {
        guard let target = makeReviewPollingTarget() else {
            reviewPollingTarget = nil
            cancelReviewPolling()
            return
        }

        let targetChanged = reviewPollingTarget?.worklaneID != target.worklaneID
            || reviewPollingTarget?.paneID != target.paneID
            || reviewPollingTarget?.repoRoot != target.repoRoot
            || reviewPollingTarget?.branch != target.branch

        reviewPollingTarget = target
        if reviewPollingHandle == nil || targetChanged {
            cancelReviewPolling()
            reviewPollingHandle = reviewPollingScheduler(ReviewPolling.interval) { [weak self] in
                self?.refreshReviewPollingTarget(forceReload: true)
            }
        }
    }

    private func cancelReviewPolling() {
        reviewPollingHandle?.cancel()
        reviewPollingHandle = nil
    }

    private static func defaultReviewPollingScheduler(
        interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any WorklaneRenderCoordinatorScheduledHandle {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                operation()
            }
        }
        return TimerWorklaneRenderCoordinatorScheduledHandle(timer: timer)
    }

    private func makeReviewPollingTarget() -> (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)? {
        let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
        guard windowState.isVisible, windowState.isKeyWindow,
              let worklane = worklaneStore.activeWorklane,
              let paneID = worklane.paneStripState.focusedPaneID,
              let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              let repoRoot = auxiliaryState.presentation.repoRoot,
              let branch = auxiliaryState.presentation.lookupBranch
        else {
            return nil
        }

        return (
            worklaneID: worklane.id,
            paneID: paneID,
            repoRoot: repoRoot,
            branch: branch
        )
    }

    private func refreshReviewPollingTarget(forceReload: Bool) {
        guard let target = reviewPollingTarget else {
            return
        }

        reviewStateResolver.refreshPane(
            repoRoot: target.repoRoot,
            branch: target.branch,
            paneID: target.paneID,
            forceReload: forceReload
        ) { [weak self] paneID, resolution in
            self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }

    private func handleAuxiliaryStateUpdate(
        worklaneID: WorklaneID,
        paneID: PaneID,
        impacts: WorklaneAuxiliaryInvalidation
    ) {
        guard let views else {
            return
        }

        if impacts.contains(.sidebar) {
            renderSidebar(in: views)
        }

        if impacts.contains(.header) {
            renderHeader()
        }

        if impacts.contains(.canvas),
           worklaneID == worklaneStore.activeWorklaneID {
            renderCanvasForCurrentWorklane(animated: false)
        }

        if impacts.contains(.attention) {
            let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
            attentionNotificationCoordinator.update(
                windowID: windowID,
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsKey: windowState.isKeyWindow
            )
        }

        if impacts.contains(.reviewRefresh) {
            updateReviewPolling()
            refreshReviewState(for: worklaneID, paneID: paneID, forceReload: true)
        }

        if impacts.contains(.surfaceActivities) {
            updateRuntimeSurfaceActivities()
        }
    }

    private func renderHeader() {
        guard let views else {
            return
        }

        guard let worklane = worklaneStore.activeWorklane else {
            renderWindowChrome(
                WorklaneChromeSummary(
                attention: nil,
                focusedLabel: nil,
                branch: nil,
                pullRequest: nil,
                reviewChips: []
                ),
                in: views
            )
            return
        }

        renderWindowChrome(WorklaneHeaderSummaryBuilder.summary(for: worklane), in: views)
    }

    private func renderWindowChrome(_ summary: WorklaneChromeSummary, in views: ViewBindings) {
        views.windowChromeView.render(summary: summary)
    }

    private func bootstrapReviewRefresh(force: Bool) {
        guard force || !hasBootstrappedReviewState else {
            return
        }

        hasBootstrappedReviewState = true
        reviewStateResolver.refresh(for: worklaneStore.worklanes) { [weak self] paneID, resolution in
            self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }

    private func refreshReviewState(
        for worklaneID: WorklaneID,
        paneID: PaneID,
        forceReload: Bool = false
    ) {
        guard
            let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }),
            let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            let repoRoot = auxiliaryState.presentation.repoRoot,
            let branch = auxiliaryState.presentation.lookupBranch
        else {
            return
        }

        reviewStateResolver.refreshPane(
            repoRoot: repoRoot,
            branch: branch,
            paneID: paneID,
            forceReload: forceReload
        ) { [weak self] paneID, resolution in
            self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }
}
