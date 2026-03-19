import AppKit
import QuartzCore

@MainActor
final class RootViewController: NSViewController {
    private enum SidebarLayout {
        static let hoverRailWidth: CGFloat = 8
        static let toggleOverlayHeight: CGFloat = ChromeGeometry.headerHeight + (ShellMetrics.outerInset * 2)
        static let defaultTrafficLightAnchor = NSPoint(x: ChromeGeometry.trafficLightLeadingInset + 48, y: 0)
    }

    private let workspaceStore: WorkspaceStore
    private let paneLayoutDefaults: UserDefaults
    private let sidebarView = SidebarView()
    private let sidebarHoverRailView = SidebarHoverRailView()
    private let sidebarToggleOverlayView = SidebarToggleOverlayView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let agentStatusCenter = AgentStatusCenter()
    private let reviewStateResolver: WorkspaceReviewStateResolver
    private let workspaceReviewStateProvider = DefaultWorkspaceReviewStateProvider()
    private let sidebarMotionCoordinator: SidebarMotionCoordinator
    private let themeCoordinator: ThemeCoordinator
    private let attentionNotificationCoordinator = WorkspaceAttentionNotificationCoordinator()
    private var staleAgentSweepTimer: Timer?
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let paneBorderContextOverlayView = PaneBorderContextOverlayView()
    private let windowChromeView = WindowChromeView()
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var paneLayoutPreferences: PaneLayoutPreferences
    private var currentPaneLayoutContext: PaneLayoutContext
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var currentPaneBorderChromeSnapshots: [PaneBorderChromeSnapshot] = []
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var trafficLightAnchor = SidebarLayout.defaultTrafficLightAnchor
    private var suppressWorkspaceRender = false

    private var currentTheme: ZenttyTheme { themeCoordinator.currentTheme }

    init(
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        reviewStateResolver: WorkspaceReviewStateResolver = WorkspaceReviewStateResolver(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        initialLayoutContext: PaneLayoutContext = .fallback
    ) {
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.paneLayoutDefaults = paneLayoutDefaults
        self.paneLayoutPreferences = PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults)
        self.currentPaneLayoutContext = initialLayoutContext
        self.sidebarMotionCoordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            sidebarWidthDefaults: sidebarWidthDefaults
        )
        self.themeCoordinator = ThemeCoordinator()
        self.workspaceStore = WorkspaceStore(layoutContext: initialLayoutContext)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentView = WindowContentView()
        contentView.onEffectiveAppearanceDidChange = { [weak self] in
            guard let self else { return }
            self.themeCoordinator.refreshTheme(for: self.view.effectiveAppearance, animated: true)
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
            equalToConstant: sidebarMotionCoordinator.currentSidebarWidth
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

        workspaceStore.onChange = { [weak self] change in
            guard let self, !self.suppressWorkspaceRender else {
                return
            }
            self.handleWorkspaceChange(change)
        }
        appCanvasView.paneStripView.onFocusSettled = { [weak self] paneID in
            self?.workspaceStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneSelected = { [weak self] paneID in
            self?.workspaceStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneCloseRequested = { [weak self] paneID in
            self?.workspaceStore.closePane(id: paneID)
        }
        appCanvasView.paneStripView.onBorderChromeSnapshotsDidChange = { [weak self] snapshots in
            self?.currentPaneBorderChromeSnapshots = snapshots
            self?.renderPaneBorderContextOverlay()
        }
        sidebarView.delegate = self
        sidebarHoverRailView.onPointerEntered = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.hoverRailEntered)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarHoverRailView.onPointerExited = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.hoverRailExited)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarToggleOverlayView.onToggleSidebar = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.togglePressed)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarMotionCoordinator.onMotionStateDidChange = { [weak self] motionState, animated in
            self?.applySidebarMotionState(
                motionState,
                animated: animated,
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
        themeCoordinator.onThemeDidChange = { [weak self] theme, animated in
            self?.applyThemeToViews(theme, animated: animated)
        }
        runtimeRegistry.onMetadataDidChange = { [weak self] paneID, metadata in
            guard let self else {
                return
            }

            self.workspaceStore.updateMetadata(id: paneID, metadata: metadata)
        }
        runtimeRegistry.onEventDidOccur = { [weak self] paneID, event in
            self?.workspaceStore.handleTerminalEvent(paneID: paneID, event: event)
        }
        agentStatusCenter.onPayload = { [weak self] payload in
            self?.workspaceStore.applyAgentStatusPayload(payload)
        }
        agentStatusCenter.start()
        sidebarToggleOverlayView.setTrafficLightAnchor(
            trailingX: trafficLightAnchor.x,
            midYInSuperview: trafficLightAnchor.y > 0 ? trafficLightAnchor.y : nil
        )
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        updatePaneLayoutContextIfNeeded(force: true)
        updatePaneViewportHeight()
        installStaleAgentSweepTimer()
        themeCoordinator.refreshTheme(for: NSApp.effectiveAppearance, animated: false)
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
            workspaceStore.createWorkspace()
        case .pane(let command):
            workspaceStore.send(command)
        }
    }

