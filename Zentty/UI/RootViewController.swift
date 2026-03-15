import AppKit

final class RootViewController: NSViewController {
    private let paneStripStore = PaneStripStore()
    private let sidebarView = SidebarView()
    private let runtimeRegistry = PaneRuntimeRegistry()
    private let themeResolver = GhosttyThemeResolver()
    private let themeWatcher = GhosttyThemeWatcher()
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private var hasInstalledKeyMonitor = false
    private var hasInstalledWindowObservers = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    private enum Layout {
        static let outerInset: CGFloat = 6
        static let sidebarWidth: CGFloat = 84
        static let canvasGap: CGFloat = 8
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

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        appCanvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarView)
        view.addSubview(appCanvasView)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.outerInset),
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.outerInset),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.outerInset),
            sidebarView.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),

            appCanvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.outerInset),
            appCanvasView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: Layout.canvasGap),
            appCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.outerInset),
            appCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.outerInset),
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
        runtimeRegistry.onMetadataDidChange = { [weak self] paneID, metadata in
            guard let self else {
                return
            }

            self.paneStripStore.updateMetadata(id: paneID, metadata: metadata)
            if self.paneStripStore.activeWorkspace?.paneStripState.panes.contains(where: { $0.id == paneID }) == true {
                self.appCanvasView.updateMetadata(for: paneID, metadata: metadata)
            }
        }
        themeWatcher.onChange = { [weak self] in
            self?.refreshTheme(animated: true)
        }
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
            workspaces: paneStripStore.workspaces,
            activeWorkspaceID: paneStripStore.activeWorkspaceID,
            theme: currentTheme
        )

        guard let workspace = paneStripStore.activeWorkspace else {
            return
        }

        appCanvasView.render(
            workspaceName: workspace.title,
            state: workspace.paneStripState,
            metadataByPaneID: workspace.metadataByPaneID,
            theme: currentTheme
        )
        updateRuntimeSurfaceActivities()
    }

    private func refreshTheme(animated: Bool) {
        let resolution = themeResolver.resolve(for: view.effectiveAppearance)
        let theme = resolution.map { ZenttyTheme(resolvedTheme: $0.theme) }
            ?? ZenttyTheme.fallback(for: view.effectiveAppearance)
        let didChange = theme != currentTheme
        currentTheme = theme
        apply(theme: theme, animated: animated && didChange)
        sidebarView.apply(theme: theme, animated: animated && didChange)
        appCanvasView.apply(theme: theme, animated: animated && didChange)
        themeWatcher.watch(urls: resolution?.watchedURLs ?? [themeResolver.configURL])
    }

    private func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.view.layer?.backgroundColor = theme.windowBackground.cgColor
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
