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
final class WorklaneRenderCoordinator {
    private enum ReviewPolling {
        static let interval: TimeInterval = 30
    }

    struct ViewBindings {
        let sidebarView: SidebarView
        let windowChromeView: WindowChromeView
        let appCanvasView: AppCanvasView
        let paneBorderContextOverlayView: PaneBorderContextOverlayView
    }

    let worklaneStore: WorklaneStore
    let runtimeRegistry: PaneRuntimeRegistry
    let reviewStateResolver: WorklaneReviewStateResolver
    private let terminalDiagnostics: TerminalDiagnostics
    private let configStore: AppConfigStore?

    private let attentionNotificationCoordinator: WorklaneAttentionNotificationCoordinator

    private var views: ViewBindings?
    private var currentPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] = []
    private var reviewPollingTimer: Timer?
    private var reviewPollingTarget: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)?
    private var hasBootstrappedReviewState = false
    private var needsRuntimeSynchronization = true

    weak var environment: RenderEnvironmentProviding?

    init(
        worklaneStore: WorklaneStore,
        runtimeRegistry: PaneRuntimeRegistry,
        notificationStore: NotificationStore,
        configStore: AppConfigStore? = nil,
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        terminalDiagnostics: TerminalDiagnostics = .shared
    ) {
        self.worklaneStore = worklaneStore
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.terminalDiagnostics = terminalDiagnostics
        self.configStore = configStore
        self.attentionNotificationCoordinator = WorklaneAttentionNotificationCoordinator(
            notificationStore: notificationStore,
            configStore: configStore
        )
    }

    func bind(to views: ViewBindings) {
        self.views = views
        views.appCanvasView.paneStripView.onBorderChromeSnapshotsDidChange = { [weak self] snapshots, animated in
            self?.currentPaneBorderChromeSnapshots = snapshots
            self?.renderPaneBorderContextOverlay(animated: animated)
        }
    }

    func startObserving() {
        worklaneStore.subscribe { [weak self] change in
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

    func renderBorderOverlay() {
        renderPaneBorderContextOverlay()
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
        case .historyChanged:
            break
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
                terminalDiagnostics.recordRender(.sidebar, activePaneID: activePaneID)
                views.sidebarView.render(
                    summaries: WorklaneSidebarSummaryBuilder.summaries(
                        for: worklaneStore.worklanes,
                        activeWorklaneID: worklaneStore.activeWorklaneID
                    ),
                    theme: currentTheme
                )
                environment?.renderSidebarSyncNeeded()

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
            views.appCanvasView.render(
                worklaneName: worklane.title,
                state: worklane.paneStripState,
                metadataByPaneID: worklane.auxiliaryStateByPaneID.compactMapValues(\.metadata),
                paneBorderContextByPaneID: worklane.paneBorderContextDisplayByPaneID,
                showsPaneLabels: paneSettings.showLabels,
                inactivePaneOpacity: paneSettings.inactiveOpacity,
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
                windowIsKey: windowState.isKeyWindow
            )
        }
    }

    var translatedPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] {
        guard let views else {
            return []
        }

        return currentPaneBorderChromeSnapshots.map { snapshot in
            PaneBorderChromeSnapshot(
                paneID: snapshot.paneID,
                frame: snapshot.frame.offsetBy(
                    dx: views.appCanvasView.frame.minX,
                    dy: views.appCanvasView.frame.minY
                ),
                isFocused: snapshot.isFocused,
                emphasis: snapshot.emphasis,
                borderContext: snapshot.borderContext
            )
        }
    }

    private func renderPaneBorderContextOverlay(animated: Bool = false) {
        guard let views else { return }
        if views.paneBorderContextOverlayView.isHidden,
           !views.appCanvasView.paneStripView.isDragActive {
            views.paneBorderContextOverlayView.isHidden = false
        }
        views.paneBorderContextOverlayView.render(
            snapshots: translatedPaneBorderChromeSnapshots,
            theme: currentTheme,
            animated: animated
        )
    }

    private func updateReviewPolling() {
        guard let target = makeReviewPollingTarget() else {
            reviewPollingTarget = nil
            reviewPollingTimer?.invalidate()
            reviewPollingTimer = nil
            return
        }

        let targetChanged = reviewPollingTarget?.worklaneID != target.worklaneID
            || reviewPollingTarget?.paneID != target.paneID
            || reviewPollingTarget?.repoRoot != target.repoRoot
            || reviewPollingTarget?.branch != target.branch

        reviewPollingTarget = target
        if reviewPollingTimer == nil || targetChanged {
            reviewPollingTimer?.invalidate()
            reviewPollingTimer = Timer.scheduledTimer(
                withTimeInterval: ReviewPolling.interval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshReviewPollingTarget(forceReload: true)
                }
            }
        }
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
            views.sidebarView.render(
                summaries: WorklaneSidebarSummaryBuilder.summaries(
                    for: worklaneStore.worklanes,
                    activeWorklaneID: worklaneStore.activeWorklaneID
                ),
                theme: currentTheme
            )
            environment?.renderSidebarSyncNeeded()
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
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsKey: windowState.isKeyWindow
            )
        }

        if impacts.contains(.reviewRefresh) {
            updateReviewPolling()
            refreshReviewState(for: worklaneID, paneID: paneID)
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

    private func refreshReviewState(for worklaneID: WorklaneID, paneID: PaneID) {
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
            paneID: paneID
        ) { [weak self] paneID, resolution in
            self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }
}