    private func syncFocusedPaneWithResponderIfNeeded(_ responder: NSResponder?) {
        guard let paneID = paneID(containing: responder),
              workspaceStore.activeWorkspace?.paneStripState.focusedPaneID != paneID else {
            return
        }

        workspaceStore.focusPane(id: paneID)
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

    private func handleWorkspaceChange(_ change: WorkspaceChange) {
        switch change {
        case .paneStructure, .focusChanged:
            renderCurrentWorkspace(animated: true)
        case .layoutResized, .auxiliaryStateUpdated, .workspaceListChanged, .activeWorkspaceChanged:
            renderCurrentWorkspace(animated: false)
        }
    }

    private func renderCurrentWorkspace(animated: Bool = false) {
        suppressWorkspaceRender = true
        defer { suppressWorkspaceRender = false }

        runtimeRegistry.synchronize(with: workspaceStore.workspaces)
        reviewStateResolver.refresh(for: workspaceStore.workspaces) { [weak self] paneID, resolution in
            self?.workspaceStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        }
        sidebarView.render(
            summaries: WorkspaceSidebarSummaryBuilder.summaries(
                for: workspaceStore.workspaces,
                activeWorkspaceID: workspaceStore.activeWorkspaceID
            ),
            theme: currentTheme
        )
        syncSidebarVisibilityControls(animated: false)

        guard let workspace = workspaceStore.activeWorkspace else {
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
        renderCanvasForCurrentWorkspace(animated: animated)
        attentionNotificationCoordinator.update(
            workspaces: workspaceStore.workspaces,
            activeWorkspaceID: workspaceStore.activeWorkspaceID,
            windowIsKey: view.window?.isKeyWindow ?? false
        )
        updateRuntimeSurfaceActivities()
    }

    private func installStaleAgentSweepTimer() {
        staleAgentSweepTimer?.invalidate()
        staleAgentSweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.workspaceStore.clearStaleAgentSessions()
            }
        }
    }

    private func renderCanvasForCurrentWorkspace(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard let workspace = workspaceStore.activeWorkspace else {
            return
        }

        let effectiveInset = leadingVisibleInsetOverride
            ?? sidebarMotionCoordinator.effectiveLeadingInset(
                sidebarWidth: sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
            )

        appCanvasView.render(
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

    private func applyThemeToViews(_ theme: ZenttyTheme, animated: Bool) {
        apply(theme: theme, animated: animated)
        sidebarView.apply(theme: theme, animated: animated)
        sidebarToggleOverlayView.apply(theme: theme, animated: animated)
        windowChromeView.apply(theme: theme, animated: animated)
        appCanvasView.apply(theme: theme, animated: animated)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        renderPaneBorderContextOverlay()
    }

    private func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.view.layer?.backgroundColor = theme.windowBackground.cgColor
            self.view.layer?.borderColor = theme.topChromeBorder.cgColor
        }
    }

    private func updateRuntimeSurfaceActivities() {
        guard !workspaceStore.workspaces.isEmpty else {
            return
        }

        runtimeRegistry.updateSurfaceActivities(
            workspaces: workspaceStore.workspaces,
            activeWorkspaceID: workspaceStore.activeWorkspaceID,
            windowIsVisible: view.window?.isVisible ?? false,
            windowIsKey: view.window?.isKeyWindow ?? false
        )
    }

