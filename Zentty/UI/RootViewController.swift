import AppKit
import QuartzCore
import os

@MainActor
final class RootViewController: NSViewController {
    private final class LocalEventMonitor {
        private let token: Any

        init(
            matching mask: NSEvent.EventTypeMask,
            handler: @escaping (NSEvent) -> NSEvent?
        ) {
            token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) as Any
        }

        deinit {
            NSEvent.removeMonitor(token)
        }
    }

    private final class NotificationObserverBag {
        private let center: NotificationCenter
        private var tokens: [NSObjectProtocol] = []

        init(center: NotificationCenter = .default) {
            self.center = center
        }

        func addObserver(
            forName name: Notification.Name,
            object: AnyObject?,
            using block: @escaping @Sendable (Notification) -> Void
        ) {
            tokens.append(
                center.addObserver(forName: name, object: object, queue: .main, using: block)
            )
        }

        deinit {
            tokens.forEach(center.removeObserver)
        }
    }

    private enum SidebarLayout {
        static let hoverRailWidth: CGFloat = 8
        static let defaultTrafficLightAnchor = NSPoint(
            x: ChromeGeometry.trafficLightLeadingInset + 48, y: 0)
    }

    private enum PaneResize {
        static let minimumColumns: CGFloat = 5
        static let minimumRows: CGFloat = 5
    }

    private let worklaneStore: WorklaneStore
    private let windowID: WindowID
    private let configStore: AppConfigStore
    private let appUpdateStateStore: AppUpdateStateStore
    private let openWithService: OpenWithServing
    private let sidebarView = SidebarView()
    private let sidebarHoverRailView = SidebarHoverRailView()
    private let sidebarToggleButton = SidebarToggleButton()
    private let globalSearchHUDView = WindowSearchHUDView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let agentStatusCenter = AgentStatusCenter()
    private let sidebarMotionCoordinator: SidebarMotionCoordinator
    private let themeCoordinator: ThemeCoordinator
    private let notificationCoordinator: NotificationChromeCoordinator
    private let renderCoordinator: WorklaneRenderCoordinator
    private var staleAgentSweepTimer: Timer?
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let dragOverlayView: HitTransparentView = {
        let view = HitTransparentView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }()
    private let windowChromeView = WindowChromeView()
    private var keyMonitor: LocalEventMonitor?
    private var windowObserverBag: NotificationObserverBag?
    private var paneLayoutPreferences: PaneLayoutPreferences
    private var shortcutManager: ShortcutManager
    private var lastAppliedAppearanceSettings: AppConfig.Appearance
    private var currentPaneLayoutContext: PaneLayoutContext
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var toggleLeadingConstraint: NSLayoutConstraint?
    private var toggleTopConstraint: NSLayoutConstraint?
    private var trafficLightAnchor = SidebarLayout.defaultTrafficLightAnchor
    private var pathCopiedToastView: PathCopiedToastView?
    private let paneNavigationButtons = PaneNavigationButtons()
    private let paneLayoutMenuCoordinator: PaneLayoutMenuCoordinator
    private lazy var globalSearchCoordinator = GlobalSearchCoordinator(
        orderedTargetsProvider: { [weak self] in
            self?.worklaneStore.worklanes.flatMap { worklane in
                worklane.paneStripState.panes.map { pane in
                    GlobalSearchTarget(worklaneID: worklane.id, paneID: pane.id)
                }
            } ?? []
        },
        runtimeProvider: { [weak self] paneID in
            self?.runtimeRegistry.runtime(for: paneID)
        },
        navigateToTarget: { [weak self] worklaneID, paneID, completion in
            guard let self else {
                return
            }

            self.navigateToPane(worklaneID: worklaneID, paneID: paneID)
            self.view.layoutSubtreeIfNeeded()
            self.runtimeRegistry.runtime(for: paneID)?.forceViewportSync()

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.view.layoutSubtreeIfNeeded()
                self.runtimeRegistry.runtime(for: paneID)?.forceViewportSync()
                completion()
                self.focusGlobalSearchField(selectAll: false)
            }
        },
        endAllLocalSearches: { [weak self] in
            self?.endAllLocalSearches()
        }
    )
    private var currentTheme: ZenttyTheme { themeCoordinator.currentTheme }
    private let commandPaletteController = CommandPaletteController()
    private var appUpdateObserverID: UUID?
    private var isUpdateAvailable = false
    var onWindowChromeNeedsUpdate: (() -> Void)?
    var onOpenWithPrimaryRequested: (() -> Void)?
    var onOpenWithMenuRequested: (() -> Void)?
    var onShowSettingsRequested: (() -> Void)?
    var onCheckForUpdatesRequested: (() -> Void)?
    var onCloseWindowRequested: (() -> Void)?
    var onNavigateToNotificationRequested: ((WindowID, WorklaneID, PaneID) -> Void)?
    var onWorkspaceStateDidChange: (() -> Void)?

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        configStore: AppConfigStore,
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        openWithService: OpenWithServing = OpenWithService(),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        notificationStore: NotificationStore = NotificationStore(),
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver(),
        initialLayoutContext: PaneLayoutContext = .fallback,
        initialWorkspaceState: WindowWorkspaceState? = nil
    ) {
        self.windowID = windowID
        self.runtimeRegistry = runtimeRegistry
        self.configStore = configStore
        self.appUpdateStateStore = appUpdateStateStore
        self.openWithService = openWithService
        self.paneLayoutPreferences = configStore.current.paneLayout
        self.shortcutManager = ShortcutManager(shortcuts: configStore.current.shortcuts)
        self.lastAppliedAppearanceSettings = configStore.current.appearance
        self.currentPaneLayoutContext = initialLayoutContext
        self.isUpdateAvailable = appUpdateStateStore.current.isUpdateAvailable
        self.sidebarMotionCoordinator = SidebarMotionCoordinator(
            configStore: configStore
        )
        self.themeCoordinator = ThemeCoordinator(
            themeResolver: GhosttyThemeResolver(
                configEnvironment: GhosttyConfigEnvironment(appConfigProvider: {
                    [weak configStore] in
                    configStore?.current ?? .default
                })
            )
        )
        self.notificationCoordinator = NotificationChromeCoordinator(store: notificationStore)
        self.paneLayoutMenuCoordinator = PaneLayoutMenuCoordinator(
            shortcutManager: shortcutManager
        )
        self.worklaneStore = WorklaneStore(
            windowID: windowID,
            worklanes: initialWorkspaceState?.worklanes ?? [],
            layoutContext: initialLayoutContext,
            activeWorklaneID: initialWorkspaceState?.activeWorklaneID,
            gitContextResolver: gitContextResolver
        )
        self.renderCoordinator = WorklaneRenderCoordinator(
            windowID: windowID,
            worklaneStore: worklaneStore,
            runtimeRegistry: runtimeRegistry,
            notificationStore: notificationStore,
            configStore: configStore,
            reviewStateResolver: reviewStateResolver
        )
        super.init(nibName: nil, bundle: nil)
        appUpdateObserverID = appUpdateStateStore.addObserver { [weak self] state in
            self?.handleAppUpdateAvailabilityChange(state.isUpdateAvailable)
        }
        configStore.onChange = { [weak self] config in
            DispatchQueue.main.async {
                self?.applyPersistedConfig(config)
            }
        }
        preloadOpenWithIcons()
    }

    convenience init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        configStore: AppConfigStore? = nil,
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        openWithService: OpenWithServing = OpenWithService(),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        notificationStore: NotificationStore = NotificationStore(),
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        initialLayoutContext: PaneLayoutContext = .fallback,
        initialWorkspaceState: WindowWorkspaceState? = nil
    ) {
        self.init(
            windowID: windowID,
            configStore: configStore
                ?? AppConfigStore(
                    fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.RootViewController"),
                    sidebarWidthDefaults: sidebarWidthDefaults,
                    sidebarVisibilityDefaults: sidebarVisibilityDefaults,
                    paneLayoutDefaults: paneLayoutDefaults
                ),
            appUpdateStateStore: appUpdateStateStore,
            openWithService: openWithService,
            runtimeRegistry: runtimeRegistry,
            notificationStore: notificationStore,
            reviewStateResolver: reviewStateResolver,
            gitContextResolver: gitContextResolver,
            initialLayoutContext: initialLayoutContext,
            initialWorkspaceState: initialWorkspaceState
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            invalidateStaleAgentSweepTimer()
            if let appUpdateObserverID {
                appUpdateStateStore.removeObserver(appUpdateObserverID)
            }
        }
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
        view.layer?.borderWidth = 0
        apply(theme: currentTheme, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSubviews()
        setupConstraints()
        setupRenderCoordinator()
        setupWorklaneStoreObserver()
        setupToolbarButtons()
        setupCanvasCallbacks()
        setupSidebarCallbacks()
        setupCoordinatorsAndServices()
        applyInitialState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCleanCopyDidModifyPasteboard),
            name: .cleanCopyDidModifyPasteboard,
            object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let window = view.window {
            window.backgroundColor = currentTheme.windowBackground
            window.invalidateShadow()
            LibghosttyRuntime.shared.applyBackgroundBlur(to: window)
        }
    }

    // MARK: - View Setup

    private func setupSubviews() {
        appCanvasView.translatesAutoresizingMaskIntoConstraints = false
        windowChromeView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarHoverRailView.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false
        paneNavigationButtons.translatesAutoresizingMaskIntoConstraints = false
        paneLayoutMenuCoordinator.menuButton.translatesAutoresizingMaskIntoConstraints = false
        notificationCoordinator.bellButton.translatesAutoresizingMaskIntoConstraints = false
        globalSearchHUDView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appCanvasView)
        view.addSubview(globalSearchHUDView)
        view.addSubview(windowChromeView)
        view.addSubview(sidebarHoverRailView)
        view.addSubview(sidebarView)
        view.addSubview(dragOverlayView)
        view.addSubview(sidebarToggleButton)
        view.addSubview(paneLayoutMenuCoordinator.menuButton)
        view.addSubview(paneNavigationButtons)
        view.addSubview(notificationCoordinator.bellButton)
        sidebarView.setUpdateAvailable(isUpdateAvailable)
    }

    private func setupConstraints() {
        let sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarMotionCoordinator.currentSidebarWidth
        )
        let sidebarLeadingConstraint = sidebarView.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: ShellMetrics.outerInset
        )
        self.sidebarWidthConstraint = sidebarWidthConstraint
        self.sidebarLeadingConstraint = sidebarLeadingConstraint

        let initialSidebarTrailing =
            ShellMetrics.outerInset + sidebarMotionCoordinator.currentSidebarWidth
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
            sidebarView.topAnchor.constraint(
                equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            sidebarLeadingConstraint,
            sidebarView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -ShellMetrics.outerInset),
            sidebarWidthConstraint,

            appCanvasView.topAnchor.constraint(equalTo: windowChromeView.bottomAnchor),
            appCanvasView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            appCanvasView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -ShellMetrics.canvasOuterInset),
            appCanvasView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -ShellMetrics.canvasOuterInset),

            globalSearchHUDView.topAnchor.constraint(
                equalTo: appCanvasView.topAnchor, constant: 14),
            globalSearchHUDView.trailingAnchor.constraint(
                equalTo: appCanvasView.trailingAnchor, constant: -14),

            // Drag overlay matches canvas frame so coordinate conversion is identity
            dragOverlayView.topAnchor.constraint(equalTo: appCanvasView.topAnchor),
            dragOverlayView.leadingAnchor.constraint(equalTo: appCanvasView.leadingAnchor),
            dragOverlayView.trailingAnchor.constraint(equalTo: appCanvasView.trailingAnchor),
            dragOverlayView.bottomAnchor.constraint(equalTo: appCanvasView.bottomAnchor),

            windowChromeView.topAnchor.constraint(
                equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: ShellMetrics.outerInset),
            windowChromeView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -ShellMetrics.outerInset),
            windowChromeView.heightAnchor.constraint(
                equalToConstant: WindowChromeView.preferredHeight),

            sidebarHoverRailView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarHoverRailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarHoverRailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarHoverRailView.widthAnchor.constraint(
                equalToConstant: SidebarLayout.hoverRailWidth),

            toggleLeadingConstraint,
            toggleVerticalConstraint,
            sidebarToggleButton.widthAnchor.constraint(
                equalToConstant: SidebarToggleButton.buttonSize),
            sidebarToggleButton.heightAnchor.constraint(
                equalToConstant: SidebarToggleButton.buttonSize),

            paneLayoutMenuCoordinator.menuButton.leadingAnchor.constraint(
                equalTo: sidebarToggleButton.trailingAnchor,
                constant: 4
            ),
            paneLayoutMenuCoordinator.menuButton.centerYAnchor.constraint(
                equalTo: sidebarToggleButton.centerYAnchor
            ),
            paneLayoutMenuCoordinator.menuButton.widthAnchor.constraint(
                equalToConstant: PaneLayoutMenuButton.buttonSize
            ),
            paneLayoutMenuCoordinator.menuButton.heightAnchor.constraint(
                equalToConstant: PaneLayoutMenuButton.buttonSize
            ),

            paneNavigationButtons.leadingAnchor.constraint(
                equalTo: paneLayoutMenuCoordinator.menuButton.trailingAnchor, constant: 4),
            paneNavigationButtons.centerYAnchor.constraint(
                equalTo: sidebarToggleButton.centerYAnchor),
            paneNavigationButtons.widthAnchor.constraint(
                equalToConstant: PaneNavigationButtons.totalWidth),
            paneNavigationButtons.heightAnchor.constraint(
                equalToConstant: PaneNavigationButtons.buttonSize),

            notificationCoordinator.bellButton.leadingAnchor.constraint(
                equalTo: paneNavigationButtons.trailingAnchor, constant: 8),
            notificationCoordinator.bellButton.centerYAnchor.constraint(
                equalTo: sidebarToggleButton.centerYAnchor),
            notificationCoordinator.bellButton.widthAnchor.constraint(
                equalToConstant: NotificationBellButton.buttonSize),
            notificationCoordinator.bellButton.heightAnchor.constraint(
                equalToConstant: NotificationBellButton.buttonSize),
        ])
    }

    private func setupRenderCoordinator() {
        renderCoordinator.bind(
            to: WorklaneRenderCoordinator.ViewBindings(
                sidebarView: sidebarView,
                windowChromeView: windowChromeView,
                appCanvasView: appCanvasView
            ))
        renderCoordinator.environment = self
        renderCoordinator.startObserving()
    }

    private func setupWorklaneStoreObserver() {
        _ = worklaneStore.subscribe { [weak self] change in
            guard let self else {
                return
            }

            switch change {
            case .paneStructure, .worklaneListChanged:
                if self.isGlobalSearchSessionActive {
                    self.globalSearchCoordinator.end()
                } else {
                    self.globalSearchCoordinator.reconcileTargets(with: self.worklaneStore.worklanes)
                }
                self.updateOpenWithChromeState()
                self.updatePaneNavigationButtonState()
            case .focusChanged, .activeWorklaneChanged:
                self.globalSearchCoordinator.reconcileTargets(with: self.worklaneStore.worklanes)
                self.updateOpenWithChromeState()
                self.updatePaneNavigationButtonState()
            case .historyChanged:
                self.updatePaneNavigationButtonState()
            case .auxiliaryStateUpdated(_, _, let impacts) where impacts.contains(.openWith):
                self.updateOpenWithChromeState()
            default:
                break
            }

            switch change {
            case .historyChanged, .volatileAgentTitleUpdated:
                break
            default:
                self.onWorkspaceStateDidChange?()
            }
        }
    }

    private func setupToolbarButtons() {
        globalSearchHUDView.delegate = self
        paneNavigationButtons.onBack = { [weak self] in
            self?.worklaneStore.navigateBack()
        }
        paneNavigationButtons.onForward = { [weak self] in
            self?.worklaneStore.navigateForward()
        }
        paneNavigationButtons.update(canGoBack: false, canGoForward: false, theme: currentTheme)
        paneNavigationButtons.configure(theme: currentTheme, animated: false)

        paneLayoutMenuCoordinator.setup(
            target: self,
            buttonAction: #selector(handlePaneLayoutMenuAction),
            menuItemAction: #selector(handlePaneLayoutMenuItem(_:)),
            theme: currentTheme
        )
        paneLayoutMenuCoordinator.onAction = { [weak self] action in
            self?.handle(action)
        }

        notificationCoordinator.setup(parentView: view, theme: currentTheme)
        notificationCoordinator.onNavigateToNotification = { [weak self] notification in
            self?.navigateToNotification(notification)
        }

        appCanvasView.paneStripView.onPaneBorderContextClicked = { [weak self] paneID in
            self?.copyPath(forPaneID: paneID)
        }
    }

    private func setupCanvasCallbacks() {
        appCanvasView.paneStripView.onHostDrivenResizeRenderRequested = { [weak self] in
            self?.renderCoordinator.renderCanvas(animated: false)
        }
        appCanvasView.paneStripView.onFocusSettled = { [weak self] paneID in
            self?.appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
            self?.worklaneStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneSelected = { [weak self] paneID in
            self?.appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
            self?.worklaneStore.focusPane(id: paneID)
        }
        appCanvasView.paneStripView.onPaneCloseRequested = { [weak self] paneID in
            guard let self else { return }
            if self.configStore.current.confirmations.confirmBeforeClosingPane,
                let reason = self.worklaneStore.paneCloseConfirmationReason(paneID)
            {
                self.showClosePaneConfirmation(reason: reason) {
                    self.closePane(id: paneID)
                }
            } else {
                self.closePane(id: paneID)
            }
        }
        appCanvasView.paneStripView.onDividerInteraction = { [weak self] divider in
            self?.worklaneStore.markDividerInteraction(divider)
        }
        appCanvasView.paneStripView.onDividerResizeRequested = { [weak self] target, delta in
            guard let self else {
                return 0
            }
            return self.worklaneStore.resize(
                target,
                delta: delta,
                availableSize: self.appCanvasView.bounds.size,
                leadingVisibleInset: self.appCanvasView.leadingVisibleInset,
                minimumSizeByPaneID: self.paneMinimumSizesByPaneID()
            )
        }
        appCanvasView.paneStripView.onDividerEqualizeRequested = { [weak self] divider in
            guard let self else {
                return
            }
            self.worklaneStore.equalizeDivider(
                divider, availableSize: self.appCanvasView.bounds.size)
        }
        appCanvasView.paneStripView.onPaneStripStateRestoreRequested = { [weak self] state in
            self?.worklaneStore.restorePaneLayout(state)
        }
        appCanvasView.paneStripView.onPaneReorderRequested = {
            [weak self] paneID, columnIndex, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneAsColumn(
                    paneID: paneID,
                    toColumnIndex: columnIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.reorderPane(
                    paneID: paneID,
                    toColumnIndex: columnIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onPaneReorderInColumnRequested = {
            [weak self] paneID, columnID, paneIndex, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneInColumn(
                    paneID: paneID,
                    toColumnID: columnID,
                    atPaneIndex: paneIndex,
                    availableHeight: self.appCanvasView.bounds.height,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.reorderPane(
                    paneID: paneID,
                    toColumnID: columnID,
                    atPaneIndex: paneIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onPaneSplitDropRequested = {
            [weak self] paneID, targetID, axis, leading, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneSplitDrop(
                    paneID: paneID,
                    ontoTargetPaneID: targetID,
                    axis: axis,
                    leading: leading,
                    availableHeight: self.appCanvasView.bounds.height,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.splitDropPane(
                    paneID: paneID,
                    ontoTargetPaneID: targetID,
                    axis: axis,
                    leading: leading,
                    availableHeight: self.appCanvasView.bounds.height,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onPaneCrossWorklaneDropRequested = {
            [weak self] paneID, worklaneID, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneToWorklane(
                    paneID: paneID,
                    targetWorklaneID: worklaneID,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.transferPaneToWorklane(
                    paneID: paneID,
                    targetWorklaneID: worklaneID,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onPaneNewWorklaneDropRequested = {
            [weak self] paneID, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneToNewWorklane(
                    paneID: paneID,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.transferPaneToNewWorklane(
                    paneID: paneID,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onNewWorklanePlaceholderVisibilityChanged = {
            [weak self] visible in
            if visible {
                self?.sidebarView.showNewWorklanePlaceholder()
            } else {
                self?.sidebarView.hideNewWorklanePlaceholder()
            }
        }
        appCanvasView.paneStripView.onSidebarScrollRequested = { [weak self] delta in
            self?.sidebarView.adjustScrollOffset(by: delta)
        }
        appCanvasView.paneStripView.sidebarWorklaneFrameProvider = { [weak self] in
            guard let self else { return [] }
            return self.sidebarView.worklaneRowFrames(in: self.appCanvasView)
        }
        appCanvasView.paneStripView.onDragApproachingSidebarEdge = { [weak self] approaching in
            guard let self else { return }
            self.sidebarMotionCoordinator.handle(approaching ? .hoverRailEntered : .hoverRailExited)
            self.syncSidebarVisibilityControls(animated: true)
        }
        appCanvasView.paneStripView.onHoveredSidebarWorklaneChanged = { [weak self] worklaneID in
            self?.sidebarView.setHighlightedDropTargetWorklane(worklaneID)
        }
        appCanvasView.paneStripView.onDragActiveChanged = { [weak self] active in
            guard let self else { return }
            if !active {
                self.sidebarMotionCoordinator.handle(.hoverRailExited)
                self.syncSidebarVisibilityControls(animated: true)
            }
        }
        appCanvasView.paneStripView.activeWorklaneIDProvider = { [weak self] in
            self?.worklaneStore.activeWorklaneID
        }
        appCanvasView.paneStripView.sidebarBoundsProvider = { [weak self] in
            guard let self else { return .zero }
            return self.sidebarView.convert(
                self.sidebarView.bounds, to: self.appCanvasView.paneStripView)
        }
        appCanvasView.paneStripView.worklaneCountProvider = { [weak self] in
            self?.worklaneStore.worklanes.count ?? 1
        }
        appCanvasView.paneStripView.sidebarWidthProvider = { [weak self] in
            self?.sidebarMotionCoordinator.currentSidebarWidth ?? 0
        }
        appCanvasView.paneStripView.dragOverlayView = dragOverlayView
    }

    private func setupSidebarCallbacks() {
        sidebarView.onWorklaneSelected = { [weak self] id in
            self?.worklaneStore.selectWorklane(id: id)
        }
        sidebarView.onPaneSelected = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(
                worklaneID: worklaneID,
                paneID: paneID
            )
        }
        sidebarView.onCloseWorklaneRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.worklaneStore.closeActiveWorklane()
        }
        sidebarView.onClosePaneRequested = { [weak self] worklaneID, paneID in
            guard let self else { return }
            if self.configStore.current.confirmations.confirmBeforeClosingPane,
                let reason = self.worklaneStore.paneCloseConfirmationReason(paneID)
            {
                self.showClosePaneConfirmation(reason: reason) {
                    self.worklaneStore.selectWorklaneAndFocusPane(
                        worklaneID: worklaneID, paneID: paneID)
                    self.closePane(id: paneID)
                }
            } else {
                self.worklaneStore.selectWorklaneAndFocusPane(
                    worklaneID: worklaneID, paneID: paneID)
                self.closePane(id: paneID)
            }
        }
        sidebarView.onSplitHorizontalRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.worklaneStore.send(.splitHorizontally)
        }
        sidebarView.onSplitVerticalRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.worklaneStore.send(.splitVertically)
        }
        sidebarView.onNewWorklaneRequested = { [weak self] in
            self?.handle(.newWorklane)
        }
        sidebarView.onCheckForUpdatesRequested = { [weak self] in
            self?.onCheckForUpdatesRequested?()
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
    }

    private func setupCoordinatorsAndServices() {
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
        themeCoordinator.onTerminalConfigReload = { [weak self] in
            LibghosttyRuntime.shared.reloadConfig()
            self?.syncRunningOpenCodeThemesIfNeeded()
        }
        globalSearchCoordinator.onStateDidChange = { [weak self] state in
            self?.applyGlobalSearchState(state)
        }
        runtimeRegistry.onMetadataDidChange = { [weak self] paneID, metadata in
            guard let self else {
                return
            }

            self.worklaneStore.updateMetadata(id: paneID, metadata: metadata)
        }
        runtimeRegistry.onEventDidOccur = { [weak self] paneID, event in
            self?.handleTerminalEvent(paneID: paneID, event: event)
        }
        runtimeRegistry.onGlobalSearchDidChange = { [weak self] paneID, event in
            self?.globalSearchCoordinator.handleSearchEvent(for: paneID, event: event)
        }
        agentStatusCenter.onPayload = { [weak self] payload in
            self?.worklaneStore.applyAgentStatusPayload(payload)
        }
        agentStatusCenter.start()
    }

    private func syncRunningOpenCodeThemesIfNeeded() {
        let appConfig = configStore.current
        guard appConfig.appearance.syncOpenCodeThemeWithTerminal else {
            return
        }
        guard let runtimeDirectoryURL = AgentIPCServer.shared.currentRuntimeDirectoryURL() else {
            return
        }

        let panes = OpenCodeLiveThemeSync.runningPanes(in: worklaneStore.worklanes)
        guard !panes.isEmpty else {
            return
        }

        let configEnvironment = GhosttyConfigEnvironment(appConfigProvider: { [weak configStore] in
            configStore?.current ?? .default
        })

        do {
            _ = try OpenCodeLiveThemeSync.syncRunningPanes(
                panes,
                runtimeDirectoryURL: runtimeDirectoryURL,
                appConfig: appConfig,
                configEnvironment: configEnvironment,
                effectiveAppearance: view.effectiveAppearance,
                themeDirectories: GhosttyThemeLibrary.resolverThemeDirectories()
            )
        } catch {
            Logger(subsystem: "be.zenjoy.zentty", category: "RootViewController").error(
                "Failed to sync running OpenCode themes: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applyInitialState() {
        updateToggleButtonConstraints()
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        updatePaneLayoutContextIfNeeded(force: true)
        updatePaneViewportHeight()
        installStaleAgentSweepTimer()
        themeCoordinator.refreshTheme(for: NSApp.effectiveAppearance, animated: false)
        renderCoordinator.render()
        windowChromeView.onOpenWithPrimaryAction = { [weak self] in
            self?.onOpenWithPrimaryRequested?()
        }
        windowChromeView.onOpenWithMenuAction = { [weak self] in
            self?.onOpenWithMenuRequested?()
        }
        updateOpenWithChromeState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncSidebarWidthToAvailableWidth(persist: false)
        _ = updatePaneLayoutContextIfNeeded()
        updatePaneViewportHeight()
        updateWindowChromeLeadingControlsInset()
    }

    func activateWindowBindingsIfNeeded() {
        installKeyboardMonitorIfNeeded()
        installWindowObserversIfNeeded()
        if commandPaletteController.onExecute == nil {
            commandPaletteController.onExecute = { [weak self] action in
                self?.handle(action)
            }
            commandPaletteController.onOpenWith = { [weak self] stableID, workingDirectory in
                self?.openWithFromPalette(stableID: stableID, workingDirectory: workingDirectory)
            }
        }
        syncSidebarWidthToAvailableWidth(persist: false)
        renderCoordinator.updateSurfaceActivities()
        appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
        if globalSearchCoordinator.state.isHUDVisible {
            focusGlobalSearchField(selectAll: false)
        } else {
            appCanvasView.focusCurrentPaneIfNeeded()
        }
    }

    func windowDragSuppressionTarget(
        at point: NSPoint,
        eventType: NSEvent.EventType
    ) -> WindowDragSuppressionTarget? {
        guard eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return nil
        }
        if globalSearchCoordinator.state.isHUDVisible {
            let localPoint = view.convert(point, from: nil)
            if globalSearchHUDView.frame.contains(localPoint) {
                return .globalSearchHUD
            }
        }
        if windowChromeView.containsFocusedProxyIconPointInWindow(point) {
            return .proxyIcon
        }

        return nil
    }

    func deliverProxyMouseDown(_ event: NSEvent) {
        windowChromeView.deliverFocusedProxyMouseDown(with: event)
    }

    func updateTrafficLightAnchor(_ anchor: NSPoint) {
        trafficLightAnchor = anchor
        updateToggleButtonConstraints()
    }

    private func updateToggleButtonConstraints() {
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
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

    @objc
    private func handlePaneLayoutMenuAction() {
        paneLayoutMenuCoordinator.showMenu(worklaneStore: worklaneStore)
    }

    @objc
    private func handlePaneLayoutMenuItem(_ sender: NSMenuItem) {
        paneLayoutMenuCoordinator.handleMenuItem(sender)
    }

    private func installKeyboardMonitorIfNeeded() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = LocalEventMonitor(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            guard self.view.window?.isKeyWindow == true else {
                return event
            }

            guard let shortcut = KeyboardShortcut(event: event),
                let commandID = shortcutManager.commandID(for: shortcut)
            else {
                return event
            }

            guard self.isCommandAvailable(commandID) else {
                return event
            }

            self.handle(AppCommandRegistry.definition(for: commandID).action)
            return nil
        }
    }

    func handle(_ action: AppAction) {
        handle(action, syncingFocusWith: view.window?.firstResponder)
    }

    func handle(_ action: AppAction, syncingFocusWith responder: NSResponder?) {
        syncFocusedPaneWithResponderIfNeeded(responder)
        cancelPendingPaneStripScrollSwitchGestureIfNeeded(for: action)

        if let commandID = commandID(for: action), isCommandAvailable(commandID) == false {
            return
        }

        switch action {
        case .toggleSidebar:
            handleToggleSidebar()
        case .newWorklane:
            worklaneStore.createWorklane()
        case .nextWorklane:
            worklaneStore.selectNextWorklane()
        case .previousWorklane:
            worklaneStore.selectPreviousWorklane()
        case .find:
            showFocusedPaneSearch()
        case .globalFind:
            showGlobalSearch()
        case .useSelectionForFind:
            useFocusedPaneSelectionForSearch()
        case .findNext:
            findNextInFocusedPane()
        case .findPrevious:
            findPreviousInFocusedPane()
        case .copyFocusedPanePath:
            copyFocusedPanePath()
        case .cleanCopy:
            performCleanCopy()
        case .copyRaw:
            performCopyRaw()
        case .jumpToLatestNotification:
            if let notification = notificationCoordinator.store.mostUrgentUnresolved() {
                notificationCoordinator.closePanel()
                navigateToNotification(notification)
            }
        case .pane(let command):
            handlePaneCommand(command)
        case .navigateBack:
            worklaneStore.navigateBack()
        case .navigateForward:
            worklaneStore.navigateForward()
        case .showCommandPalette:
            showCommandPalette()
        case .openBranchOnRemote:
            openBranchOnRemote()
        case .openSettings:
            onShowSettingsRequested?()
        case .newWindow:
            NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil)
        case .closeWindow:
            view.window?.close()
        case .reloadConfig:
            configStore.reloadFromDisk()
        }
    }

    private func showFocusedPaneSearch() {
        if isGlobalSearchSessionActive {
            globalSearchCoordinator.end()
        }
        focusedPaneRuntime()?.showSearch()
    }

    private func showGlobalSearch() {
        globalSearchCoordinator.show()
        focusGlobalSearchField(selectAll: true)
    }

    private func useFocusedPaneSelectionForSearch() {
        if isGlobalSearchSessionActive {
            globalSearchCoordinator.end()
        }
        focusedPaneRuntime()?.useSelectionForFind()
    }

    private func findNextInFocusedPane() {
        if globalSearchHasRememberedSearch {
            globalSearchCoordinator.findNext()
            focusGlobalSearchField(selectAll: false)
            return
        }

        focusedPaneRuntime()?.findNext()
    }

    private func findPreviousInFocusedPane() {
        if globalSearchHasRememberedSearch {
            globalSearchCoordinator.findPrevious()
            focusGlobalSearchField(selectAll: false)
            return
        }

        focusedPaneRuntime()?.findPrevious()
    }

    private func handleHorizontalKeyboardResize(delta: CGFloat) {
        guard let action = worklaneStore.focusedHorizontalKeyboardResizeAction(for: delta) else {
            return
        }
        switch action {
        case .interior:
            let shouldCenterMiddlePane =
                shouldCenterFocusedInteriorPaneAfterHorizontalKeyboardResize()
            if shouldCenterMiddlePane {
                appCanvasView.centerFocusedInteriorPaneOnNextRender()
            }
            let didResize = worklaneStore.resizeFocusedPane(
                in: .horizontal,
                delta: delta,
                availableSize: appCanvasView.bounds.size,
                leadingVisibleInset: appCanvasView.leadingVisibleInset,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
            if shouldCenterMiddlePane, !didResize {
                appCanvasView.clearPendingPaneStripTargetOffsetOverride()
            }
        case .edge(let target):
            let appliedWidthDelta = worklaneStore.resize(
                .horizontalEdge(target),
                delta: delta,
                availableSize: appCanvasView.bounds.size,
                leadingVisibleInset: appCanvasView.leadingVisibleInset,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
            if target.edge == .left, abs(appliedWidthDelta) > 0.001 {
                appCanvasView.shiftPaneStripTargetOffsetOnNextRender(by: appliedWidthDelta)
            }
        }
    }

    private func handlePaneCommand(_ command: PaneCommand) {
        switch command {
        case .resizeLeft:
            appCanvasView.settlePaneStripPresentationNow()
            handleHorizontalKeyboardResize(delta: -keyboardResizeStep(for: .horizontal))
        case .resizeRight:
            appCanvasView.settlePaneStripPresentationNow()
            handleHorizontalKeyboardResize(delta: keyboardResizeStep(for: .horizontal))
        case .resizeUp:
            appCanvasView.settlePaneStripPresentationNow()
            worklaneStore.resizeFocusedPane(
                in: .vertical,
                delta: resolvedVerticalKeyboardResizeDelta(
                    keyboardResizeStep(for: .vertical)
                ),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .resizeDown:
            appCanvasView.settlePaneStripPresentationNow()
            worklaneStore.resizeFocusedPane(
                in: .vertical,
                delta: resolvedVerticalKeyboardResizeDelta(
                    -keyboardResizeStep(for: .vertical)
                ),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID()
            )
        case .arrangeHorizontally(let arrangement):
            appCanvasView.settlePaneStripPresentationNow()
            worklaneStore.arrangeActiveWorklaneHorizontally(
                arrangement,
                availableWidth: appCanvasView.bounds.width,
                leadingVisibleInset: appCanvasView.leadingVisibleInset
            )
        case .arrangeVertically(let arrangement):
            appCanvasView.settlePaneStripPresentationNow()
            worklaneStore.arrangeActiveWorklaneVertically(arrangement)
        case .arrangeGoldenRatio(let preset):
            appCanvasView.settlePaneStripPresentationNow()
            switch preset {
            case .focusWide, .focusNarrow:
                worklaneStore.arrangeActiveWorklaneGoldenWidth(
                    focusWide: preset == .focusWide,
                    availableWidth: appCanvasView.bounds.width,
                    leadingVisibleInset: appCanvasView.leadingVisibleInset
                )
            case .focusTall, .focusShort:
                worklaneStore.arrangeActiveWorklaneGoldenHeight(
                    focusTall: preset == .focusTall,
                    availableSize: appCanvasView.bounds.size
                )
            }
        case .resetLayout:
            worklaneStore.resetActiveWorklaneLayout()
        case .closeFocusedPane:
            let focusedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID
            if configStore.current.confirmations.confirmBeforeClosingPane,
                let focusedPaneID,
                let reason = worklaneStore.paneCloseConfirmationReason(focusedPaneID)
            {
                showClosePaneConfirmation(reason: reason) { [weak self] in
                    self?.closeFocusedPane()
                }
            } else {
                closeFocusedPane()
            }
        case .toggleZoomOut:
            appCanvasView.paneStripView.toggleZoom()
        default:
            worklaneStore.send(command)
        }
    }

    private func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        if event == .surfaceClosed {
            handlePaneCloseResult(worklaneStore.closePaneFromShellExit(id: paneID))
            return
        }

        worklaneStore.handleTerminalEvent(paneID: paneID, event: event)
    }

    private func closePane(id paneID: PaneID) {
        handlePaneCloseResult(worklaneStore.closePane(id: paneID))
    }

    private func closeFocusedPane() {
        handlePaneCloseResult(worklaneStore.closeFocusedPane())
    }

    private func handlePaneCloseResult(_ result: WorklaneStore.PaneCloseResult) {
        switch result {
        case .closed, .notFound:
            return
        case .closeWindow:
            requestContainingWindowClose()
        }
    }

    private func requestContainingWindowClose() {
        if let onCloseWindowRequested {
            onCloseWindowRequested()
            return
        }

        view.window?.close()
    }

    private var isShowingClosePaneConfirmation = false

    private func showClosePaneConfirmation(
        reason: WorklaneStore.PaneCloseReason,
        onConfirm: @escaping () -> Void
    ) {
        guard !isShowingClosePaneConfirmation else { return }
        isShowingClosePaneConfirmation = true

        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        switch reason {
        case .runningProcess:
            alert.informativeText = "The running process in this pane will be terminated."
        case .sessionHistory:
            alert.informativeText = "This pane's session history will be lost."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        let isDark = currentTheme.windowBackground.isDarkThemeColor
        alert.window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        guard let window = view.window else {
            isShowingClosePaneConfirmation = false
            if alert.runModal() == .alertFirstButtonReturn {
                onConfirm()
            }
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            self?.isShowingClosePaneConfirmation = false
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }

    private func shouldCenterFocusedInteriorPaneAfterHorizontalKeyboardResize() -> Bool {
        guard
            let state = worklaneStore.activeWorklane?.paneStripState,
            let focusedColumnID = state.focusedColumnID,
            let focusedColumnIndex = state.columns.firstIndex(where: { $0.id == focusedColumnID })
        else {
            return false
        }

        return state.columns.count > 2
            && focusedColumnIndex > 0
            && focusedColumnIndex + 1 < state.columns.count
    }

    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID) {
        worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
        notificationCoordinator.store.resolve(
            windowID: windowID, worklaneID: worklaneID, paneID: paneID)
    }

    private func navigateToNotification(_ notification: AppNotification) {
        if notification.windowID == windowID {
            navigateToPane(worklaneID: notification.worklaneID, paneID: notification.paneID)
            return
        }

        onNavigateToNotificationRequested?(
            notification.windowID, notification.worklaneID, notification.paneID)
    }

    private func endAllLocalSearches() {
        for worklane in worklaneStore.worklanes {
            for pane in worklane.paneStripState.panes {
                runtimeRegistry.runtime(for: pane.id)?.endSearch()
            }
        }
    }

    private func applyGlobalSearchState(_ state: GlobalSearchState) {
        globalSearchHUDView.apply(search: state)
    }

    private func focusGlobalSearchField(selectAll: Bool) {
        guard globalSearchCoordinator.state.isHUDVisible else {
            return
        }

        globalSearchHUDView.focusField(
            selectAll: selectAll && !globalSearchCoordinator.state.needle.isEmpty)
    }

    private func showCommandPalette() {
        guard let window = view.window else { return }

        let activeWorklane = worklaneStore.activeWorklane
        let availabilityContext = commandAvailabilityContext()
        let focusedBranchName = WorklaneContextFormatter.trimmed(
            activeWorklane?.focusedPaneContext?.presentation.branchDisplayText
        )
        let focusedPanePath: String? = {
            guard let paneID = activeWorklane?.paneStripState.focusedPaneID else { return nil }
            return activeWorklane?.auxiliaryStateByPaneID[paneID]?.shellContext?.path
        }()

        let openWithTargets =
            focusedOpenWithContext != nil
            ? availableOpenWithTargets
            : []

        commandPaletteController.show(
            in: window,
            theme: currentTheme,
            shortcutManager: shortcutManager,
            availabilityContext: availabilityContext,
            focusedPanePath: focusedPanePath,
            focusedBranchName: focusedBranchName,
            openWithTargets: openWithTargets
        )
    }

    private func openWithFromPalette(stableID: String, workingDirectory: String) {
        guard let target = availableOpenWithTargets.first(where: { $0.stableID == stableID }) else {
            return
        }
        openWithService.open(target: target, workingDirectory: workingDirectory)
    }

    private func copyFocusedPanePath() {
        guard
            let focusedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID
        else {
            return
        }
        copyPath(forPaneID: focusedPaneID)
    }

    private func copyPath(forPaneID paneID: PaneID) {
        guard
            let path = worklaneStore.activeWorklane?.auxiliaryStateByPaneID[paneID]?.shellContext?
                .path,
            !path.isEmpty
        else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showPathCopiedToast()
    }

    private func showPathCopiedToast() {
        pathCopiedToastView?.removeFromSuperview()
        let toast = PathCopiedToastView()
        pathCopiedToastView = toast
        toast.show(in: appCanvasView, theme: currentTheme)
    }

    private func performCleanCopy() {
        // Suppress callback cleaning — we clean at this call site instead.
        // Safe because ghostty_surface_binding_action is a synchronous C FFI call:
        // the clipboard write callback fires within performBindingAction before
        // NSApp.sendAction returns, so the flag is always set when the callback reads it.
        CleanCopyPipeline.suppressCallbackCleaning = true
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        CleanCopyPipeline.suppressCallbackCleaning = false

        let result = CleanCopyPipeline.cleanPasteboardInPlace(.general)
        let message = (result?.wasModified == true) ? "Copied (cleaned)" : "Copied"
        showCopyToast(message: message)
    }

    private func performCopyRaw() {
        CleanCopyPipeline.suppressCallbackCleaning = true
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        CleanCopyPipeline.suppressCallbackCleaning = false
    }

    @objc private func handleCleanCopyDidModifyPasteboard() {
        showCopyToast(message: "Copied (cleaned)")
    }

    private func showCopyToast(message: String) {
        pathCopiedToastView?.removeFromSuperview()
        let toast = PathCopiedToastView()
        pathCopiedToastView = toast
        toast.show(message: message, in: appCanvasView, theme: currentTheme)
    }

    private func keyboardResizeStep(for axis: PaneResizeAxis) -> CGFloat {
        let minimumSizesByPaneID = paneMinimumSizesByPaneID()
        guard let focusedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID,
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

    private func commandAvailabilityContext() -> CommandAvailabilityContext {
        let activeWorklane = worklaneStore.activeWorklane
        let paneStripState = activeWorklane?.paneStripState
        let totalPaneCount = worklaneStore.worklanes.reduce(0) { partialResult, worklane in
            partialResult + worklane.paneStripState.panes.count
        }
        return CommandAvailabilityContext(
            worklaneCount: worklaneStore.worklanes.count,
            activePaneCount: paneStripState?.panes.count ?? 0,
            totalPaneCount: totalPaneCount,
            activeColumnCount: paneStripState?.columns.count ?? 0,
            focusedColumnPaneCount: paneStripState?.focusedColumn?.panes.count ?? 0,
            focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
            globalSearchHasRememberedSearch: globalSearchHasRememberedSearch,
            activeWorklaneHasBranchURL: activeWorklaneHasBranchRemoteURL
        )
    }

    private var activeWorklaneHasBranchRemoteURL: Bool {
        guard let presentation = worklaneStore.activeWorklane?.focusedPaneContext?.presentation,
            let branchURL = presentation.branchURL,
            let branchText = WorklaneContextFormatter.trimmed(presentation.branchDisplayText)
        else {
            return false
        }

        return branchURL.absoluteString.isEmpty == false && branchText.isEmpty == false
    }

    private func openBranchOnRemote() {
        guard
            let branchURL = worklaneStore.activeWorklane?.focusedPaneContext?.presentation.branchURL
        else {
            return
        }

        NSWorkspace.shared.open(branchURL)
    }

    var focusedTerminalHasSelection: Bool {
        guard let validator = view.window?.firstResponder as? NSMenuItemValidation else {
            return false
        }
        let probe = NSMenuItem(title: "", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        return validator.validateMenuItem(probe)
    }

    func isCommandAvailable(_ commandID: AppCommandID) -> Bool {
        CommandAvailabilityResolver.isCommandAvailable(commandID, for: commandAvailabilityContext())
    }

    private func commandID(for action: AppAction) -> AppCommandID? {
        AppCommandRegistry.definitions.first(where: { $0.action == action })?.id
    }

    private func resolvedVerticalKeyboardResizeDelta(_ delta: CGFloat) -> CGFloat {
        guard
            worklaneStore.activeWorklane?.paneStripState.shouldInvertVerticalKeyboardResizeDelta()
                == true
        else {
            return delta
        }

        return -delta
    }

    private func paneMinimumSizesByPaneID() -> [PaneID: PaneMinimumSize] {
        guard let worklane = worklaneStore.activeWorklane else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: worklane.paneStripState.panes.map { pane in
                let runtime = runtimeRegistry.runtime(for: pane)
                let minimumWidth =
                    runtime.cellWidth > 0
                    ? max(
                        PaneMinimumSize.fallback.width,
                        runtime.cellWidth * PaneResize.minimumColumns)
                    : PaneMinimumSize.fallback.width
                let minimumHeight =
                    runtime.cellHeight > 0
                    ? max(
                        PaneMinimumSize.fallback.height, runtime.cellHeight * PaneResize.minimumRows
                    )
                    : PaneMinimumSize.fallback.height
                return (pane.id, PaneMinimumSize(width: minimumWidth, height: minimumHeight))
            })
    }

    private func syncFocusedPaneWithResponderIfNeeded(_ responder: NSResponder?) {
        guard let paneID = paneID(containing: responder),
            worklaneStore.activeWorklane?.paneStripState.focusedPaneID != paneID
        else {
            return
        }

        worklaneStore.focusPane(id: paneID)
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
        guard windowObserverBag == nil, let window = view.window else {
            return
        }

        let observerBag = NotificationObserverBag()
        [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
        ].forEach { name in
            observerBag.addObserver(forName: name, object: window) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWindowStateDidChange()
                }
            }
        }
        windowObserverBag = observerBag
    }

    @objc
    private func handleWindowStateDidChange() {
        appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
        syncSidebarWidthToAvailableWidth(persist: false)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.updateSurfaceActivities()
    }

    private func cancelPendingPaneStripScrollSwitchGestureIfNeeded(for action: AppAction) {
        switch action {
        case .newWorklane, .nextWorklane, .previousWorklane, .navigateBack, .navigateForward,
            .pane(_):
            appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
        default:
            break
        }
    }

    func handleWindowDidResize() {
        // NSWindow.didResize follows AppKit layout. viewDidLayout handles pane relayout
        // so we avoid forcing an additional resize render from the delegate path.
    }

    private func invalidateStaleAgentSweepTimer() {
        staleAgentSweepTimer?.invalidate()
        staleAgentSweepTimer = nil
    }

    private func installStaleAgentSweepTimer() {
        invalidateStaleAgentSweepTimer()
        staleAgentSweepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.worklaneStore.clearStaleAgentSessions()
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
        paneLayoutMenuCoordinator.applyTheme(theme, animated: animated)
        paneNavigationButtons.configure(theme: theme, animated: animated)
        notificationCoordinator.applyTheme(theme, animated: animated)
        updatePaneNavigationButtonState()
        windowChromeView.apply(theme: theme, animated: animated)
        appCanvasView.apply(theme: theme, animated: animated)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        onWindowChromeNeedsUpdate?()
    }

    private func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            // Shell fill is painted via window.backgroundColor (below) so that the
            // crescent between our 26pt clip and NSThemeFrame's native silhouette is
            // filled too — killing the shadow-halo seam. Painting it here as well would
            // double-up the alpha and halve the translucency (0.5 * 0.5 → 0.75 effective).
            self.view.layer?.backgroundColor = NSColor.clear.cgColor
            self.view.layer?.borderColor = theme.topChromeBorder.cgColor
        }
        if let window = view.window {
            window.backgroundColor = theme.windowBackground
            window.invalidateShadow()
            LibghosttyRuntime.shared.applyBackgroundBlur(to: window)
        }
    }

    private func handleSidebarWidthChange(_ width: CGFloat) {
        updateSidebarWidth(width, persist: true)
    }

    private func syncSidebarVisibilityControls(animated: Bool) {
        sidebarView.setResizeEnabled(sidebarMotionCoordinator.showsResizeHandle)
        sidebarToggleButton.configure(
            theme: currentTheme,
            isActive: sidebarMotionCoordinator.mode == .pinnedOpen,
            animated: animated
        )
        onWindowChromeNeedsUpdate?()
    }

    /// Total width of the left-side chrome controls that sit between the sidebar
    /// trailing edge and the centered title row: toggle + pane layout menu +
    /// navigation buttons + notification bell, including inter-button gaps.
    private static let chromeControlsBarWidth: CGFloat =
        SidebarToggleButton.buttonSize + 4
        + PaneLayoutMenuButton.buttonSize + 4
        + PaneNavigationButtons.totalWidth + 8
        + NotificationBellButton.buttonSize

    private func applySidebarMotionState(
        _ motionState: SidebarMotionState,
        animated: Bool,
        forceLayout: Bool = true,
        reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        let sidebarWidth = SidebarWidthPreference.clamped(
            sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth,
            availableWidth: resolvedSidebarAvailableWidth()
        )
        let hiddenTravel = sidebarWidth + ShellMetrics.shellGap
        let reservedInset = hiddenTravel * motionState.reservedFraction
        let leadingConstant =
            ShellMetrics.outerInset - ((1 - motionState.revealFraction) * hiddenTravel)
        let floatingStrength = max(0, motionState.revealFraction - motionState.reservedFraction)

        let duration = SidebarTransitionProfile.resolvedDuration(reducedMotion: reducedMotion)
        let timingFunction = SidebarTransitionProfile.resolvedTimingFunction(
            reducedMotion: reducedMotion)

        let previousLeadingInset = appCanvasView.leadingVisibleInset
        let previousWorklaneState = worklaneStore.state
        let previousLayoutContext = currentPaneLayoutContext
        worklaneStore.batchUpdate { [self] in
            updatePaneLayoutContextIfNeeded(force: true, leadingVisibleInsetOverride: reservedInset)
        }
        let needsCanvasTransition =
            abs(previousLeadingInset - reservedInset) > 0.001
            || previousWorklaneState != worklaneStore.state
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
        let closedToggleTarget = trafficLightAnchor.x + SidebarToggleButton.spacingFromTrafficLights
        let openToggleTarget = max(
            closedToggleTarget,
            sidebarTrailingEdge + ShellMetrics.shellGap
        )
        let toggleTarget =
            motionState.reservedFraction == 1
            ? openToggleTarget
            : closedToggleTarget
        windowChromeView.leadingControlsInset =
            (toggleTarget - ShellMetrics.outerInset)
            + Self.chromeControlsBarWidth
        let pinnedHeaderContentMinX =
            trafficLightAnchor.x
            - leadingConstant
            + SidebarToggleButton.spacingFromTrafficLights
        sidebarView.updateHeaderLayout(
            visibilityMode: sidebarMotionCoordinator.mode,
            pinnedContentMinX: pinnedHeaderContentMinX
        )
        if forceLayout {
            sidebarView.layoutSubtreeIfNeeded()
        }

        if animated, forceLayout {
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
            if forceLayout {
                view.layoutSubtreeIfNeeded()
            }
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

    var currentWindowTheme: ZenttyTheme {
        currentTheme
    }

    var anyPaneRequiresQuitConfirmation: Bool {
        worklaneStore.anyPaneRequiresQuitConfirmation
    }

    func containsWorklane(_ worklaneID: WorklaneID) -> Bool {
        worklaneStore.worklanes.contains { $0.id == worklaneID }
    }

    func containsPane(worklaneID: WorklaneID, paneID: PaneID) -> Bool {
        worklaneStore.worklanes.contains { worklane in
            worklane.id == worklaneID
                && worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }
    }

    // MARK: - Pane IPC

    func handlePaneIPCCommand(_ command: PaneCommand) {
        handlePaneCommand(command)
    }

    func splitWithLayout(
        placement: PanePlacement,
        isHorizontal: Bool,
        layout: SplitLayoutAction
    ) {
        appCanvasView.settlePaneStripPresentationNow()
        worklaneStore.splitWithLayout(
            placement: placement,
            isHorizontal: isHorizontal,
            layout: layout,
            availableWidth: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset,
            availableSize: appCanvasView.bounds.size,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
    }

    func focusPaneByID(_ paneID: PaneID, in worklaneID: WorklaneID) {
        worklaneStore.selectWorklane(id: worklaneID)
        worklaneStore.focusPane(id: paneID)
    }

    func closePaneByID(_ paneID: PaneID) {
        handlePaneCloseResult(worklaneStore.closePane(id: paneID))
    }

    func resizeFocusedColumnToFraction(_ fraction: CGFloat) {
        appCanvasView.settlePaneStripPresentationNow()
        worklaneStore.resizeFocusedColumnToFraction(
            fraction,
            availableWidth: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
    }

    func resizeFocusedPaneHeightToFraction(_ fraction: CGFloat) {
        worklaneStore.resizeFocusedPaneHeightToFraction(fraction)
    }

    func equalizeFocusedColumnPaneHeights() {
        worklaneStore.equalizeFocusedColumnPaneHeights()
    }

    func paneListEntries(for worklaneID: WorklaneID) -> [PaneListEntry] {
        guard let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }

        var entries: [PaneListEntry] = []
        var index = 1
        for (columnIndex, column) in worklane.paneStripState.columns.enumerated() {
            for pane in column.panes {
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                let isFocused = worklane.paneStripState.focusedPaneID == pane.id
                entries.append(PaneListEntry(
                    index: index,
                    id: pane.id.rawValue,
                    column: columnIndex + 1,
                    title: pane.title,
                    workingDirectory: auxiliaryState?.shellContext?.path,
                    isFocused: isFocused,
                    agentTool: auxiliaryState?.agentStatus?.tool.displayName,
                    agentStatus: auxiliaryState?.agentStatus?.state.rawValue
                ))
                index += 1
            }
        }
        return entries
    }

    func resolvePaneID(_ target: String, in worklaneID: WorklaneID) -> PaneID? {
        guard let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }) else {
            return nil
        }

        if target.hasPrefix("pn_") {
            let paneID = PaneID(target)
            if worklane.paneStripState.panes.contains(where: { $0.id == paneID }) {
                return paneID
            }
            return nil
        }

        if let displayIndex = Int(target), displayIndex >= 1 {
            let allPanes = worklane.paneStripState.columns.flatMap(\.panes)
            if displayIndex <= allPanes.count {
                return allPanes[displayIndex - 1].id
            }
        }

        return nil
    }

    var worklaneTitles: [String] {
        worklaneStore.worklanes.map(\.title)
    }

    var activeWorklaneTitle: String? {
        worklaneStore.activeWorklane?.title
    }

    var activePaneTitles: [String] {
        worklaneStore.activeWorklane?.paneStripState.panes.map(\.title) ?? []
    }

    var focusedPaneTitle: String? {
        worklaneStore.activeWorklane?.paneStripState.focusedPane?.title
    }

    var focusedOpenWithContext: WorklaneOpenWithContext? {
        worklaneStore.focusedOpenWithContext
    }

    var focusedPaneHasRememberedSearch: Bool {
        focusedPaneRuntime()?.snapshot.search.hasRememberedSearch ?? false
    }

    var globalSearchHasRememberedSearch: Bool {
        globalSearchCoordinator.state.hasRememberedSearch
    }

    private var isGlobalSearchSessionActive: Bool {
        globalSearchCoordinator.state.isHUDVisible
            || globalSearchCoordinator.state.hasRememberedSearch
    }

    var focusedPaneIDForTesting: PaneID? {
        worklaneStore.activeWorklane?.paneStripState.focusedPaneID
    }

    var focusedPaneSearchStateForTesting: PaneSearchState? {
        focusedPaneRuntime()?.snapshot.search
    }

    var availableOpenWithTargets: [OpenWithResolvedTarget] {
        openWithService.availableTargets(preferences: configStore.current.openWith)
    }

    private func focusedPaneRuntime() -> PaneRuntime? {
        guard let paneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID else {
            return nil
        }

        return runtimeRegistry.runtime(for: paneID)
    }

    var primaryOpenWithTarget: OpenWithResolvedTarget? {
        openWithService.primaryTarget(preferences: configStore.current.openWith)
    }

    private func updatePaneViewportHeight() {
        worklaneStore.updatePaneViewportHeight(appCanvasView.bounds.height)
    }

    var chromeView: WindowChromeView {
        windowChromeView
    }

    #if DEBUG
        var activeWorklaneIDForTesting: WorklaneID? {
            worklaneStore.activeWorklane?.id
        }

        var focusedPaneEnvironmentForTesting: [String: String]? {
            worklaneStore.activeWorklane?.paneStripState.focusedPane?.sessionRequest
                .environmentVariables
        }

        var notificationStoreForTesting: NotificationStore {
            notificationCoordinator.store
        }

        var appCanvasViewForTesting: AppCanvasView {
            appCanvasView
        }

        var pathCopiedToastViewForTesting: PathCopiedToastView? {
            pathCopiedToastView
        }

        func handleTerminalEventForTesting(paneID: PaneID, event: TerminalEvent) {
            handleTerminalEvent(paneID: paneID, event: event)
        }

        func triggerCopyFocusedPanePathForTesting() {
            copyFocusedPanePath()
        }

        func handleSidebarVisibilityEvent(_ event: SidebarVisibilityEvent) {
            sidebarMotionCoordinator.handle(event)
            syncSidebarVisibilityControls(animated: false)
        }

        func replaceWorklanes(_ worklanes: [WorklaneState], activeWorklaneID: WorklaneID? = nil) {
            worklaneStore.replaceWorklanes(worklanes, activeWorklaneID: activeWorklaneID)
            renderCoordinator.render()
        }

        func focusPaneDirectly(_ paneID: PaneID) {
            worklaneStore.focusPane(id: paneID)
            renderCoordinator.render()
        }

        func applyAgentStatusPayloadForTesting(_ payload: AgentStatusPayload) {
            worklaneStore.applyAgentStatusPayload(payload)
            renderCoordinator.render()
        }

        func setSidebarWidth(_ width: CGFloat) {
            updateSidebarWidth(width, persist: false)
        }

        func settleSidebarTransitionForTesting() {
            applySidebarMotionState(
                sidebarMotionCoordinator.currentMotionState,
                animated: false
            )
            appCanvasView.settlePaneStripPresentationNow()
            view.layoutSubtreeIfNeeded()
        }

        func prepareForTestingTearDown() {
            invalidateStaleAgentSweepTimer()
            appCanvasView.prepareForTestingTearDown()
            view.layer?.removeAllAnimations()
            sidebarView.layer?.removeAllAnimations()
            view.layoutSubtreeIfNeeded()
        }

        var paneStripStateForTesting: PaneStripState {
            worklaneStore.state
        }

        func paneLayoutMenuCommandTitlesForTesting() -> [String] {
            paneLayoutMenuCoordinator.makeMenu(worklaneStore: worklaneStore).items
                .filter { !$0.isSeparatorItem }
                .map(\.title)
        }

        var globalSearchStateForTesting: GlobalSearchState {
            globalSearchCoordinator.state
        }

        var isGlobalSearchHUDVisibleForTesting: Bool {
            !globalSearchHUDView.isHidden
        }

        func globalSearchHUDButtonPointInWindowForTesting(
            _ button: WindowSearchHUDView.ButtonKind
        ) -> NSPoint? {
            globalSearchHUDView.buttonPointInWindowForTesting(button)
        }

        func updateGlobalSearchQueryForTesting(_ query: String) {
            globalSearchCoordinator.updateQuery(query)
        }

        func performGlobalSearchNextForTesting() {
            globalSearchCoordinator.findNext()
        }

        func performGlobalSearchPreviousForTesting() {
            globalSearchCoordinator.findPrevious()
        }

        func paneLayoutSubmenuCommandTitlesForTesting(_ title: String) -> [String] {
            paneLayoutMenuCoordinator.makeMenu(worklaneStore: worklaneStore).items
                .first { !$0.isSeparatorItem && $0.title == title }?
                .submenu?
                .items
                .filter { !$0.isSeparatorItem }
                .map(\.title) ?? []
    }
    #endif

    var workspaceState: WindowWorkspaceState {
        WindowWorkspaceState(
            worklanes: worklaneStore.worklanes,
            activeWorklaneID: worklaneStore.activeWorklaneID
        )
    }

    private func resolvedSidebarAvailableWidth() -> CGFloat? {
        view.bounds.width > 0 ? view.bounds.width : view.window?.screen?.visibleFrame.width
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

    private func updateSidebarWidth(_ width: CGFloat, persist: Bool) {
        let previousWidth = sidebarMotionCoordinator.currentSidebarWidth
        sidebarMotionCoordinator.setSidebarWidth(
            width,
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
        let leadingVisibleInset =
            leadingVisibleInset
            ?? (sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth)
            + ShellMetrics.shellGap
        appCanvasView.leadingVisibleInset = leadingVisibleInset
        windowChromeView.leadingVisibleInset = leadingVisibleInset
    }

    private func updateWindowChromeLeadingControlsInset() {
        guard isViewLoaded else {
            return
        }

        let bellMaxXInRoot = notificationCoordinator.bellButton.frame.maxX
        let bellMaxXInChrome = windowChromeView.convert(
            NSPoint(x: bellMaxXInRoot, y: 0),
            from: view
        ).x
        windowChromeView.leadingControlsInset = bellMaxXInChrome
    }

    func updatePaneLayoutPreferences(_ preferences: PaneLayoutPreferences) {
        paneLayoutPreferences = preferences
        try? configStore.update {
            $0.paneLayout = preferences
        }
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.render()
    }

    private func handleAppUpdateAvailabilityChange(_ isUpdateAvailable: Bool) {
        self.isUpdateAvailable = isUpdateAvailable
        guard isViewLoaded else {
            return
        }

        sidebarView.setUpdateAvailable(isUpdateAvailable)
    }

    private func applyPersistedConfig(_ config: AppConfig) {
        let appearanceDidChange = config.appearance != lastAppliedAppearanceSettings
        lastAppliedAppearanceSettings = config.appearance
        paneLayoutPreferences = config.paneLayout
        shortcutManager = ShortcutManager(shortcuts: config.shortcuts)
        paneLayoutMenuCoordinator.updateShortcutManager(shortcutManager)
        preloadOpenWithIcons()
        sidebarMotionCoordinator.applyPersistedSidebarSettings(
            config.sidebar,
            availableWidth: resolvedSidebarAvailableWidth()
        )
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(sidebarMotionCoordinator.currentMotionState, animated: false)
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.render()
        updateOpenWithChromeState()

        if appearanceDidChange {
            themeCoordinator.refreshTheme(for: view.effectiveAppearance, animated: true)
        }
    }

    private func updatePaneNavigationButtonState() {
        let controller = worklaneStore.focusHistoryController
        paneNavigationButtons.update(
            canGoBack: controller.history.canGoBack,
            canGoForward: controller.history.canGoForward,
            theme: currentTheme
        )
    }

    private func updateOpenWithChromeState() {
        let primaryTarget = primaryOpenWithTarget
        let canOpenFocusedPane = focusedOpenWithContext != nil && primaryTarget != nil
        windowChromeView.render(
            openWith: WindowChromeOpenWithState(
                title: primaryTarget?.displayName ?? "Open With",
                icon: primaryTarget.flatMap { openWithService.icon(for: $0) },
                isPrimaryEnabled: canOpenFocusedPane,
                isMenuEnabled: true
            ))
    }

    private func preloadOpenWithIcons() {
        openWithService.preloadIcons(for: availableOpenWithTargets)
    }

    private func updatePaneLayoutContextIfNeeded(
        force: Bool = false,
        leadingVisibleInsetOverride: CGFloat? = nil,
        notifyLayoutResize: Bool = true
    ) -> Bool {
        let resolvedContext = resolveCurrentPaneLayoutContext(
            leadingVisibleInsetOverride: leadingVisibleInsetOverride
        )
        guard force || resolvedContext != currentPaneLayoutContext else {
            return false
        }

        currentPaneLayoutContext = resolvedContext
        worklaneStore.updateLayoutContext(
            resolvedContext,
            notifyLayoutResize: notifyLayoutResize
        )
        return true
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

// MARK: - RenderEnvironmentProviding

extension RootViewController: RenderEnvironmentProviding {
    var renderTheme: ZenttyTheme {
        currentTheme
    }

    var renderSidebarWidth: CGFloat {
        sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
    }

    func renderLeadingInset(sidebarWidth: CGFloat) -> CGFloat {
        sidebarMotionCoordinator.effectiveLeadingInset(
            sidebarWidth: sidebarWidth,
            availableWidth: resolvedSidebarAvailableWidth()
        )
    }

    var renderWindowState: (isVisible: Bool, isKeyWindow: Bool) {
        (
            isVisible: view.window?.isVisible ?? false,
            isKeyWindow: view.window?.isKeyWindow ?? false
        )
    }

    func renderSidebarSyncNeeded() {
        syncSidebarVisibilityControls(animated: false)
    }
}

extension RootViewController: WindowSearchHUDViewDelegate {
    func windowSearchHUDView(_ hudView: WindowSearchHUDView, didChangeQuery query: String) {
        globalSearchCoordinator.updateQuery(query)
    }

    func windowSearchHUDViewDidRequestNext(_ hudView: WindowSearchHUDView) {
        globalSearchCoordinator.findNext()
    }

    func windowSearchHUDViewDidRequestPrevious(_ hudView: WindowSearchHUDView) {
        globalSearchCoordinator.findPrevious()
    }

    func windowSearchHUDViewDidRequestHide(_ hudView: WindowSearchHUDView) {
        globalSearchCoordinator.hide()
        focusedPaneRuntime()?.hostView.focusTerminal()
    }

    func windowSearchHUDViewDidRequestClose(_ hudView: WindowSearchHUDView) {
        globalSearchCoordinator.end()
        focusedPaneRuntime()?.hostView.focusTerminal()
    }
}

/// Transparent to hit testing — allows mouse events to pass through to views below.
private final class HitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
