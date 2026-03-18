import AppKit
import QuartzCore

final class RootViewController: NSViewController {
    private enum SidebarLayout {
        static let hoverRailWidth: CGFloat = 8
        static let dismissDelay: TimeInterval = 0.15
        static let toggleOverlayHeight: CGFloat = ChromeGeometry.headerHeight + (ShellMetrics.outerInset * 2)
        static let defaultTrafficLightAnchor = NSPoint(x: ChromeGeometry.trafficLightLeadingInset + 48, y: 0)
    }

    private let paneStripStore: PaneStripStore
    private let sidebarWidthDefaults: UserDefaults
    private let sidebarVisibilityDefaults: UserDefaults
    private let paneLayoutDefaults: UserDefaults
    private let sidebarView = SidebarView()
    private let sidebarHoverRailView = SidebarHoverRailView()
    private let sidebarToggleOverlayView = SidebarToggleOverlayView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let agentStatusCenter = AgentStatusCenter()
    private let reviewStateResolver: WorkspaceReviewStateResolver
    private let workspaceReviewStateProvider = DefaultWorkspaceReviewStateProvider()
    private let themeResolver = GhosttyThemeResolver()
    private let themeWatcher = GhosttyThemeWatcher()
    private let attentionNotificationCoordinator = WorkspaceAttentionNotificationCoordinator()
    private var staleAgentSweepTimer: Timer?
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let paneBorderContextOverlayView = PaneBorderContextOverlayView()
    private let windowChromeView = WindowChromeView()
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var paneLayoutPreferences: PaneLayoutPreferences
    private var currentPaneLayoutContext: PaneLayoutContext
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var currentPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] = []
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var sidebarVisibilityController: SidebarVisibilityController
    private var currentSidebarMotionState: SidebarMotionState
    private var sidebarDismissWorkItem: DispatchWorkItem?
    private var trafficLightAnchor = SidebarLayout.defaultTrafficLightAnchor
    private var suppressWorkspaceRender = false

    init(
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        reviewStateResolver: WorkspaceReviewStateResolver = WorkspaceReviewStateResolver(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        initialLayoutContext: PaneLayoutContext = .fallback
    ) {
        let restoredSidebarVisibility = SidebarVisibilityPreference.restoredVisibility(from: sidebarVisibilityDefaults)
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.sidebarWidthDefaults = sidebarWidthDefaults
        self.sidebarVisibilityDefaults = sidebarVisibilityDefaults
        self.paneLayoutDefaults = paneLayoutDefaults
        self.paneLayoutPreferences = PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults)
        self.currentPaneLayoutContext = initialLayoutContext
        self.sidebarVisibilityController = SidebarVisibilityController(mode: restoredSidebarVisibility)
        self.currentSidebarMotionState = SidebarMotionState(mode: restoredSidebarVisibility)
        self.paneStripStore = PaneStripStore(layoutContext: initialLayoutContext)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentView = WindowContentView()
        contentView.onEffectiveAppearanceDidChange = { [weak self] in
            self?.refreshTheme(animated: true)
        }
        view = contentView
        view.wantsLayer = true
        view.layer?.cornerRadius = ChromeGeometry.outerWindowRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        apply(theme: currentTheme, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        appCanvasView.translatesAutoresizingMaskIntoConstraints = false
        paneBorderContextOverlayView.translatesAutoresizingMaskIntoConstraints = false
        windowChromeView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarHoverRailView.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleOverlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appCanvasView)
        view.addSubview(paneBorderContextOverlayView)
        view.addSubview(windowChromeView)
        view.addSubview(sidebarHoverRailView)
        view.addSubview(sidebarView)
        view.addSubview(sidebarToggleOverlayView)

        let sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: SidebarWidthPreference.restoredWidth(from: sidebarWidthDefaults)
        )
        let sidebarLeadingConstraint = sidebarView.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: ShellMetrics.outerInset
        )
        self.sidebarWidthConstraint = sidebarWidthConstraint
        self.sidebarLeadingConstraint = sidebarLeadingConstraint

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            sidebarLeadingConstraint,
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ShellMetrics.outerInset),
            sidebarWidthConstraint,

            appCanvasView.topAnchor.constraint(equalTo: windowChromeView.bottomAnchor),
            appCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            appCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ShellMetrics.canvasOuterInset),
            appCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ShellMetrics.canvasOuterInset),

            paneBorderContextOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            paneBorderContextOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneBorderContextOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneBorderContextOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            windowChromeView.topAnchor.constraint(equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ShellMetrics.outerInset),
            windowChromeView.heightAnchor.constraint(equalToConstant: WindowChromeView.preferredHeight),

            sidebarHoverRailView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarHoverRailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarHoverRailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarHoverRailView.widthAnchor.constraint(equalToConstant: SidebarLayout.hoverRailWidth),

            sidebarToggleOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarToggleOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarToggleOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebarToggleOverlayView.heightAnchor.constraint(equalToConstant: SidebarLayout.toggleOverlayHeight),
        ])

        paneStripStore.onChange = { [weak self] _ in
            guard let self, !self.suppressWorkspaceRender else {
                return
            }
            self.renderCurrentWorkspace()
        }
        appCanvasView.onFocusSettled = { [weak self] paneID in
            self?.paneStripStore.focusPane(id: paneID)
        }
        appCanvasView.onPaneSelected = { [weak self] paneID in
            self?.paneStripStore.focusPane(id: paneID)
        }
        appCanvasView.onPaneCloseRequested = { [weak self] paneID in
            self?.paneStripStore.closePane(id: paneID)
        }
        appCanvasView.onBorderChromeSnapshotsDidChange = { [weak self] snapshots in
            self?.currentPaneBorderChromeSnapshots = snapshots
            self?.renderPaneBorderContextOverlay()
        }
        sidebarView.onSelectWorkspace = { [weak self] workspaceID in
            self?.paneStripStore.selectWorkspace(id: workspaceID)
        }
        sidebarView.onCreateWorkspace = { [weak self] in
            self?.handle(.newWorkspace)
        }
        sidebarView.onResizeWidth = { [weak self] width in
            self?.setSidebarWidth(width, persist: true)
        }
        sidebarView.onPointerEntered = { [weak self] in
            self?.handleSidebarVisibilityEvent(.sidebarEntered)
        }
        sidebarView.onPointerExited = { [weak self] in
            self?.handleSidebarVisibilityEvent(.sidebarExited)
        }
        sidebarHoverRailView.onPointerEntered = { [weak self] in
            self?.handleSidebarVisibilityEvent(.hoverRailEntered)
        }
        sidebarHoverRailView.onPointerExited = { [weak self] in
            self?.handleSidebarVisibilityEvent(.hoverRailExited)
        }
        sidebarToggleOverlayView.onToggleSidebar = { [weak self] in
            self?.handleSidebarVisibilityEvent(.togglePressed)
        }
        runtimeRegistry.onMetadataDidChange = { [weak self] paneID, metadata in
            guard let self else {
                return
            }

            self.paneStripStore.updateMetadata(id: paneID, metadata: metadata)
        }
        runtimeRegistry.onEventDidOccur = { [weak self] paneID, event in
            self?.paneStripStore.handleTerminalEvent(paneID: paneID, event: event)
        }
        agentStatusCenter.onPayload = { [weak self] payload in
            self?.paneStripStore.applyAgentStatusPayload(payload)
        }
        agentStatusCenter.start()
        themeWatcher.onChange = { [weak self] in
            self?.refreshTheme(animated: true)
        }
        sidebarToggleOverlayView.setTrafficLightAnchor(
            trailingX: trafficLightAnchor.x,
            midYInSuperview: trafficLightAnchor.y > 0 ? trafficLightAnchor.y : nil
        )
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(currentSidebarMotionState, animated: false)
        updatePaneLayoutContextIfNeeded(force: true)
        updatePaneViewportHeight()
        installStaleAgentSweepTimer()
        refreshTheme(animated: false)
        renderCurrentWorkspace()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePaneLayoutContextIfNeeded()
        updatePaneViewportHeight()
        renderPaneBorderContextOverlay()
    }

    func activateWindowBindingsIfNeeded() {
        installKeyboardMonitorIfNeeded()
        installWindowObserversIfNeeded()
        updateRuntimeSurfaceActivities()
        appCanvasView.focusCurrentPaneIfNeeded()
    }

    func updateTrafficLightAnchor(_ anchor: NSPoint) {
        trafficLightAnchor = anchor
        sidebarToggleOverlayView.setTrafficLightAnchor(trailingX: anchor.x, midYInSuperview: anchor.y)
    }

    private func installKeyboardMonitorIfNeeded() {
        guard !hasInstalledKeyMonitor else {
            return
        }

        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            guard self.view.window?.isKeyWindow == true else {
                return event
            }

            guard let shortcut = KeyboardShortcut(event: event),
                  let action = KeyboardShortcutResolver.resolve(shortcut) else {
                return event
            }

            self.handle(action)
            return nil
        }
        hasInstalledKeyMonitor = true
    }

    func handle(_ action: AppAction) {
        handle(action, syncingFocusWith: view.window?.firstResponder)
    }

    func handle(_ action: AppAction, syncingFocusWith responder: NSResponder?) {
        syncFocusedPaneWithResponderIfNeeded(responder)

        switch action {
        case .newWorkspace:
            paneStripStore.createWorkspace()
        case .pane(let command):
            paneStripStore.send(command)
        }
    }

    private func syncFocusedPaneWithResponderIfNeeded(_ responder: NSResponder?) {
        guard let paneID = paneID(containing: responder),
              paneStripStore.activeWorkspace?.paneStripState.focusedPaneID != paneID else {
            return
        }

        paneStripStore.focusPane(id: paneID)
    }

    private func paneID(containing responder: NSResponder?) -> PaneID? {
        guard let view = responder as? NSView else {
            return nil
        }

        var currentView: NSView? = view
        while let current = currentView {
            if let paneView = current as? PaneContainerView {
                return paneView.paneID
            }
            currentView = current.superview
        }

        return nil
    }

    private func installWindowObserversIfNeeded() {
        guard !hasInstalledWindowObservers, let window = view.window else {
            return
        }

        let notificationCenter = NotificationCenter.default
        [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
        ].forEach { name in
            notificationCenter.addObserver(
                self,
                selector: #selector(handleWindowStateDidChange),
                name: name,
                object: window
            )
        }
        hasInstalledWindowObservers = true
    }

    @objc
    private func handleWindowStateDidChange() {
        updatePaneLayoutContextIfNeeded(force: true)
        updateRuntimeSurfaceActivities()
    }

    private func renderCurrentWorkspace() {
        runtimeRegistry.synchronize(with: paneStripStore.workspaces)
        reviewStateResolver.refresh(for: paneStripStore.workspaces) { [weak self] paneID, resolution in
            self?.paneStripStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
        sidebarView.render(
            summaries: WorkspaceSidebarSummaryBuilder.summaries(
                for: paneStripStore.workspaces,
                activeWorkspaceID: paneStripStore.activeWorkspaceID
            ),
            theme: currentTheme
        )
        syncSidebarVisibilityControls(animated: false)

        guard let workspace = paneStripStore.activeWorkspace else {
            windowChromeView.render(summary: WorkspaceChromeSummary(
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
            reviewStateProvider: workspaceReviewStateProvider
        )
        windowChromeView.render(summary: headerSummary)
        renderCanvasForCurrentWorkspace()
        attentionNotificationCoordinator.update(
            workspaces: paneStripStore.workspaces,
            activeWorkspaceID: paneStripStore.activeWorkspaceID,
            windowIsKey: view.window?.isKeyWindow ?? false
        )
        updateRuntimeSurfaceActivities()
    }

    private func installStaleAgentSweepTimer() {
        staleAgentSweepTimer?.invalidate()
        staleAgentSweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.paneStripStore.clearStaleAgentSessions()
            }
        }
    }

    private func renderCanvasForCurrentWorkspace(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard let workspace = paneStripStore.activeWorkspace else {
            return
        }

        appCanvasView.render(
            workspaceName: workspace.title,
            state: workspace.paneStripState,
            metadataByPaneID: workspace.metadataByPaneID,
            paneBorderContextByPaneID: workspace.paneBorderContextDisplayByPaneID,
            theme: currentTheme,
            leadingVisibleInset: leadingVisibleInsetOverride,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    private func refreshTheme(animated: Bool) {
        let resolution = themeResolver.resolve(for: view.effectiveAppearance)
        let theme = resolution.map {
            ZenttyTheme(
                resolvedTheme: $0.theme,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            )
        } ?? ZenttyTheme.fallback(
            for: view.effectiveAppearance,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        let didChange = theme != currentTheme
        currentTheme = theme
        apply(theme: theme, animated: animated && didChange)
        sidebarView.apply(theme: theme, animated: animated && didChange)
        sidebarToggleOverlayView.apply(theme: theme, animated: animated && didChange)
        windowChromeView.apply(theme: theme, animated: animated && didChange)
        appCanvasView.apply(theme: theme, animated: animated && didChange)
        applySidebarMotionState(currentSidebarMotionState, animated: false)
        renderPaneBorderContextOverlay()
        themeWatcher.watch(urls: resolution?.watchedURLs ?? [themeResolver.configURL])
    }

    private func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.view.layer?.backgroundColor = theme.windowBackground.cgColor
            self.view.layer?.borderColor = theme.topChromeBorder.cgColor
        }
    }

    private func updateRuntimeSurfaceActivities() {
        guard !paneStripStore.workspaces.isEmpty else {
            return
        }

        runtimeRegistry.updateSurfaceActivities(
            workspaces: paneStripStore.workspaces,
            activeWorkspaceID: paneStripStore.activeWorkspaceID,
            windowIsVisible: view.window?.isVisible ?? false,
            windowIsKey: view.window?.isKeyWindow ?? false
        )
    }

    private func setSidebarWidth(_ width: CGFloat, persist: Bool) {
        let clampedWidth = SidebarWidthPreference.clamped(width)
        sidebarWidthConstraint?.constant = clampedWidth
        applySidebarMotionState(currentSidebarMotionState, animated: false)

        if persist {
            SidebarWidthPreference.persist(clampedWidth, in: sidebarWidthDefaults)
        }
    }

    private func handleSidebarVisibilityEvent(_ event: SidebarVisibilityEvent) {
        if event == .togglePressed || event == .hoverRailEntered || event == .sidebarEntered {
            cancelSidebarDismissalTimer()
        }

        let previousMode = sidebarVisibilityController.mode
        sidebarVisibilityController.handle(event)
        let nextMode = sidebarVisibilityController.mode

        if sidebarVisibilityController.shouldScheduleDismissal {
            scheduleSidebarDismissalTimer()
        } else {
            cancelSidebarDismissalTimer()
        }

        guard previousMode != nextMode else {
            syncSidebarVisibilityControls(animated: true)
            return
        }

        SidebarVisibilityPreference.persist(sidebarVisibilityController.persistedMode, in: sidebarVisibilityDefaults)
        syncSidebarVisibilityControls(animated: true)
        applySidebarMotionState(
            SidebarMotionState(mode: nextMode),
            animated: true,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func syncSidebarVisibilityControls(animated: Bool) {
        sidebarView.setResizeEnabled(sidebarVisibilityController.showsResizeHandle)
        sidebarToggleOverlayView.setSidebarVisibility(sidebarVisibilityController.mode, animated: animated)
    }

    private func scheduleSidebarDismissalTimer() {
        cancelSidebarDismissalTimer()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleSidebarVisibilityEvent(.dismissTimerElapsed)
        }
        sidebarDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarLayout.dismissDelay, execute: workItem)
    }

    private func cancelSidebarDismissalTimer() {
        sidebarDismissWorkItem?.cancel()
        sidebarDismissWorkItem = nil
    }

    private func applySidebarMotionState(
        _ motionState: SidebarMotionState,
        animated: Bool,
        reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        currentSidebarMotionState = motionState

        let sidebarWidth = SidebarWidthPreference.clamped(
            sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
        )
        let hiddenTravel = sidebarWidth + ShellMetrics.shellGap
        let reservedInset = hiddenTravel * motionState.reservedFraction
        let leadingConstant = ShellMetrics.outerInset - ((1 - motionState.revealFraction) * hiddenTravel)
        let floatingStrength = max(0, motionState.revealFraction - motionState.reservedFraction)

        let duration = SidebarTransitionProfile.resolvedDuration(reducedMotion: reducedMotion)
        let timingFunction = SidebarTransitionProfile.resolvedTimingFunction(reducedMotion: reducedMotion)

        let previousLeadingInset = appCanvasView.leadingVisibleInset
        let previousWorkspaceState = paneStripStore.state
        let previousLayoutContext = currentPaneLayoutContext
        suppressWorkspaceRender = true
        updatePaneLayoutContextIfNeeded(force: true, leadingVisibleInsetOverride: reservedInset)
        suppressWorkspaceRender = false
        let needsCanvasTransition = abs(previousLeadingInset - reservedInset) > 0.001
            || previousWorkspaceState != paneStripStore.state
            || previousLayoutContext != currentPaneLayoutContext
        windowChromeView.leadingVisibleInset = reservedInset
        if needsCanvasTransition {
            renderCanvasForCurrentWorkspace(
                leadingVisibleInsetOverride: reservedInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        } else {
            appCanvasView.leadingVisibleInset = reservedInset
        }

        let applyState = {
            self.sidebarLeadingConstraint?.constant = leadingConstant
            self.sidebarView.alphaValue = motionState.revealFraction
            self.view.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timingFunction
                context.allowsImplicitAnimation = true
                self.sidebarLeadingConstraint?.animator().constant = leadingConstant
                self.sidebarView.animator().alphaValue = motionState.revealFraction
                self.view.layoutSubtreeIfNeeded()
            }
        } else {
            applyState()
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? duration : 0)
        CATransaction.setAnimationTimingFunction(animated ? timingFunction : nil)
        CATransaction.setDisableActions(!animated)
        sidebarView.layer?.shadowColor = currentTheme.underlapShadow.cgColor
        sidebarView.layer?.shadowOpacity = Float(floatingStrength * 0.28)
        sidebarView.layer?.shadowRadius = 18 * floatingStrength
        sidebarView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        CATransaction.commit()
    }

    var sidebarWidthForTesting: CGFloat {
        sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
    }

    var sidebarVisibilityModeForTesting: SidebarVisibilityMode {
        sidebarVisibilityController.mode
    }

    var isSidebarFloatingForTesting: Bool {
        sidebarVisibilityController.isFloating
    }

    var sidebarToggleMinXForTesting: CGFloat {
        sidebarToggleOverlayView.toggleFrameInSuperviewForTesting.minX
    }

    var sidebarToggleMidYForTesting: CGFloat {
        sidebarToggleOverlayView.toggleFrameInSuperviewForTesting.midY
    }

    var isSidebarToggleActiveForTesting: Bool {
        sidebarToggleOverlayView.isToggleActiveForTesting
    }

    func handleSidebarVisibilityEventForTesting(_ event: SidebarVisibilityEvent) {
        handleSidebarVisibilityEvent(event)
    }

    var paneLayoutPreferencesForTesting: PaneLayoutPreferences {
        paneLayoutPreferences
    }

    var workspaceTitlesForTesting: [String] {
        paneStripStore.workspaces.map(\.title)
    }

    var activeWorkspaceTitleForTesting: String? {
        paneStripStore.activeWorkspace?.title
    }

    var activePaneTitlesForTesting: [String] {
        paneStripStore.activeWorkspace?.paneStripState.panes.map(\.title) ?? []
    }

    var focusedPaneTitleForTesting: String? {
        paneStripStore.activeWorkspace?.paneStripState.focusedPane?.title
    }

    private func updatePaneViewportHeight() {
        paneStripStore.updatePaneViewportHeight(appCanvasView.bounds.height)
    }

    var windowChromeViewForTesting: WindowChromeView {
        windowChromeView
    }

    func replaceWorkspacesForTesting(_ workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID? = nil) {
        paneStripStore.replaceWorkspacesForTesting(workspaces, activeWorkspaceID: activeWorkspaceID)
        renderCurrentWorkspace()
    }

    func focusPaneForTesting(_ paneID: PaneID) {
        paneStripStore.focusPane(id: paneID)
        renderCurrentWorkspace()
    }

    func setSidebarWidthForTesting(_ width: CGFloat) {
        setSidebarWidth(width, persist: false)
    }

    private func updateCanvasLeadingInset(_ leadingVisibleInset: CGFloat? = nil) {
        let leadingVisibleInset = leadingVisibleInset
            ?? (sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth) + ShellMetrics.shellGap
        appCanvasView.leadingVisibleInset = leadingVisibleInset
        windowChromeView.leadingVisibleInset = leadingVisibleInset
    }

    private var translatedPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] {
        currentPaneBorderChromeSnapshots.map { snapshot in
            PaneBorderChromeSnapshot(
                paneID: snapshot.paneID,
                frame: snapshot.frame.offsetBy(dx: appCanvasView.frame.minX, dy: appCanvasView.frame.minY),
                isFocused: snapshot.isFocused,
                emphasis: snapshot.emphasis,
                borderContext: snapshot.borderContext
            )
        }
    }

    private func renderPaneBorderContextOverlay() {
        paneBorderContextOverlayView.render(
            snapshots: translatedPaneBorderChromeSnapshots,
            theme: currentTheme
        )
    }
    func updatePaneLayoutPreferences(_ preferences: PaneLayoutPreferences) {
        paneLayoutPreferences = preferences
        PaneLayoutPreferenceStore.persist(preferences.laptopPreset, for: .laptop, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(preferences.largeDisplayPreset, for: .largeDisplay, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(preferences.ultrawidePreset, for: .ultrawide, in: paneLayoutDefaults)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCurrentWorkspace()
    }

    private func updatePaneLayoutContextIfNeeded(
        force: Bool = false,
        leadingVisibleInsetOverride: CGFloat? = nil
    ) {
        let resolvedContext = resolveCurrentPaneLayoutContext(
            leadingVisibleInsetOverride: leadingVisibleInsetOverride
        )
        guard force || resolvedContext != currentPaneLayoutContext else {
            return
        }

        currentPaneLayoutContext = resolvedContext
        paneStripStore.updateLayoutContext(resolvedContext)
    }

    private func resolveCurrentPaneLayoutContext(
        leadingVisibleInsetOverride: CGFloat? = nil
    ) -> PaneLayoutContext {
        let viewportWidth = max(
            appCanvasView.bounds.width,
            view.bounds.width - (ShellMetrics.outerInset * 2)
        )
        let displayClass = PaneDisplayClassResolver.resolve(
            screen: view.window?.screen,
            viewportWidth: viewportWidth
        )

        return paneLayoutPreferences.makeLayoutContext(
            displayClass: displayClass,
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInsetOverride ?? appCanvasView.leadingVisibleInset,
            sizing: PaneLayoutSizing.forSidebarVisibility(sidebarVisibilityController.mode)
        )
    }
}

private final class WindowContentView: NSView {
    var onEffectiveAppearanceDidChange: (() -> Void)?

    override var fittingSize: NSSize {
        NSSize(width: 1, height: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceDidChange?()
    }
}