    private func handleSidebarWidthChange(_ width: CGFloat) {
        sidebarMotionCoordinator.setSidebarWidth(width, persist: true)
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
    }

    private func syncSidebarVisibilityControls(animated: Bool) {
        sidebarView.setResizeEnabled(sidebarMotionCoordinator.showsResizeHandle)
        sidebarToggleOverlayView.setSidebarVisibility(sidebarMotionCoordinator.mode, animated: animated)
    }

    private func applySidebarMotionState(
        _ motionState: SidebarMotionState,
        animated: Bool,
        reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
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
        let previousWorkspaceState = workspaceStore.state
        let previousLayoutContext = currentPaneLayoutContext
        suppressWorkspaceRender = true
        updatePaneLayoutContextIfNeeded(force: true, leadingVisibleInsetOverride: reservedInset)
        suppressWorkspaceRender = false
        let needsCanvasTransition = abs(previousLeadingInset - reservedInset) > 0.001
            || previousWorkspaceState != workspaceStore.state
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

    var currentSidebarWidth: CGFloat {
        sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
    }

    var sidebarVisibilityMode: SidebarVisibilityMode {
        sidebarMotionCoordinator.mode
    }

    var isSidebarFloating: Bool {
        sidebarMotionCoordinator.isFloating
    }

    var sidebarToggleMinX: CGFloat {
        sidebarToggleOverlayView.toggleFrameInSuperview.minX
    }

    var sidebarToggleMidY: CGFloat {
        sidebarToggleOverlayView.toggleFrameInSuperview.midY
    }

    var isSidebarToggleActive: Bool {
        sidebarToggleOverlayView.isToggleActive
    }

    var currentPaneLayoutPreferences: PaneLayoutPreferences {
        paneLayoutPreferences
    }

    var workspaceTitles: [String] {
        workspaceStore.workspaces.map(\.title)
    }

    var activeWorkspaceTitle: String? {
        workspaceStore.activeWorkspace?.title
    }

    var activePaneTitles: [String] {
        workspaceStore.activeWorkspace?.paneStripState.panes.map(\.title) ?? []
    }

    var focusedPaneTitle: String? {
        workspaceStore.activeWorkspace?.paneStripState.focusedPane?.title
    }

    private func updatePaneViewportHeight() {
        workspaceStore.updatePaneViewportHeight(appCanvasView.bounds.height)
    }

    var chromeView: WindowChromeView {
        windowChromeView
    }

    #if DEBUG
    func handleSidebarVisibilityEvent(_ event: SidebarVisibilityEvent) {
        sidebarMotionCoordinator.handle(event)
        syncSidebarVisibilityControls(animated: false)
    }

    func replaceWorkspaces(_ workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID? = nil) {
        workspaceStore.replaceWorkspaces(workspaces, activeWorkspaceID: activeWorkspaceID)
        renderCurrentWorkspace()
    }

    func focusPaneDirectly(_ paneID: PaneID) {
        workspaceStore.focusPane(id: paneID)
        renderCurrentWorkspace()
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarMotionCoordinator.setSidebarWidth(width, persist: false)
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
    }
    #endif

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
        workspaceStore.updateLayoutContext(resolvedContext)
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
            sizing: PaneLayoutSizing.forSidebarVisibility(sidebarMotionCoordinator.mode)
        )
    }
}

extension RootViewController: SidebarViewDelegate {
    func sidebarView(_ sidebarView: SidebarView, didSelectWorkspace id: WorkspaceID) {
        workspaceStore.selectWorkspace(id: id)
    }

    func sidebarViewDidRequestNewWorkspace(_ sidebarView: SidebarView) {
        handle(.newWorkspace)
    }

    func sidebarView(_ sidebarView: SidebarView, didResizeToWidth width: CGFloat) {
        handleSidebarWidthChange(width)
    }

    func sidebarViewPointerDidEnter(_ sidebarView: SidebarView) {
        sidebarMotionCoordinator.handle(.sidebarEntered)
        syncSidebarVisibilityControls(animated: true)
    }

    func sidebarViewPointerDidExit(_ sidebarView: SidebarView) {
        sidebarMotionCoordinator.handle(.sidebarExited)
        syncSidebarVisibilityControls(animated: true)
    }
}

@MainActor
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
