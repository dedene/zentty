import AppKit
import QuartzCore

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

    private let attentionNotificationCoordinator: WorklaneAttentionNotificationCoordinator

    private var views: ViewBindings?
    private var currentPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] = []
    private var reviewPollingTimer: Timer?
    private var reviewPollingTarget: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)?

    var onNeedsSidebarSync: (() -> Void)?
    var themeProvider: (() -> ZenttyTheme)?
    var leadingInsetProvider: ((_ sidebarWidth: CGFloat) -> CGFloat)?
    var sidebarWidthProvider: (() -> CGFloat)?
    var windowStateProvider: (() -> (isVisible: Bool, isKeyWindow: Bool))?

    init(
        worklaneStore: WorklaneStore,
        runtimeRegistry: PaneRuntimeRegistry,
        notificationStore: NotificationStore,
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver()
    ) {
        self.worklaneStore = worklaneStore
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.attentionNotificationCoordinator = WorklaneAttentionNotificationCoordinator(
            notificationStore: notificationStore
        )
    }

    func bind(to views: ViewBindings) {
        self.views = views
        views.appCanvasView.paneStripView.onBorderChromeSnapshotsDidChange = { [weak self] snapshots in
            self?.currentPaneBorderChromeSnapshots = snapshots
            self?.renderPaneBorderContextOverlay()
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

    // MARK: - Internal

    private var currentTheme: ZenttyTheme {
        themeProvider?() ?? ZenttyTheme.fallback(for: nil)
    }

    private func handleWorklaneChange(_ change: WorklaneChange) {
        switch change {
        case .paneStructure, .focusChanged:
            renderCurrentWorklane(animated: true)
        case .layoutResized, .auxiliaryStateUpdated, .worklaneListChanged, .activeWorklaneChanged:
            renderCurrentWorklane(animated: false)
        }
    }

    private func renderCurrentWorklane(animated: Bool = false) {
        guard let views else {
            return
        }

        worklaneStore.batchUpdate { [self] in
            runtimeRegistry.synchronize(with: worklaneStore.worklanes)
            reviewStateResolver.refresh(for: worklaneStore.worklanes) { [weak self] paneID, resolution in
                self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
            }
            views.sidebarView.render(
                summaries: WorklaneSidebarSummaryBuilder.summaries(
                    for: worklaneStore.worklanes,
                    activeWorklaneID: worklaneStore.activeWorklaneID
                ),
                theme: currentTheme
            )
            onNeedsSidebarSync?()

            guard let worklane = worklaneStore.activeWorklane else {
                views.windowChromeView.render(summary: WorklaneChromeSummary(
                    attention: nil,
                    focusedLabel: nil,
                    branch: nil,
                    pullRequest: nil,
                    reviewChips: []
                ))
                return
            }

            let headerSummary = WorklaneHeaderSummaryBuilder.summary(for: worklane)
            views.windowChromeView.render(summary: headerSummary)
            renderCanvasForCurrentWorklane(animated: animated)
            let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
            attentionNotificationCoordinator.update(
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsKey: windowState.isKeyWindow
            )
            updateReviewPolling()
            updateRuntimeSurfaceActivities()
        }
    }

    private func renderCanvasForCurrentWorklane(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard let views, let worklane = worklaneStore.activeWorklane else {
            return
        }

        let sidebarWidth = sidebarWidthProvider?() ?? SidebarWidthPreference.defaultWidth
        let effectiveInset = leadingVisibleInsetOverride
            ?? leadingInsetProvider?(sidebarWidth)
            ?? 0

        views.appCanvasView.render(
            worklaneName: worklane.title,
            state: worklane.paneStripState,
            metadataByPaneID: worklane.auxiliaryStateByPaneID.compactMapValues(\.metadata),
            paneBorderContextByPaneID: worklane.paneBorderContextDisplayByPaneID,
            theme: currentTheme,
            leadingVisibleInset: effectiveInset,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    private func updateRuntimeSurfaceActivities() {
        guard !worklaneStore.worklanes.isEmpty else {
            return
        }

        let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
        runtimeRegistry.updateSurfaceActivities(
            worklanes: worklaneStore.worklanes,
            activeWorklaneID: worklaneStore.activeWorklaneID,
            windowIsVisible: windowState.isVisible,
            windowIsKey: windowState.isKeyWindow
        )
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

    private func renderPaneBorderContextOverlay() {
        views?.paneBorderContextOverlayView.render(
            snapshots: translatedPaneBorderChromeSnapshots,
            theme: currentTheme
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
        let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
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

        reviewStateResolver.refreshFocusedPane(
            repoRoot: target.repoRoot,
            branch: target.branch,
            paneID: target.paneID,
            forceReload: forceReload
        ) { [weak self] paneID, resolution in
            self?.worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }
}
