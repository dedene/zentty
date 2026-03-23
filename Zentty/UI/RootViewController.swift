import AppKit
import QuartzCore

@MainActor
final class RootViewController: NSViewController {
    private enum SidebarLayout {
        static let hoverRailWidth: CGFloat = 8
        static let defaultTrafficLightAnchor = NSPoint(x: ChromeGeometry.trafficLightLeadingInset + 48, y: 0)
    }

    private enum PaneResize {
        static let minimumColumns: CGFloat = 40
        static let minimumRows: CGFloat = 8
    }

    private let workspaceStore: WorkspaceStore
    private let paneLayoutDefaults: UserDefaults
    private let sidebarView = SidebarView()
    private let sidebarHoverRailView = SidebarHoverRailView()
    private let sidebarToggleButton = SidebarToggleButton()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let agentStatusCenter = AgentStatusCenter()
    private let sidebarMotionCoordinator: SidebarMotionCoordinator
    private let themeCoordinator: ThemeCoordinator
    private let renderCoordinator: WorkspaceRenderCoordinator
    private var staleAgentSweepTimer: Timer?
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let paneBorderContextOverlayView = PaneBorderContextOverlayView()
    private let windowChromeView = WindowChromeView()
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var paneLayoutPreferences: PaneLayoutPreferences
    private var currentPaneLayoutContext: PaneLayoutContext
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var toggleLeadingConstraint: NSLayoutConstraint?
    private var toggleTopConstraint: NSLayoutConstraint?
    private var trafficLightAnchor = SidebarLayout.defaultTrafficLightAnchor

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
        self.paneLayoutDefaults = paneLayoutDefaults
        self.paneLayoutPreferences = PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults)
        self.currentPaneLayoutContext = initialLayoutContext
        self.sidebarMotionCoordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            sidebarWidthDefaults: sidebarWidthDefaults
        )
        self.themeCoordinator = ThemeCoordinator()
        self.workspaceStore = WorkspaceStore(layoutContext: initialLayoutContext)
        self.renderCoordinator = WorkspaceRenderCoordinator(
            workspaceStore: workspaceStore,
            runtimeRegistry: runtimeRegistry,
            reviewStateResolver: reviewStateResolver
        )
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
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appCanvasView)
        view.addSubview(paneBorderContextOverlayView)
        view.addSubview(windowChromeView)
        view.addSubview(sidebarHoverRailView)
        view.addSubview(sidebarView)
        view.addSubview(sidebarToggleButton)

        let sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarMotionCoordinator.currentSidebarWidth
        )
        let sidebarLeadingConstraint = sidebarView.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: ShellMetrics.outerInset
        )
        self.sidebarWidthConstraint = sidebarWidthConstraint
        self.sidebarLeadingConstraint = sidebarLeadingConstraint

        let initialSidebarTrailing = ShellMetrics.outerInset + sidebarMotionCoordinator.currentSidebarWidth
        let toggleLeadingConstraint = sidebarToggleButton.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: initialSidebarTrailing + ShellMetrics.shellGap
        )
        self.toggleLeadingConstraint = toggleLeadingConstraint

        let toggleVerticalConstraint: NSLayoutConstraint
        if trafficLightAnchor.y > 0 {
            toggleVerticalConstraint = sidebarToggleButton.centerYAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -trafficLightAnchor.y
            )
        } else {
            toggleVerticalConstraint = sidebarToggleButton.centerYAnchor.constraint(
                equalTo: windowChromeView.centerYAnchor
            )
        }
        self.toggleTopConstraint = toggleVerticalConstraint

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

            toggleLeadingConstraint,
            toggleVerticalConstraint,
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: SidebarToggleButton.buttonSize),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: SidebarToggleButton.buttonSize),
        ])

        renderCoordinator.bind(to: WorkspaceRenderCoordinator.ViewBindings(
            sidebarView: sidebarView,
            windowChromeView: windowChromeView,
            appCanvasView: appCanvasView,
            paneBorderContextOverlayView: paneBorderContextOverlayView
        ))
        renderCoordinator.themeProvider = { [weak self] in
            self?.currentTheme ?? ZenttyTheme.fallback(for: nil)
        }
        renderCoordinator.leadingInsetProvider = { [weak self] sidebarWidth in
            self?.sidebarMotionCoordinator.effectiveLeadingInset(sidebarWidth: sidebarWidth) ?? 0
        }
        renderCoordinator.sidebarWidthProvider = { [weak self] in
            self?.sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
        }
        renderCoordinator.windowStateProvider = { [weak self] in
            guard let self else {
                return (isVisible: false, isKeyWindow: false)
            }
            return (
                isVisible: self.view.window?.isVisible ?? false,
                isKeyWindow: self.view.window?.isKeyWindow ?? false
            )
        }
        renderCoordinator.onNeedsSidebarSync = { [weak self] in
            self?.syncSidebarVisibilityControls(animated: false)
        }
        renderCoordinator.startObserving()

        appCanvasView.paneStripView.onFocusSettled = { [weak self] paneID in
            self?.workspaceStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneSelected = { [weak self] paneID in
            self?.workspaceStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneCloseRequested = { [weak self] paneID in
            self?.workspaceStore.closePane(id: paneID)
        }
        appCanvasView.paneStripView.onDividerInteraction = { [weak self] divider in
            self?.workspaceStore.markDividerInteraction(divider)
        }
        appCanvasView.paneStripView.onDividerResizeRequested = { [weak self] target, delta in
            guard let self else {
                return
            }
            self.workspaceStore.resize(
                target,
                delta: delta,
                availableSize: self.appCanvasView.bounds.size,
                minimumSizeByPaneID: self.paneMinimumSizesByPaneID()
            )
        }
        appCanvasView.paneStripView.onDividerEqualizeRequested = { [weak self] divider in
            guard let self else {
                return
            }
            self.workspaceStore.equalizeDivider(divider, availableSize: self.appCanvasView.bounds.size)
        }
        appCanvasView.paneStripView.onPaneStripStateRestoreRequested = { [weak self] state in
            self?.workspaceStore.restorePaneLayout(state)
        }
        sidebarView.onWorkspaceSelected = { [weak self] id in
            self?.workspaceStore.selectWorkspace(id: id)
        }
        sidebarView.onNewWorkspaceRequested = { [weak self] in
            self?.handle(.newWorkspace)
        }
        sidebarView.onResized = { [weak self] width in
            self?.handleSidebarWidthChange(width)
        }
        sidebarView.onPointerEntered = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.sidebarEntered)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarView.onPointerExited = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.sidebarExited)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarHoverRailView.onPointerEntered = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.hoverRailEntered)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarHoverRailView.onPointerExited = { [weak self] in
            self?.sidebarMotionCoordinator.handle(.hoverRailExited)
            self?.syncSidebarVisibilityControls(animated: true)
        }
        sidebarToggleButton.target = self
        sidebarToggleButton.action = #selector(handleToggleSidebar)
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
        updateToggleButtonConstraints()
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        updatePaneLayoutContextIfNeeded(force: true)
        updatePaneViewportHeight()
        installStaleAgentSweepTimer()
        themeCoordinator.refreshTheme(for: NSApp.effectiveAppearance, animated: false)
        renderCoordinator.render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncSidebarWidthToAvailableWidth(persist: false)
        updatePaneLayoutContextIfNeeded()
        updatePaneViewportHeight()
        renderCoordinator.renderBorderOverlay()
    }

    func activateWindowBindingsIfNeeded() {
        installKeyboardMonitorIfNeeded()
        installWindowObserversIfNeeded()
        syncSidebarWidthToAvailableWidth(persist: false)
        renderCoordinator.updateSurfaceActivities()
        appCanvasView.focusCurrentPaneIfNeeded()
    }

    func updateTrafficLightAnchor(_ anchor: NSPoint) {
        trafficLightAnchor = anchor
        updateToggleButtonConstraints()
    }

    private func updateToggleButtonConstraints() {
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        if trafficLightAnchor.y > 0 {
            toggleTopConstraint?.isActive = false
            toggleTopConstraint = sidebarToggleButton.centerYAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -trafficLightAnchor.y
            )
            toggleTopConstraint?.isActive = true
        }
    }

    @objc
    private func handleToggleSidebar() {
        sidebarMotionCoordinator.handle(.togglePressed)
        syncSidebarVisibilityControls(animated: true)
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
            handlePaneCommand(command)
        }
    }

    private func handlePaneCommand(_ command: PaneCommand) {
        switch command {
        case .resizeLeft:
            workspaceStore.resizeFocusedPane(
                in: .horizontal,
                delta: -keyboardResizeStep(for: .horizontal),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .resizeRight:
            workspaceStore.resizeFocusedPane(
                in: .horizontal,
                delta: keyboardResizeStep(for: .horizontal),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .resizeUp:
            workspaceStore.resizeFocusedPane(
                in: .vertical,
                delta: keyboardResizeStep(for: .vertical),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .resizeDown:
            workspaceStore.resizeFocusedPane(
                in: .vertical,
                delta: -keyboardResizeStep(for: .vertical),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .resetLayout:
            workspaceStore.resetActiveWorkspaceLayout()
        default:
            workspaceStore.send(command)
        }
    }

    private func keyboardResizeStep(for axis: PaneResizeAxis) -> CGFloat {
        let minimumSizesByPaneID = paneMinimumSizesByPaneID()
        guard let focusedPaneID = workspaceStore.activeWorkspace?.paneStripState.focusedPaneID,
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

    private func paneMinimumSizesByPaneID() -> [PaneID: PaneMinimumSize] {
        guard let workspace = workspaceStore.activeWorkspace else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: workspace.paneStripState.panes.map { pane in
            let runtime = runtimeRegistry.runtime(for: pane)
            let minimumWidth = runtime.cellWidth > 0
                ? max(PaneMinimumSize.fallback.width, runtime.cellWidth * PaneResize.minimumColumns)
                : PaneMinimumSize.fallback.width
            let minimumHeight = runtime.cellHeight > 0
                ? max(PaneMinimumSize.fallback.height, runtime.cellHeight * PaneResize.minimumRows)
                : PaneMinimumSize.fallback.height
            return (pane.id, PaneMinimumSize(width: minimumWidth, height: minimumHeight))
        })
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
        syncSidebarWidthToAvailableWidth(persist: false)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.updateSurfaceActivities()
    }

    private func installStaleAgentSweepTimer() {
        staleAgentSweepTimer?.invalidate()
        staleAgentSweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.workspaceStore.clearStaleAgentSessions()
            }
        }
    }

    private func applyThemeToViews(_ theme: ZenttyTheme, animated: Bool) {
        apply(theme: theme, animated: animated)
        sidebarView.apply(theme: theme, animated: animated)
        sidebarToggleButton.configure(
            theme: theme,
            isActive: sidebarMotionCoordinator.mode == .pinnedOpen,
            animated: animated
        )
        windowChromeView.apply(theme: theme, animated: animated)
        appCanvasView.apply(theme: theme, animated: animated)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        renderCoordinator.renderBorderOverlay()
    }

    private func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.view.layer?.backgroundColor = theme.windowBackground.cgColor
            self.view.layer?.borderColor = theme.topChromeBorder.cgColor
        }
    }

    private func handleSidebarWidthChange(_ width: CGFloat) {
        sidebarMotionCoordinator.setSidebarWidth(width, availableWidth: resolvedSidebarAvailableWidth(), persist: true)
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
    }

    private func syncSidebarVisibilityControls(animated: Bool) {
        sidebarView.setResizeEnabled(sidebarMotionCoordinator.showsResizeHandle)
        sidebarToggleButton.configure(
            theme: currentTheme,
            isActive: sidebarMotionCoordinator.mode == .pinnedOpen,
            animated: animated
        )
    }

    private func applySidebarMotionState(
        _ motionState: SidebarMotionState,
        animated: Bool,
        reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        let sidebarWidth = SidebarWidthPreference.clamped(
            sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth,
            availableWidth: resolvedSidebarAvailableWidth()
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
        workspaceStore.batchUpdate { [self] in
            updatePaneLayoutContextIfNeeded(force: true, leadingVisibleInsetOverride: reservedInset)
        }
        let needsCanvasTransition = abs(previousLeadingInset - reservedInset) > 0.001
            || previousWorkspaceState != workspaceStore.state
            || previousLayoutContext != currentPaneLayoutContext
        windowChromeView.leadingVisibleInset = reservedInset
        if needsCanvasTransition {
            renderCoordinator.renderCanvas(
                leadingVisibleInsetOverride: reservedInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        } else {
            appCanvasView.leadingVisibleInset = reservedInset
        }

        let sidebarTrailingEdge = leadingConstant + sidebarWidth
        let toggleTarget = max(
            trafficLightAnchor.x + SidebarToggleButton.spacingFromTrafficLights,
            sidebarTrailingEdge + ShellMetrics.shellGap
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timingFunction
                context.allowsImplicitAnimation = true
                self.sidebarLeadingConstraint?.animator().constant = leadingConstant
                self.toggleLeadingConstraint?.animator().constant = toggleTarget
                self.sidebarView.animator().alphaValue = motionState.revealFraction
                self.view.layoutSubtreeIfNeeded()
            }
        } else {
            sidebarLeadingConstraint?.constant = leadingConstant
            toggleLeadingConstraint?.constant = toggleTarget
            sidebarView.alphaValue = motionState.revealFraction
            view.layoutSubtreeIfNeeded()
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
        sidebarToggleButton.frame.minX
    }

    var sidebarToggleMidY: CGFloat {
        sidebarToggleButton.frame.midY
    }

    var isSidebarToggleActive: Bool {
        sidebarToggleButton.isActive
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
        renderCoordinator.render()
    }

    func focusPaneDirectly(_ paneID: PaneID) {
        workspaceStore.focusPane(id: paneID)
        renderCoordinator.render()
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarMotionCoordinator.setSidebarWidth(width, availableWidth: resolvedSidebarAvailableWidth(), persist: false)
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
    }
    #endif

    private func resolvedSidebarAvailableWidth() -> CGFloat? {
        view.window?.screen?.visibleFrame.width
    }

    private func syncSidebarWidthToAvailableWidth(persist: Bool) {
        let previousWidth = sidebarMotionCoordinator.currentSidebarWidth
        sidebarMotionCoordinator.setSidebarWidth(
            previousWidth,
            availableWidth: resolvedSidebarAvailableWidth(),
            persist: persist
        )
        guard abs(sidebarMotionCoordinator.currentSidebarWidth - previousWidth) > 0.001 else {
            return
        }

        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
    }

    private func updateCanvasLeadingInset(_ leadingVisibleInset: CGFloat? = nil) {
        let leadingVisibleInset = leadingVisibleInset
            ?? (sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth) + ShellMetrics.shellGap
        appCanvasView.leadingVisibleInset = leadingVisibleInset
        windowChromeView.leadingVisibleInset = leadingVisibleInset
    }

    func updatePaneLayoutPreferences(_ preferences: PaneLayoutPreferences) {
        paneLayoutPreferences = preferences
        PaneLayoutPreferenceStore.persist(preferences.laptopPreset, for: .laptop, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(preferences.largeDisplayPreset, for: .largeDisplay, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(preferences.ultrawidePreset, for: .ultrawide, in: paneLayoutDefaults)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.render()
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
