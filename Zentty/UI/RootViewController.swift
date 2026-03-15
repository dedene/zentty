import AppKit

final class RootViewController: NSViewController {
    private let paneStripStore = PaneStripStore()
    private let sidebarWidthDefaults: UserDefaults
    private let sidebarView = SidebarView()
    private let runtimeRegistry = PaneRuntimeRegistry()
    private let themeResolver = GhosttyThemeResolver()
    private let themeWatcher = GhosttyThemeWatcher()
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let windowChromeView = WindowChromeView()
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var sidebarWidthConstraint: NSLayoutConstraint?

    init(sidebarWidthDefaults: UserDefaults = .standard) {
        self.sidebarWidthDefaults = sidebarWidthDefaults
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
            self?.paneStripStore.createWorkspace()
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
        themeWatcher.onChange = { [weak self] in
            self?.refreshTheme(animated: true)
        }
        updateCanvasLeadingInset()
        refreshTheme(animated: false)
        renderCurrentWorkspace()
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
                  let command = KeyboardShortcutResolver.resolve(shortcut) else {
                return event
            }

            self.paneStripStore.send(command)
            return nil
        }
        hasInstalledKeyMonitor = true
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
        updateRuntimeSurfaceActivities()
    }

    private func renderCurrentWorkspace() {
        runtimeRegistry.synchronize(with: paneStripStore.workspaces)
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
        windowChromeView.render(workspaceName: workspace.title, state: workspace.paneStripState, metadata: metadata)
        appCanvasView.render(workspaceName: workspace.title, state: workspace.paneStripState, metadataByPaneID: workspace.metadataByPaneID, theme: currentTheme)
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
            self.view.layer?.backgroundColor = theme.startupSurface.cgColor
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

        if persist {
            SidebarWidthPreference.persist(clampedWidth, in: sidebarWidthDefaults)
        }
    }

    var sidebarWidthForTesting: CGFloat {
        sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
    }

    private func updateCanvasLeadingInset() {
        appCanvasView.leadingVisibleInset = (sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth) + ShellMetrics.shellGap
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
