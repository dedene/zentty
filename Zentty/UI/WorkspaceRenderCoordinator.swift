import AppKit
import QuartzCore

@MainActor
final class WorkspaceRenderCoordinator {
    private enum ReviewPolling {
        static let interval: TimeInterval = 30
    }

    struct ViewBindings {
        let sidebarView: SidebarView
        let windowChromeView: WindowChromeView
        let appCanvasView: AppCanvasView
        let paneBorderContextOverlayView: PaneBorderContextOverlayView
    }

    let workspaceStore: WorkspaceStore
    let runtimeRegistry: PaneRuntimeRegistry
    let reviewStateResolver: WorkspaceReviewStateResolver

    private let reviewStateProvider = DefaultWorkspaceReviewStateProvider()
    private let attentionNotificationCoordinator = WorkspaceAttentionNotificationCoordinator()

    private var views: ViewBindings?
    private var currentPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] = []
    private var reviewPollingTimer: Timer?
    private var reviewPollingTarget: (workspaceID: WorkspaceID, paneID: PaneID, path: String, preferredBranch: String?)?

    var onNeedsSidebarSync: (() -> Void)?
    var themeProvider: (() -> ZenttyTheme)?
    var leadingInsetProvider: ((_ sidebarWidth: CGFloat) -> CGFloat)?
    var sidebarWidthProvider: (() -> CGFloat)?
    var windowStateProvider: (() -> (isVisible: Bool, isKeyWindow: Bool))?

    init(
        workspaceStore: WorkspaceStore,
        runtimeRegistry: PaneRuntimeRegistry,
        reviewStateResolver: WorkspaceReviewStateResolver = WorkspaceReviewStateResolver()
    ) {
        self.workspaceStore = workspaceStore
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
    }

    func bind(to views: ViewBindings) {
        self.views = views
        views.appCanvasView.paneStripView.onBorderChromeSnapshotsDidChange = { [weak self] snapshots in
            self?.currentPaneBorderChromeSnapshots = snapshots
            self?.renderPaneBorderContextOverlay()
        }
    }

    func startObserving() {
        workspaceStore.subscribe { [weak self] change in
            self?.handleWorkspaceChange(change)
        }
    }

    // MARK: - Public render API

    func render(animated: Bool = false) {
        renderCurrentWorkspace(animated: animated)
    }

    func renderCanvas(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        renderCanvasForCurrentWorkspace(
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

    private func handleWorkspaceChange(_ change: WorkspaceChange) {
        switch change {
        case .paneStructure, .focusChanged:
            renderCurrentWorkspace(animated: true)
        case .layoutResized, .auxiliaryStateUpdated, .workspaceListChanged, .activeWorkspaceChanged:
            renderCurrentWorkspace(animated: false)
        }
    }

    private func renderCurrentWorkspace(animated: Bool = false) {
        guard let views else {
            return
        }

        workspaceStore.batchUpdate { [self] in
            runtimeRegistry.synchronize(with: workspaceStore.workspaces)
            reviewStateResolver.refresh(for: workspaceStore.workspaces) { [weak self] paneID, resolution in
                self?.workspaceStore.updateReviewResolution(paneID: paneID, resolution: resolution)
            }
            views.sidebarView.render(
                summaries: WorkspaceSidebarSummaryBuilder.summaries(
                    for: workspaceStore.workspaces,
                    activeWorkspaceID: workspaceStore.activeWorkspaceID
                ),
                theme: currentTheme
            )
            onNeedsSidebarSync?()

            guard let workspace = workspaceStore.activeWorkspace else {
                views.windowChromeView.render(summary: WorkspaceChromeSummary(
                    attention: nil,
                    focusedLabel: nil,
                    branch: nil,
                    pullRequest: nil,
                    reviewChips: []
                ))
                return
            }

            let headerSummary = WorkspaceHeaderSummaryBuilder.summary(
                for: workspace,
                reviewStateProvider: reviewStateProvider
            )
            views.windowChromeView.render(summary: headerSummary)
            renderCanvasForCurrentWorkspace(animated: animated)
            let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
            attentionNotificationCoordinator.update(
                workspaces: workspaceStore.workspaces,
                activeWorkspaceID: workspaceStore.activeWorkspaceID,
                windowIsKey: windowState.isKeyWindow
            )
            updateReviewPolling()
            updateRuntimeSurfaceActivities()
        }
    }

    private func renderCanvasForCurrentWorkspace(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard let views, let workspace = workspaceStore.activeWorkspace else {
            return
        }

        let sidebarWidth = sidebarWidthProvider?() ?? SidebarWidthPreference.defaultWidth
        let effectiveInset = leadingVisibleInsetOverride
            ?? leadingInsetProvider?(sidebarWidth)
            ?? 0

        views.appCanvasView.render(
            workspaceName: workspace.title,
            state: workspace.paneStripState,
            metadataByPaneID: workspace.auxiliaryStateByPaneID.compactMapValues(\.metadata),
            paneBorderContextByPaneID: workspace.paneBorderContextDisplayByPaneID,
            theme: currentTheme,
            leadingVisibleInset: effectiveInset,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    private func updateRuntimeSurfaceActivities() {
        guard !workspaceStore.workspaces.isEmpty else {
            return
        }

        let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
        runtimeRegistry.updateSurfaceActivities(
            workspaces: workspaceStore.workspaces,
            activeWorkspaceID: workspaceStore.activeWorkspaceID,
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

        let targetChanged = reviewPollingTarget?.workspaceID != target.workspaceID
            || reviewPollingTarget?.paneID != target.paneID
            || reviewPollingTarget?.path != target.path
            || reviewPollingTarget?.preferredBranch != target.preferredBranch

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

    private func makeReviewPollingTarget() -> (workspaceID: WorkspaceID, paneID: PaneID, path: String, preferredBranch: String?)? {
        let windowState = windowStateProvider?() ?? (isVisible: false, isKeyWindow: false)
        guard windowState.isVisible, windowState.isKeyWindow,
              let workspace = workspaceStore.activeWorkspace,
              let paneID = workspace.paneStripState.focusedPaneID,
              let auxiliaryState = workspace.auxiliaryStateByPaneID[paneID],
              let path = auxiliaryState.localReviewWorkingDirectory
        else {
            return nil
        }

        return (
            workspaceID: workspace.id,
            paneID: paneID,
            path: path,
            preferredBranch: auxiliaryState.metadata?.gitBranch
        )
    }

    private func refreshReviewPollingTarget(forceReload: Bool) {
        guard let target = reviewPollingTarget else {
            return
        }

        reviewStateResolver.refreshFocusedPane(
            path: target.path,
            preferredBranch: target.preferredBranch,
            paneID: target.paneID,
            forceReload: forceReload
        ) { [weak self] paneID, resolution in
            self?.workspaceStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
    }
}
