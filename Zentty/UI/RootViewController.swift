import AppKit

final class RootViewController: NSViewController {
    private let paneStripStore: PaneStripStore
    private let sidebarWidthDefaults: UserDefaults
    private let paneLayoutDefaults: UserDefaults
    private let sidebarView = SidebarView()
    private let runtimeRegistry = PaneRuntimeRegistry()
    private let agentStatusCenter = AgentStatusCenter()
    private let prArtifactResolver = PRArtifactResolver()
    private let themeResolver = GhosttyThemeResolver()
    private let themeWatcher = GhosttyThemeWatcher()
    private let attentionNotificationCoordinator = WorkspaceAttentionNotificationCoordinator()
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let windowChromeView = WindowChromeView()
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var paneLayoutPreferences: PaneLayoutPreferences
    private var currentPaneLayoutContext: PaneLayoutContext
    private var sidebarWidthConstraint: NSLayoutConstraint?

    init(
        sidebarWidthDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        initialLayoutContext: PaneLayoutContext = .fallback
    ) {
        self.sidebarWidthDefaults = sidebarWidthDefaults
        self.paneLayoutDefaults = paneLayoutDefaults
        self.paneLayoutPreferences = PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults)
        self.currentPaneLayoutContext = initialLayoutContext
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
        windowChromeView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appCanvasView)
        view.addSubview(windowChromeView)
        view.addSubview(sidebarView)

        let sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: SidebarWidthPreference.restoredWidth(from: sidebarWidthDefaults)
        )
        self.sidebarWidthConstraint = sidebarWidthConstraint

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ShellMetrics.outerInset),
            sidebarWidthConstraint,

            appCanvasView.topAnchor.constraint(equalTo: windowChromeView.bottomAnchor),
            appCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            appCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ShellMetrics.outerInset),
            appCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ShellMetrics.outerInset),

            windowChromeView.topAnchor.constraint(equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ShellMetrics.outerInset),
            windowChromeView.heightAnchor.constraint(equalToConstant: WindowChromeView.preferredHeight),
        ])

        paneStripStore.onChange = { [weak self] _ in
            self?.renderCurrentWorkspace()
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
        sidebarView.onSelectWorkspace = { [weak self] workspaceID in
            self?.paneStripStore.selectWorkspace(id: workspaceID)
        }
        sidebarView.onCreateWorkspace = { [weak self] in
            self?.handle(.newWorkspace)
        }
        sidebarView.onResizeWidth = { [weak self] width in
            self?.setSidebarWidth(width, persist: true)
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
        updateCanvasLeadingInset()
        updatePaneLayoutContextIfNeeded(force: true)
        refreshTheme(animated: false)
        renderCurrentWorkspace()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePaneLayoutContextIfNeeded()
    }

    func activateWindowBindingsIfNeeded() {
        installKeyboardMonitorIfNeeded()
        installWindowObserversIfNeeded()
        updateRuntimeSurfaceActivities()
        appCanvasView.focusCurrentPaneIfNeeded()
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
        switch action {
        case .newWorkspace:
            paneStripStore.createWorkspace()
        case .pane(let command):
            paneStripStore.send(command)
        }
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
        prArtifactResolver.refresh(for: paneStripStore.workspaces) { [weak self] paneID, artifact in
            self?.paneStripStore.updateInferredArtifact(paneID: paneID, artifact: artifact)
        }
        sidebarView.render(
            summaries: WorkspaceSidebarSummaryBuilder.summaries(
                for: paneStripStore.workspaces,
                activeWorkspaceID: paneStripStore.activeWorkspaceID
            ),
            theme: currentTheme
        )

        guard let workspace = paneStripStore.activeWorkspace else {
            return
        }

        let metadata = workspace.paneStripState.focusedPaneID.flatMap { workspace.metadataByPaneID[$0] }
        windowChromeView.render(
            workspaceName: workspace.title,
            state: workspace.paneStripState,
            metadata: metadata,
            attention: WorkspaceAttentionSummaryBuilder.summary(for: workspace)
        )
        appCanvasView.render(workspaceName: workspace.title, state: workspace.paneStripState, metadataByPaneID: workspace.metadataByPaneID, theme: currentTheme)
        attentionNotificationCoordinator.update(
            workspaces: paneStripStore.workspaces,
            activeWorkspaceID: paneStripStore.activeWorkspaceID,
            windowIsKey: view.window?.isKeyWindow ?? false
        )
        updateRuntimeSurfaceActivities()
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
        windowChromeView.apply(theme: theme, animated: animated && didChange)
        appCanvasView.apply(theme: theme, animated: animated && didChange)
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
        updateCanvasLeadingInset()
        view.layoutSubtreeIfNeeded()
        updatePaneLayoutContextIfNeeded(force: true)

        if persist {
            SidebarWidthPreference.persist(clampedWidth, in: sidebarWidthDefaults)
        }
    }

    var sidebarWidthForTesting: CGFloat {
        sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
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

    private func updateCanvasLeadingInset() {
        appCanvasView.leadingVisibleInset = (sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth) + ShellMetrics.shellGap
    }

    func updatePaneLayoutPreferences(_ preferences: PaneLayoutPreferences) {
        paneLayoutPreferences = preferences
        PaneLayoutPreferenceStore.persist(preferences.laptopPreset, for: .laptop, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(preferences.largeDisplayPreset, for: .largeDisplay, in: paneLayoutDefaults)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCurrentWorkspace()
    }

    private func updatePaneLayoutContextIfNeeded(force: Bool = false) {
        let resolvedContext = resolveCurrentPaneLayoutContext()
        guard force || resolvedContext != currentPaneLayoutContext else {
            return
        }

        currentPaneLayoutContext = resolvedContext
        paneStripStore.updateLayoutContext(resolvedContext)
    }

    private func resolveCurrentPaneLayoutContext() -> PaneLayoutContext {
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
            leadingVisibleInset: appCanvasView.leadingVisibleInset
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
