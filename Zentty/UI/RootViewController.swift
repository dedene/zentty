import AppKit
import QuartzCore
import SwiftUI
import os

enum FocusedTerminalInterruptBridge {
    static func paneIDForUserInterrupt(
        event: NSEvent,
        activeWorklane: WorklaneState?,
        isFocusedPaneTerminalFocused: Bool
    ) -> PaneID? {
        let matchesInterrupt = TerminalInterruptKeyRecognizer.matchesUserInterrupt(event)
            || TerminalInterruptKeyRecognizer.matchesKimiInterruptEscape(event)
        guard matchesInterrupt,
              isFocusedPaneTerminalFocused,
              let activeWorklane,
              let paneID = activeWorklane.paneStripState.focusedPaneID,
              let status = activeWorklane.auxiliaryStateByPaneID[paneID]?.agentStatus,
              status.tool == .kimi,
              status.source == .explicit,
              status.state == .running || status.state == .starting
        else {
            return nil
        }

        return paneID
    }
}

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

    let worklaneStore: WorklaneStore
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
    private let agentCaffeinationController = AgentCaffeinationController.shared
    private let sidebarMotionCoordinator: SidebarMotionCoordinator
    private let themeCoordinator: ThemeCoordinator
    private let notificationCoordinator: NotificationChromeCoordinator
    private let renderCoordinator: WorklaneRenderCoordinator
    private var staleAgentSweepTimer: Timer?
    private var bookmarksPopover: NSPopover?
    private var bookmarksPopoverObserverToken: NSObjectProtocol?
    private lazy var bookmarkStore: BookmarkStore = {
        let store = BookmarkStore(fileURL: AppConfigStore.bookmarksFileURL())
        store.onPersistError = { [weak self] error in
            self?.presentBookmarkPersistError(error)
        }
        return store
    }()
    private lazy var appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
    private let peekView = WorklanePeekView()
    private let peekKeyMonitor = WorklanePeekKeyMonitor()
    private let peekController: WorklanePeekController
    private var peekSidebarFocusOverride: WorklaneSidebarFocusOverride?
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
    private var isFullScreen = false
    private var trafficLightAnchor = SidebarLayout.defaultTrafficLightAnchor
    private var pathCopiedToastView: PathCopiedToastView?
    private let paneNavigationButtons = PaneNavigationButtons()
    private let paneLayoutMenuCoordinator: PaneLayoutMenuCoordinator
    private lazy var leadingChromeControlsBar = LeadingChromeControlsBar(
        toggle: sidebarToggleButton,
        layoutMenu: paneLayoutMenuCoordinator.menuButton,
        navigation: paneNavigationButtons,
        inbox: notificationCoordinator.inboxButton
    )
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
    var onShowSettingsSectionRequested: ((SettingsSection) -> Void)?
    var onCheckForUpdatesRequested: (() -> Void)?
    var onCloseWindowRequested: (() -> Void)?
    var onNavigateToNotificationRequested: ((WindowID, WorklaneID, PaneID) -> Void)?
    var onMovePaneToNewWindowRequested: ((PaneID?) -> Void)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
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
            gitContextResolver: gitContextResolver,
            agentTeamsEnabledProvider: { [weak configStore] in
                configStore?.current.agentTeams.enabled ?? false
            }
        )
        self.peekController = WorklanePeekController(
            worklaneAccess: worklaneStore
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
        worklaneStore.scrollbackProvider = { [weak self] paneID in
            guard let self else { return nil }
            guard let runtime = self.runtimeRegistry.runtime(for: paneID),
                  let reader = runtime.adapter as? TerminalTextReading
            else { return nil }
            return reader.readText(includeScrollback: true, lineLimit: 5_000)
        }
        ClosedPaneScrollbackArchive.purgeStale()
        preloadOpenWithIcons()
        wirePeek()
    }

    private func wirePeek() {
        peekController.delegate = self
        peekKeyMonitor.handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .tab(let forward):
                self.peekController.handleTab(forward: forward)
            case .escape:
                self.peekController.handleEscape()
            case .ctrlReleased:
                self.peekController.handleCtrlReleased()
            }
        }
        appCanvasView.paneStripView.onZoomTransformChanged = { [weak self] in
            self?.refreshPeekOverlay()
        }
        // Keep neighbor lanes streaming live: feed the peek-visible
        // worklane set into the render coordinator, and re-push surface
        // activities whenever the set changes (open, lazy carrier
        // creation during pan, close).
        renderCoordinator.peekVisibleWorklaneIDsProvider = { [weak self] in
            self?.peekView.peekVisibleWorklaneIDs ?? []
        }
        renderCoordinator.sidebarFocusOverrideProvider = { [weak self] in
            self?.peekSidebarFocusOverride
        }
        peekView.onPeekVisibleWorklanesChanged = { [weak self] in
            self?.renderCoordinator.updateSurfaceActivities()
        }
        peekView.onGeometryChanged = { [weak self] in
            self?.refreshPeekOverlay()
        }
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
            agentCaffeinationController.removeSource(id: windowID)
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
        refreshShortcutTooltips()
        applyInitialState()
        syncAgentCaffeinationState()
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
        globalSearchHUDView.translatesAutoresizingMaskIntoConstraints = false
        peekView.translatesAutoresizingMaskIntoConstraints = false
        peekView.isHidden = true
        view.addSubview(appCanvasView)
        view.addSubview(peekView)
        view.addSubview(globalSearchHUDView)
        view.addSubview(windowChromeView)
        view.addSubview(sidebarHoverRailView)
        view.addSubview(sidebarView)
        view.addSubview(dragOverlayView)
        view.addSubview(leadingChromeControlsBar)
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
        let toggleLeadingConstraint = leadingChromeControlsBar.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: initialSidebarTrailing + ShellMetrics.shellGap
        )
        self.toggleLeadingConstraint = toggleLeadingConstraint

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(
                equalTo: view.topAnchor, constant: ShellMetrics.outerInset),
            sidebarLeadingConstraint,
            sidebarView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -ShellMetrics.outerInset),
            sidebarWidthConstraint,

            appCanvasView.topAnchor.constraint(
                equalTo: windowChromeView.bottomAnchor,
                constant: ShellMetrics.headerOuterPadding
            ),
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

            // Worklane Peek overlay matches canvas frame too — it sits above
            // the panes but below the chrome and sidebar.
            peekView.topAnchor.constraint(equalTo: appCanvasView.topAnchor),
            peekView.leadingAnchor.constraint(equalTo: appCanvasView.leadingAnchor),
            peekView.trailingAnchor.constraint(equalTo: appCanvasView.trailingAnchor),
            peekView.bottomAnchor.constraint(equalTo: appCanvasView.bottomAnchor),

            windowChromeView.topAnchor.constraint(
                equalTo: view.topAnchor, constant: ShellMetrics.headerOuterPadding),
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
            leadingChromeControlsBar.centerYAnchor.constraint(
                equalTo: windowChromeView.centerYAnchor,
                constant: 3
            ),
            leadingChromeControlsBar.widthAnchor.constraint(
                equalToConstant: LeadingChromeControlsBar.totalWidth
            ),
            leadingChromeControlsBar.heightAnchor.constraint(
                equalToConstant: LeadingChromeControlsBar.height
            ),
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
            case .historyChanged:
                break
            default:
                self.syncAgentCaffeinationState()
            }

            switch change {
            case .paneStructure, .worklaneListChanged:
                if self.isGlobalSearchSessionActive {
                    self.globalSearchCoordinator.end()
                } else {
                    self.globalSearchCoordinator.reconcileTargets(
                        with: self.worklaneStore.worklanes)
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
            [weak self] paneID, worklaneID, paneIndex, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneToWorklane(
                    paneID: paneID,
                    targetWorklaneID: worklaneID,
                    atPaneIndex: paneIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else if let paneIndex {
                self.worklaneStore.transferPaneToWorklane(
                    paneID: paneID,
                    targetWorklaneID: worklaneID,
                    atPaneIndex: paneIndex,
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
            [weak self] paneID, insertionIndex, isDuplicate in
            guard let self else { return }
            if isDuplicate {
                self.worklaneStore.duplicatePaneToNewWorklane(
                    paneID: paneID,
                    atIndex: insertionIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            } else {
                self.worklaneStore.transferPaneToNewWorklane(
                    paneID: paneID,
                    atIndex: insertionIndex,
                    singleColumnWidth: self.worklaneStore.layoutContext.singlePaneWidth
                )
            }
        }
        appCanvasView.paneStripView.onNewWorklanePlaceholderVisibilityChanged = {
            [weak self] insertionIndex in
            if let insertionIndex {
                self?.sidebarView.showNewWorklanePlaceholder(atIndex: insertionIndex)
            } else {
                self?.sidebarView.hideNewWorklanePlaceholder()
            }
        }
        appCanvasView.paneStripView.onSidebarScrollRequested = { [weak self] delta in
            self?.sidebarView.adjustScrollOffset(by: delta)
        }
        appCanvasView.paneStripView.onSidebarInsertionLineChanged = { [weak self] target in
            guard let self else { return }
            if let target {
                let yInDocument = self.sidebarView.convertYForInsertionLine(target.y, from: self.appCanvasView)
                self.sidebarView.showInsertionLine(
                    SidebarPaneInsertionLineTarget(worklaneID: target.worklaneID, y: yInDocument)
                )
            } else {
                self.sidebarView.hideInsertionLine()
            }
        }
        appCanvasView.paneStripView.sidebarWorklaneFrameProvider = { [weak self] in
            guard let self else { return [] }
            return self.sidebarView.worklaneRowFrames(in: self.appCanvasView)
        }
        appCanvasView.paneStripView.sidebarPaneBoundaryProvider = { [weak self] in
            guard let self else { return [] }
            return self.sidebarView.paneInsertionBoundaries(in: self.appCanvasView)
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
        appCanvasView.paneStripView.rightPaneCommandPresentationProvider = { [weak self] in
            self?.currentPaneLayoutContext.rightPaneCommandPresentation ?? .addsToWorklane
        }
        appCanvasView.paneStripView.moveToWorklaneCatalogProvider = { [weak self] paneID in
            self?.moveToWorklaneCatalogProvider?(paneID)
        }
        appCanvasView.paneStripView.restoredRerunnableCommandProvider = { [weak self] paneID in
            self?.worklaneStore.restoredRerunnableCommand(for: paneID)
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
        sidebarView.onCloseWorklaneRequested = { [weak self] worklaneID in
            guard let self else { return }
            if self.configStore.current.confirmations.confirmBeforeClosingPane,
               let reason = self.worklaneStore.worklaneCloseConfirmationReason(worklaneID)
            {
                self.showCloseWorklaneConfirmation(reason: reason) {
                    self.closeWorklane(id: worklaneID)
                }
            } else {
                self.closeWorklane(id: worklaneID)
            }
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
        sidebarView.onForceSplitRightRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.worklaneStore.send(.splitRightVisibly)
        }
        sidebarView.onForceAddPaneRightRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.worklaneStore.send(.addPaneRightWithoutResizing)
        }
        sidebarView.rightPaneCommandPresentationProvider = { [weak self] in
            self?.currentPaneLayoutContext.rightPaneCommandPresentation ?? .addsToWorklane
        }
        sidebarView.moveToWorklaneCatalogProvider = { [weak self] paneID in
            self?.moveToWorklaneCatalogProvider?(paneID)
        }
        sidebarView.restoredRerunnableCommandProvider = { [weak self] paneID in
            self?.worklaneStore.restoredRerunnableCommand(for: paneID)
        }
        sidebarView.onMovePaneToNewWindowRequested = { [weak self] worklaneID, paneID in
            self?.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self?.onMovePaneToNewWindowRequested?(paneID)
        }
        sidebarView.onRunRestoredCommandRequested = { [weak self] worklaneID, paneID in
            guard let self else { return }
            self.worklaneStore.selectWorklaneAndFocusPane(worklaneID: worklaneID, paneID: paneID)
            self.runLastCommandAgain(in: paneID)
        }
        sidebarView.onWorklaneColorChanged = { [weak self] worklaneID, color in
            self?.worklaneStore.setColor(color, on: worklaneID)
        }
        sidebarView.onWorklaneReorderCommitted = { [weak self] worklaneID, targetIndex in
            self?.worklaneStore.moveWorklane(id: worklaneID, toIndex: targetIndex) ?? false
        }
        sidebarView.onNewWorklaneRequested = { [weak self] in
            self?.handle(.newWorklane)
        }
        sidebarView.onOpenBookmarksPopoverRequested = { [weak self] anchorView in
            self?.toggleBookmarksPopover(anchorView: anchorView)
        }
        sidebarView.onBookmarkAction = { [weak self] worklaneID, action in
            self?.handleSidebarBookmarkAction(worklaneID: worklaneID, action: action)
        }
        sidebarView.bookmarkNameLookup = { [weak self] id in
            self?.bookmarkStore.template(withID: id)?.name
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
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
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
        syncSidebarWidthToAvailableWidth(persist: false, forceLayout: false)
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
            commandPaletteController.onSetWorklaneColor = { [weak self] color in
                guard let self else { return }
                self.worklaneStore.setColor(color, on: self.worklaneStore.activeWorklaneID)
            }
            commandPaletteController.onShowSettingsSection = { [weak self] section in
                self?.onShowSettingsSectionRequested?(section)
            }
            commandPaletteController.onNavigateToPane = { [weak self] worklaneID, paneID in
                self?.navigateToPaneFromCommandPalette(worklaneID: worklaneID, paneID: paneID)
            }
            commandPaletteController.onRunRestoredCommand = { [weak self] paneID in
                self?.runLastCommandAgain(in: paneID)
            }
        }
        syncSidebarWidthToAvailableWidth(persist: false, forceLayout: false)
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

    /// Flatten the rounded shell to match the rectangular fullscreen frame.
    /// The titlebar+toolbar band itself is auto-hidden via
    /// `willUseFullScreenPresentationOptions` on the window delegate, so chrome
    /// constraints stay at their windowed-mode positions.
    func setFullScreenLayout(_ fullScreen: Bool, animated: Bool) {
        guard isFullScreen != fullScreen else { return }
        isFullScreen = fullScreen
        view.layer?.cornerRadius = fullScreen ? 0 : ChromeGeometry.outerWindowRadius
    }

    private func updateToggleButtonConstraints() {
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
    }

    @objc
    private func handleToggleSidebar() {
        sidebarMotionCoordinator.handle(.togglePressed)
        syncSidebarVisibilityControls(animated: true)
    }

    @objc
    private func handlePaneLayoutMenuAction() {
        paneLayoutMenuCoordinator.showMenu(
            worklaneStore: worklaneStore,
            rightPaneCommandPresentation: currentPaneLayoutContext.rightPaneCommandPresentation
        )
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

            if let paneID = FocusedTerminalInterruptBridge.paneIDForUserInterrupt(
                event: event,
                activeWorklane: self.worklaneStore.activeWorklane,
                isFocusedPaneTerminalFocused: self.focusedPaneRuntime()?.hostView.isTerminalFocused == true
            ) {
                self.handleTerminalEvent(paneID: paneID, event: .userInterrupted)
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
            peekController.handleTab(forward: true)
        case .previousWorklane:
            peekController.handleTab(forward: false)
        case .moveWorklaneUp:
            moveActiveWorklane(by: -1)
        case .moveWorklaneDown:
            moveActiveWorklane(by: 1)
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
        case .moveFocusedPaneToNewWindow:
            onMovePaneToNewWindowRequested?(worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        case .navigateBack:
            worklaneStore.navigateBack()
        case .navigateForward:
            worklaneStore.navigateForward()
        case .showCommandPalette:
            showCommandPalette()
        case .showTaskManager:
            NSApp.sendAction(#selector(AppDelegate.showTaskManager(_:)), to: nil, from: nil)
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
        case .openBookmarksPopover:
            toggleBookmarksPopover(anchorView: sidebarView.bookmarksButtonAnchor)
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
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
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
                delta: resolvedVerticalKeyboardResizeDelta(keyboardResizeStep(for: .vertical)),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
            )
        case .resizeDown:
            appCanvasView.settlePaneStripPresentationNow()
            worklaneStore.resizeFocusedPane(
                in: .vertical,
                delta: resolvedVerticalKeyboardResizeDelta(-keyboardResizeStep(for: .vertical)),
                availableSize: appCanvasView.bounds.size,
                minimumSizeByPaneID: paneMinimumSizesByPaneID(),
                animation: .immediate
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
        case .restoreClosedPane:
            performRestoreClosedPane()
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

    private func performRestoreClosedPane() {
        if let result = worklaneStore.restoreClosedPane() {
            showRestoreToast(message: result.toastMessage)
        } else {
            showRestoreToast(message: "No recently closed pane to restore")
        }
    }

    private func showRestoreToast(message: String) {
        pathCopiedToastView?.removeFromSuperview()
        let toast = PathCopiedToastView()
        pathCopiedToastView = toast
        toast.show(message: message, in: appCanvasView, theme: currentTheme)
    }

    private func closeFocusedPane() {
        handlePaneCloseResult(worklaneStore.closeFocusedPane())
    }

    private func closeWorklane(id worklaneID: WorklaneID) {
        guard worklaneStore.worklanes.contains(where: { $0.id == worklaneID }) else {
            return
        }

        worklaneStore.selectWorklane(id: worklaneID)
        worklaneStore.closeActiveWorklane()
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

    private var isShowingCloseConfirmation = false

    private func showClosePaneConfirmation(
        reason: WorklaneStore.PaneCloseReason,
        onConfirm: @escaping () -> Void
    ) {
        let informativeText = switch reason {
        case .runningProcess:
            "The running process in this pane will be terminated."
        case .sessionHistory:
            "This pane's session history will be lost."
        }
        showCloseConfirmation(
            messageText: "Close this pane?",
            informativeText: informativeText,
            confirmButtonTitle: "Close Pane",
            onConfirm: onConfirm
        )
    }

    private func showCloseWorklaneConfirmation(
        reason: WorklaneStore.PaneCloseReason,
        onConfirm: @escaping () -> Void
    ) {
        let informativeText = switch reason {
        case .runningProcess:
            "Running processes in this worklane will be terminated."
        case .sessionHistory:
            "This worklane's session history will be lost."
        }
        showCloseConfirmation(
            messageText: "Close this worklane?",
            informativeText: informativeText,
            confirmButtonTitle: "Close Worklane",
            onConfirm: onConfirm
        )
    }

    private func showCloseConfirmation(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String,
        onConfirm: @escaping () -> Void
    ) {
        guard !isShowingCloseConfirmation else { return }
        isShowingCloseConfirmation = true

        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        let isDark = currentTheme.windowBackground.isDarkThemeColor
        alert.window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        guard let window = view.window else {
            isShowingCloseConfirmation = false
            if alert.runModal() == .alertFirstButtonReturn {
                onConfirm()
            }
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            self?.isShowingCloseConfirmation = false
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
        let focusedRestoredCommand: String? = {
            guard let paneID = activeWorklane?.paneStripState.focusedPaneID else { return nil }
            return worklaneStore.restoredRerunnableCommand(for: paneID)
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
            focusedRestoredCommand: focusedRestoredCommand,
            worklanes: worklaneStore.worklanes,
            currentPaneReference: worklaneStore.currentPaneReferenceForCommandPalette,
            recentPaneReferences: worklaneStore.recentPaneReferencesForCommandPalette,
            openWithTargets: openWithTargets,
            openWithIconProvider: { [weak self] target in
                self?.openWithService.icon(for: target)
            },
            rightPaneCommandPresentation: currentPaneLayoutContext.rightPaneCommandPresentation
        )
    }

    private func navigateToPaneFromCommandPalette(worklaneID: WorklaneID, paneID: PaneID) {
        navigateToPane(worklaneID: worklaneID, paneID: paneID)
        view.layoutSubtreeIfNeeded()
        runtimeRegistry.runtime(for: paneID)?.forceViewportSync()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.runtimeRegistry.runtime(for: paneID)?.forceViewportSync()
            self.runtimeRegistry.runtime(for: paneID)?.hostView.focusTerminalIfReady()
        }
    }

    @discardableResult
    func runLastCommandAgain(in requestedPaneID: PaneID? = nil) -> Bool {
        guard let paneID = requestedPaneID ?? worklaneStore.activeWorklane?.paneStripState.focusedPaneID,
              let command = worklaneStore.restoredRerunnableCommand(for: paneID),
              let runtime = runtimeRegistry.runtime(for: paneID)
        else {
            showCommandFailureToast()
            return false
        }

        if let worklaneID = worklaneID(containing: paneID) {
            navigateToPane(worklaneID: worklaneID, paneID: paneID)
            view.layoutSubtreeIfNeeded()
            runtime.forceViewportSync()
        }

        runtime.adapter.sendText(TerminalCommandSubmission.submittedText(for: command))
        worklaneStore.consumeRestoredRerunnableCommand(for: paneID)

        DispatchQueue.main.async { [weak self] in
            self?.runtimeRegistry.runtime(for: paneID)?.hostView.focusTerminalIfReady()
        }
        return true
    }

    private func showCommandFailureToast() {
        let toast = PathCopiedToastView()
        pathCopiedToastView = toast
        toast.show(message: "Couldn’t run command", in: appCanvasView, theme: currentTheme)
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

    private func moveActiveWorklane(by delta: Int) {
        guard let currentIndex = worklaneStore.worklanes.firstIndex(where: { $0.id == worklaneStore.activeWorklaneID }) else {
            return
        }

        let targetIndex = currentIndex + delta
        guard worklaneStore.moveWorklane(id: worklaneStore.activeWorklaneID, toIndex: targetIndex) else {
            return
        }

        postWorklaneMoveAccessibilityAnnouncement()
    }

    private func postWorklaneMoveAccessibilityAnnouncement() {
        guard let index = worklaneStore.worklanes.firstIndex(where: { $0.id == worklaneStore.activeWorklaneID }) else {
            return
        }

        let worklane = worklaneStore.worklanes[index]
        let name = WorklaneSidebarSummaryBuilder.summary(
            for: worklane,
            isActive: worklane.id == worklaneStore.activeWorklaneID
        ).primaryText
        let message = "Moved \(name) to position \(index + 1) of \(worklaneStore.worklanes.count)"
        NSAccessibility.post(
            element: view as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
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
        ].forEach { name in
            observerBag.addObserver(forName: name, object: window) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWindowStateDidChange()
                }
            }
        }
        observerBag.addObserver(forName: NSWindow.didChangeScreenNotification, object: window) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowStateDidChange(forceViewportSync: true)
            }
        }
        observerBag.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowStateDidChange(forceViewportSync: true)
            }
        }
        windowObserverBag = observerBag
    }

    private func handleWindowStateDidChange(forceViewportSync: Bool = false) {
        if forceViewportSync {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        appCanvasView.cancelPendingPaneStripScrollSwitchGesture()
        syncSidebarWidthToAvailableWidth(persist: false, forceLayout: false)
        _ = updatePaneLayoutContextIfNeeded(force: true)
        if forceViewportSync {
            updatePaneViewportHeight()
            renderCoordinator.renderCanvas(animated: false)
        }
        renderCoordinator.updateSurfaceActivities()
        guard forceViewportSync else {
            return
        }
        forceActiveWorklanePaneViewportSync()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.forceActiveWorklanePaneViewportSync()
        }
    }

    private func forceActiveWorklanePaneViewportSync() {
        guard let worklane = worklaneStore.activeWorklane else {
            return
        }
        for pane in worklane.paneStripState.panes {
            runtimeRegistry.runtime(for: pane.id)?.forceViewportSync()
        }
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
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
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
        let previousFocusedColumnContentMinX = focusedPaneColumnContentMinX()
        worklaneStore.batchUpdate { [self] in
            updatePaneLayoutContextIfNeeded(force: true, leadingVisibleInsetOverride: reservedInset)
        }
        let needsCanvasTransition =
            abs(previousLeadingInset - reservedInset) > 0.001
            || previousWorklaneState != worklaneStore.state
            || previousLayoutContext != currentPaneLayoutContext
        windowChromeView.leadingVisibleInset = reservedInset
        // When the leading inset changes, every column is proportionally
        // rescaled (see `WorklaneStore.readableWidthScaleFactor`) so the
        // focused column's content X shifts. Without compensation the
        // sidebar slide drags middle panes left/right under the user.
        //
        // Preserve the focused column's *proportional* position within the
        // visible lane (distance from lane left ÷ lane width). That keeps a
        // flush-left pane flush-left and a flush-right pane flush-right
        // after the transition, regardless of which column is focused.
        //
        // Skip when the canvas hasn't been sized yet (the first call lands
        // during `viewDidLoad`, before `viewDidLayout` gives us a real
        // viewport — running the formula then would produce a garbage
        // shift that the first real render would then apply).
        let viewportWidth = appCanvasView.bounds.width
        if viewportWidth > 0.001,
            abs(previousLeadingInset - reservedInset) > 0.001,
            let previousMinX = previousFocusedColumnContentMinX,
            let nextMinX = focusedPaneColumnContentMinX()
        {
            let previousLaneWidth = max(1, viewportWidth - previousLeadingInset)
            let nextLaneWidth = max(1, viewportWidth - reservedInset)
            let previousOffset = appCanvasView.currentPaneStripScrollOffset
            let previousScreenLeft = previousMinX - previousOffset
            let relativeInLane = (previousScreenLeft - previousLeadingInset) / previousLaneWidth
            let nextScreenLeft = reservedInset + relativeInLane * nextLaneWidth
            let nextOffset = nextMinX - nextScreenLeft
            let offsetShift = nextOffset - previousOffset
            if abs(offsetShift) > 0.001 {
                appCanvasView.shiftPaneStripTargetOffsetOnNextRender(by: offsetShift)
            }
        }
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
            + LeadingChromeControlsBar.totalWidth
        let pinnedHeaderContentMinX =
            trafficLightAnchor.x
            - leadingConstant
            + SidebarToggleButton.spacingFromTrafficLights
        // Skip the header-layout update when the sidebar will be hidden — the
        // button is about to slide off-screen with the sidebar body, and
        // re-snapping its X/Y offsets to the default (.hidden) values here
        // would cause a visible 1-frame jump before the slide starts.
        if motionState.revealFraction > 0 {
            sidebarView.updateHeaderLayout(
                visibilityMode: sidebarMotionCoordinator.mode,
                pinnedContentMinX: pinnedHeaderContentMinX
            )
        }
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
                self.view.layoutSubtreeIfNeeded()
            }
        } else {
            sidebarLeadingConstraint?.constant = leadingConstant
            toggleLeadingConstraint?.constant = toggleTarget
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

    func containsPane(_ paneID: PaneID) -> Bool {
        worklaneStore.worklanes.contains { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }
    }

    func worklaneID(containing paneID: PaneID) -> WorklaneID? {
        worklaneStore.worklanes.first { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }?.id
    }

    func focusedPaneID() -> PaneID? {
        worklaneStore.activeWorklane?.paneStripState.focusedPaneID
    }

    func canSplitOutPaneToNewWindow(paneID: PaneID) -> Bool {
        worklaneStore.canSplitOutPaneToNewWindow(paneID: paneID)
    }

    func splitOutPaneToNewWindow(
        paneID: PaneID,
        destinationWindowID: WindowID
    ) -> PaneSplitOutResult? {
        worklaneStore.splitOutPaneToNewWindow(
            paneID: paneID,
            destinationWindowID: destinationWindowID
        )
    }

    // MARK: - Pane IPC

    func handlePaneIPCCommand(_ command: PaneCommand) {
        handlePaneCommand(command)
    }

    @discardableResult
    func splitWithLayout(
        placement: PanePlacement,
        isHorizontal: Bool,
        layout: SplitLayoutAction,
        targetPaneID: PaneID? = nil,
        preserveFocusPaneID: PaneID? = nil,
        sessionRequest: TerminalSessionRequest? = nil
    ) -> PaneID? {
        appCanvasView.settlePaneStripPresentationNow()
        return worklaneStore.splitWithLayout(
            placement: placement,
            isHorizontal: isHorizontal,
            layout: layout,
            availableWidth: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset,
            availableSize: appCanvasView.bounds.size,
            minimumSizeByPaneID: paneMinimumSizesByPaneID(),
            targetPaneID: targetPaneID,
            preserveFocusPaneID: preserveFocusPaneID,
            sessionRequest: sessionRequest
        )
    }

    @discardableResult
    func applyGrid(
        sourcePaneID: PaneID,
        rows: Int,
        columns: Int,
        command: String?,
        includeSource: Bool,
        focus: GridFocus
    ) throws -> GridApplicationResult {
        appCanvasView.settlePaneStripPresentationNow()
        return try worklaneStore.applyGrid(
            sourcePaneID: sourcePaneID,
            rows: rows,
            columns: columns,
            command: command,
            includeSource: includeSource,
            focus: focus
        )
    }

    @discardableResult
    func createWorklaneForGrid() -> WorklaneID {
        worklaneStore.createWorklane()
    }

    func gridWindowWorkspaceState(
        inheritingFrom sourcePaneID: PaneID,
        destinationWindowID: WindowID
    ) -> WindowWorkspaceState? {
        worklaneStore.gridWindowWorkspaceState(
            inheritingFrom: sourcePaneID,
            destinationWindowID: destinationWindowID
        )
    }

    func focusPaneByID(_ paneID: PaneID, in worklaneID: WorklaneID) {
        worklaneStore.selectWorklane(id: worklaneID)
        worklaneStore.focusPane(id: paneID)
    }

    func closePaneByID(_ paneID: PaneID) {
        handlePaneCloseResult(worklaneStore.closePane(id: paneID))
    }

    @discardableResult
    func launchDeferredPane(id paneID: PaneID, nativeCommand: String) -> Bool {
        worklaneStore.launchDeferredPane(id: paneID, nativeCommand: nativeCommand)
    }

    @discardableResult
    func setPaneTitle(id paneID: PaneID, title: String) -> Bool {
        worklaneStore.setPaneTitle(id: paneID, title: title)
    }

    @discardableResult
    func setWorklaneColor(_ color: WorklaneColor?, on id: WorklaneID) -> Bool {
        worklaneStore.setColor(color, on: id)
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

    func resizeColumnContainingPane(id paneID: PaneID, toFraction fraction: CGFloat) {
        appCanvasView.settlePaneStripPresentationNow()
        worklaneStore.resizeColumnContainingPane(
            id: paneID,
            toFraction: fraction,
            availableWidth: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
    }

    func columnWidthForPane(id paneID: PaneID, in worklaneID: WorklaneID) -> CGFloat? {
        worklaneStore.columnWidthForPane(id: paneID, in: worklaneID)
    }

    func resizeColumnContainingPaneToWidth(id paneID: PaneID, width: CGFloat) {
        appCanvasView.settlePaneStripPresentationNow()
        let availableWidth = appCanvasView.bounds.width
        let leadingVisibleInset = appCanvasView.leadingVisibleInset
        appCanvasView.centerFocusedInteriorPaneOnNextRender()
        let didResize = worklaneStore.resizeColumnContainingPanePreservingNeighbors(
            id: paneID,
            toWidth: width,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: paneMinimumSizesByPaneID()
        )
        if !didResize {
            appCanvasView.clearPendingPaneStripTargetOffsetOverride()
        }
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
                entries.append(
                    PaneListEntry(
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

    func taskManagerPaneSources(windowID: WindowID, windowTitle: String) -> [TaskManagerPaneSource] {
        worklaneStore.worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map { pane in
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                return TaskManagerPaneSource(
                    windowID: windowID,
                    windowTitle: windowTitle,
                    worklaneID: worklane.id,
                    worklaneTitle: worklane.title,
                    paneID: pane.id,
                    paneTitle: auxiliaryState?.presentation.visibleIdentityText ?? pane.title,
                    statusText: taskManagerStatusText(for: auxiliaryState),
                    rootPID: auxiliaryState?.raw.paneRootPID,
                    isRemote: auxiliaryState?.shellContext?.scope == .remote,
                    currentWorkingDirectory: PaneTerminalLocationResolver.snapshot(
                        metadata: auxiliaryState?.metadata,
                        shellContext: auxiliaryState?.shellContext,
                        requestWorkingDirectory: pane.sessionRequest.workingDirectory
                    ).workingDirectory
                )
            }
        }
    }

    private func taskManagerStatusText(for auxiliaryState: PaneAuxiliaryState?) -> String? {
        if let agentStatus = auxiliaryState?.agentStatus {
            return "\(agentStatus.tool.displayName) \(agentStatus.state.rawValue)"
        }

        switch auxiliaryState?.shellActivityState {
        case .commandRunning:
            return "Running"
        case .promptIdle:
            return "Idle"
        case .unknown, nil:
            return nil
        }
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
            paneLayoutMenuCoordinator.makeMenu(
                worklaneStore: worklaneStore,
                rightPaneCommandPresentation: currentPaneLayoutContext.rightPaneCommandPresentation
            ).items
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
            paneLayoutMenuCoordinator.makeMenu(
                worklaneStore: worklaneStore,
                rightPaneCommandPresentation: currentPaneLayoutContext.rightPaneCommandPresentation
            ).items
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

    private func syncSidebarWidthToAvailableWidth(
        persist: Bool,
        forceLayout: Bool = true
    ) {
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
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: forceLayout
        )
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
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
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

        let barMaxXInRoot = leadingChromeControlsBar.frame.maxX
        let barMaxXInChrome = windowChromeView.convert(
            NSPoint(x: barMaxXInRoot, y: 0),
            from: view
        ).x
        windowChromeView.leadingControlsInset = barMaxXInChrome
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

    private func refreshShortcutTooltips() {
        sidebarToggleButton.updateShortcutTooltip(shortcutManager)
        paneNavigationButtons.updateShortcutTooltips(shortcutManager)
        sidebarView.updateShortcutTooltips(shortcutManager)
        windowChromeView.updateShortcutTooltips(shortcutManager)
        globalSearchHUDView.updateShortcutTooltips(shortcutManager)
        runtimeRegistry.updateShortcutTooltips(shortcutManager)
        appCanvasView.updateShortcutTooltips(shortcutManager)
    }

    private func applyPersistedConfig(_ config: AppConfig) {
        let appearanceDidChange = config.appearance != lastAppliedAppearanceSettings
        lastAppliedAppearanceSettings = config.appearance
        paneLayoutPreferences = config.paneLayout
        shortcutManager = ShortcutManager(shortcuts: config.shortcuts)
        paneLayoutMenuCoordinator.updateShortcutManager(shortcutManager)
        refreshShortcutTooltips()
        preloadOpenWithIcons()
        sidebarMotionCoordinator.applyPersistedSidebarSettings(
            config.sidebar,
            availableWidth: resolvedSidebarAvailableWidth()
        )
        sidebarWidthConstraint?.constant = sidebarMotionCoordinator.currentSidebarWidth
        syncSidebarVisibilityControls(animated: false)
        applySidebarMotionState(
            sidebarMotionCoordinator.currentMotionState,
            animated: false,
            forceLayout: false
        )
        updatePaneLayoutContextIfNeeded(force: true)
        renderCoordinator.render()
        updateOpenWithChromeState()
        syncAgentCaffeinationState()

        if appearanceDidChange {
            themeCoordinator.refreshTheme(for: view.effectiveAppearance, animated: true)
        }
    }

    private func syncAgentCaffeinationState() {
        agentCaffeinationController.setSource(
            id: windowID,
            enabled: configStore.current.agentCaffeination.enabled,
            hasRunningAgent: worklaneStore.hasRunningAgentPane
        )
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

    private func focusedPaneColumnContentMinX() -> CGFloat? {
        guard let worklane = worklaneStore.activeWorklane,
            let focusedPaneID = worklane.paneStripState.focusedPaneID
        else {
            return nil
        }
        return worklane.paneStripState.columnContentMinX(forPaneID: focusedPaneID)
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

// MARK: - Bookmarks popover

private extension RootViewController {
    func toggleBookmarksPopover(anchorView: NSView) {
        if let existing = bookmarksPopover, existing.isShown {
            existing.close()
            return
        }

        // If a previous popover is mid-close, drop its observer and slot before
        // creating the new one so the old close notification doesn't sweep the
        // new popover's bookkeeping.
        if let token = bookmarksPopoverObserverToken {
            NotificationCenter.default.removeObserver(token)
            bookmarksPopoverObserverToken = nil
        }
        bookmarksPopover = nil

        let popover = NSPopover()
        popover.behavior = .transient
        let contentController = makeBookmarksPopoverContentController(popover: popover)
        popover.contentViewController = contentController
        popover.contentSize = contentController.preferredContentSize
        anchorView.layoutSubtreeIfNeeded()
        popover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxY
        )
        sidebarView.setBookmarksPopoverPresented(true)
        bookmarksPopover = popover
        bookmarksPopoverObserverToken = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self, weak popover] _ in
            guard let self, let popover, self.bookmarksPopover === popover else {
                return
            }
            self.sidebarView.setBookmarksPopoverPresented(false)
            if let token = self.bookmarksPopoverObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
            self.bookmarksPopoverObserverToken = nil
            self.bookmarksPopover = nil
        }
    }

    func makeBookmarksPopoverContentController(popover: NSPopover) -> NSViewController {
        let viewModel = BookmarksPopoverViewModel(
            store: bookmarkStore,
            canSaveCurrentWorklane: { [weak self] in
                self?.worklaneStore.focusedWorklaneSnapshot != nil
            },
            onActivate: { [weak self] template in
                self?.activateBookmarkTemplate(template)
            },
            onSaveCurrentWorklane: { [weak self] kind in
                self?.beginBookmarkSave(kind: kind, originID: nil)
            },
            onImportPreset: { [weak self] in
                self?.beginImportPreset()
            },
            onDismiss: { [weak popover] in
                popover?.performClose(nil)
            },
            onTemplateMenuAction: { [weak self] action, template in
                self?.handleBookmarkTemplateMenuAction(action, template: template)
            }
        )
        let host = NSHostingController(rootView: BookmarksPopoverView(viewModel: viewModel))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // Give NSPopover a stable, bounded size BEFORE show() — otherwise the
        // SwiftUI fitting-size dance can place the arrow far below the anchor.
        host.preferredContentSize = NSSize(
            width: BookmarksPopoverMetrics.contentWidth,
            height: BookmarksPopoverMetrics.preferredHeight(forEmpty: bookmarkStore.templates.isEmpty)
        )
        return host
    }

    func activateBookmarkTemplate(_ template: WorkspaceTemplate) {
        let result = worklaneStore.applyTemplate(template)
        if !result.fallbacks.isEmpty {
            presentBookmarkRestoreFallbacks(result.fallbacks, for: result.worklane)
        }
    }

    /// Called from the empty-state primary button and (Phase 5) the worklane context menu.
    /// Opens the save sheet pre-filled from the focused worklane.
    func beginBookmarkSave(kind: WorkspaceTemplate.Kind, originID: UUID?) {
        guard let worklane = worklaneStore.focusedWorklaneSnapshot else { return }
        presentBookmarkSaveSheet(
            forWorklane: worklane,
            initialKind: kind,
            existingTemplateID: originID
        )
    }

    func handleBookmarkTemplateMenuAction(
        _ action: BookmarksPopoverViewModel.TemplateAction,
        template: WorkspaceTemplate
    ) {
        switch action {
        case .togglePin:
            bookmarkStore.setPinned(id: template.id, pinned: !template.pinned)
        case .delete:
            confirmDeleteBookmark(template)
        case .duplicate:
            _ = bookmarkStore.duplicate(id: template.id)
        case .rename:
            beginRenameBookmarkTemplate(template)
        case .edit:
            presentBookmarkSaveSheet(editing: template)
        case .convert:
            convertBookmarkTemplate(template)
        case .revealInFinder:
            revealBookmarkRoot(template)
        case .exportAsPreset:
            exportBookmarkTemplate(template)
        }
    }

    private func confirmDeleteBookmark(_ template: WorkspaceTemplate) {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(template.name)\u{201D}?"
        alert.informativeText = template.kind == .bookmark
            ? "This bookmark will be removed from the popover. Active worklanes opened from it remain unaffected."
            : "This preset will be removed from the popover."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let confirmed: Bool
        if let window = view.window {
            // beginSheetModal would return immediately while running async, so
            // use the synchronous runModal path here for simplicity. The alert
            // is short-lived and blocking is acceptable for a destructive
            // confirmation.
            confirmed = alert.runModal() == .alertFirstButtonReturn
            _ = window
        } else {
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        bookmarkStore.delete(id: template.id)
    }

    private func beginRenameBookmarkTemplate(_ template: WorkspaceTemplate) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(template.name)\u{201D}"
        alert.alertStyle = .informational
        let textField = NSTextField(string: template.name)
        textField.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.bookmarkStore.rename(id: template.id, to: textField.stringValue)
        }
    }

    private func convertBookmarkTemplate(_ template: WorkspaceTemplate) {
        switch template.kind {
        case .bookmark:
            var copy = template.strippingWorkingDirectories()
            copy.id = UUID()
            copy.name = preset(name: template.name)
            copy.createdAt = Date()
            copy.updatedAt = Date()
            copy.pinned = false
            copy.lastUsedAt = nil
            bookmarkStore.upsert(copy)
        case .preset:
            // Phase 4 will host the save sheet that captures cwds from the focused worklane.
            // For now, take focused worklane's panes' cwds as the binding target.
            guard let worklane = worklaneStore.focusedWorklaneSnapshot else { return }
            let captured = captureWorkspaceTemplate(
                worklane: worklane,
                kind: .bookmark,
                name: bookmark(name: template.name)
            )
            var bound = captured
            bound.id = UUID()
            bound.color = template.color
            bookmarkStore.upsert(bound)
        }
    }

    private func preset(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled preset" : "\(trimmed) (preset)"
    }

    private func bookmark(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled bookmark" : "\(trimmed) (bookmark)"
    }

    private func revealBookmarkRoot(_ template: WorkspaceTemplate) {
        let path = template.projectRoot ?? template.allPanes.compactMap(\.workingDirectory).first
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func presentBookmarkPersistError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save bookmarks"
        alert.informativeText = "Zentty couldn't write to ~/.config/zentty/bookmarks.json: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func beginImportPreset() {
        guard let window = view.window else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = []
        openPanel.message = "Select a .\(WorkspaceTemplateExporter.fileExtension) file to import."
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            do {
                let template = try WorkspaceTemplateExporter.read(from: url)
                self?.bookmarkStore.upsert(template)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func exportBookmarkTemplate(_ template: WorkspaceTemplate) {
        guard let window = view.window else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = []
        savePanel.nameFieldStringValue = "\(template.name).\(WorkspaceTemplateExporter.fileExtension)"
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try WorkspaceTemplateExporter.write(template, to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    func presentBookmarkSaveSheet(
        forWorklane worklane: WorklaneState,
        initialKind: WorkspaceTemplate.Kind,
        existingTemplateID: UUID?
    ) {
        let existing = existingTemplateID.flatMap { bookmarkStore.template(withID: $0) }
        let initialTemplate: WorkspaceTemplate
        if let existing {
            initialTemplate = existing
        } else {
            let suggestedName = BookmarkNameSuggester.suggest(
                for: worklane,
                kind: initialKind
            )
            initialTemplate = captureWorkspaceTemplate(
                worklane: worklane,
                kind: initialKind,
                name: suggestedName
            )
        }
        BookmarkSaveSheetController.present(
            in: view.window,
            initialTemplate: initialTemplate,
            isUpdatingExisting: existing != nil,
            onSave: { [weak self] saved in
                self?.bookmarkStore.upsert(saved)
            }
        )
    }

    func presentBookmarkSaveSheet(editing template: WorkspaceTemplate) {
        BookmarkSaveSheetController.present(
            in: view.window,
            initialTemplate: template,
            isUpdatingExisting: true,
            onSave: { [weak self] saved in
                self?.bookmarkStore.upsert(saved)
            }
        )
    }

    func presentBookmarkRestoreFallbacks(
        _ fallbacks: [WorkspaceTemplateImporter.Fallback],
        for worklane: WorklaneState
    ) {
        BookmarkRestoreLogger.shared.logFallbacks(fallbacks, worklaneID: worklane.id)
        let banner = BookmarkRestoreBannerView(
            fallbackCount: fallbacks.count,
            onEdit: { [weak self] in
                guard let template = worklane.bookmarkOriginID
                    .flatMap({ self?.bookmarkStore.template(withID: $0) }) else {
                    return
                }
                self?.presentBookmarkSaveSheet(editing: template)
            }
        )
        banner.present(over: appCanvasView)
    }

    func handleSidebarBookmarkAction(
        worklaneID: WorklaneID,
        action: SidebarBookmarkRowAction
    ) {
        guard let worklane = worklaneStore.snapshot(of: worklaneID) else { return }
        switch action {
        case .bookmark:
            presentBookmarkSaveSheet(forWorklane: worklane, initialKind: .bookmark, existingTemplateID: nil)
        case .saveAsPreset:
            presentBookmarkSaveSheet(forWorklane: worklane, initialKind: .preset, existingTemplateID: nil)
        case .saveAsNewBookmark:
            presentBookmarkSaveSheet(forWorklane: worklane, initialKind: .bookmark, existingTemplateID: nil)
        case .updateBookmark(let templateID):
            silentlyUpdateBookmark(templateID: templateID, from: worklane)
        case .editBookmark(let templateID):
            guard let existing = bookmarkStore.template(withID: templateID) else { return }
            presentBookmarkSaveSheet(editing: existing)
        case .unlink:
            worklaneStore.setBookmarkOrigin(nil, on: worklaneID)
        }
    }

    private func silentlyUpdateBookmark(templateID: UUID, from worklane: WorklaneState) {
        guard let existing = bookmarkStore.template(withID: templateID) else { return }
        let captured = captureWorkspaceTemplate(
            worklane: worklane,
            kind: existing.kind,
            name: existing.name
        )
        var updated = captured
        updated.id = existing.id
        updated.name = existing.name
        updated.color = worklane.color?.rawValue ?? existing.color
        updated.pinned = existing.pinned
        updated.createdAt = existing.createdAt
        updated.lastUsedAt = existing.lastUsedAt
        updated.updatedAt = Date()

        // Preserve user-edited commands from the existing template per-pane.
        var preservedCommandsByPaneID: [String: String?] = [:]
        for pane in existing.allPanes where pane.wasUserEdited {
            preservedCommandsByPaneID[pane.id] = pane.command
        }
        updated.columns = updated.columns.map { column in
            var column = column
            column.panes = column.panes.map { pane in
                var pane = pane
                if let preserved = preservedCommandsByPaneID[pane.id] {
                    pane.command = preserved
                    pane.wasUserEdited = true
                }
                return pane
            }
            return column
        }
        bookmarkStore.upsert(updated)
    }

    private func captureWorkspaceTemplate(
        worklane: WorklaneState,
        kind: WorkspaceTemplate.Kind,
        name: String
    ) -> WorkspaceTemplate {
        let sampler = TaskManagerProcessSampler()
        return WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: kind,
            name: name,
            processTreeProvider: { rootPID in
                sampler.sample(rootPID: rootPID)
            }
        )
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

// MARK: - Visual Worklane Switcher

extension RootViewController: WorklanePeekControllerDelegate {

    func peekDidArm(_ controller: WorklanePeekController) {
        // Once armed, route subsequent Tab / Shift-Tab / Escape / Ctrl-release
        // through the local key monitor so the menu doesn't keep firing
        // selectNextWorklane on each subsequent tap.
        peekKeyMonitor.install()
    }

    func peekDidOpen(_ controller: WorklanePeekController) {
        let initialSelection: WorklaneStore.PaneReference? = {
            if case let .peeking(selection, _) = controller.phase {
                return selection.current
            }
            return nil
        }()
        let initialHighlight = initialSelection?.paneID
        updatePeekSidebarFocusOverride(initialSelection)

        // The active worklane stays at its canonical zoom scale even when
        // neighbors are present — partial clipping of ±1 carriers above /
        // below the canvas is fine; the camera pan will bring the chosen
        // lane fully into view as the user Ctrl-Tabs further.
        let zoomScale: CGFloat = PaneStripView.zoomScale

        appCanvasView.paneStripView.beginPeekZoomOut(
            animated: true,
            centerOnPaneID: initialHighlight
        )
        peekView.attach(paneStripView: appCanvasView.paneStripView)
        peekView.isHidden = false
        // Force layout so the overlay's bounds reflect AppCanvasView's frame
        // before we compute the HUD position from those bounds.
        peekView.layoutSubtreeIfNeeded()
        peekView.placeHUDStably(
            targetZoomScale: zoomScale,
            visibleLeadingInset: appCanvasView.leadingVisibleInset
        )

        // Build live carriers for the ±1 neighbor worklanes so the user has
        // a spatial sense of "what's around" while Tab cycling. Pass the
        // canvas size + zoom scale so neighbor strips render at identical
        // dimensions and Ghostty allocates the same terminal cells.
        let allWorklanes = worklaneStore.worklanes
        if let activeIndex = allWorklanes.firstIndex(where: { $0.id == worklaneStore.activeWorklaneID }) {
            peekView.configureNeighborLanes(
                worklanes: allWorklanes,
                activeIndex: activeIndex,
                canvasSize: appCanvasView.bounds.size,
                zoomScale: zoomScale,
                runtimeRegistry: runtimeRegistry,
                theme: currentTheme
            )
        }

        refreshPeekOverlay()
    }

    func peekDidUpdateSelection(
        _ controller: WorklanePeekController,
        transition: WorklanePeekSelectionTransition
    ) {
        guard case let .peeking(selection, _) = controller.phase else {
            updatePeekSidebarFocusOverride(nil)
            refreshPeekOverlay()
            return
        }
        updatePeekSidebarFocusOverride(selection.current)

        let animated = transition == .animated
        let originalActiveID = worklaneStore.activeWorklaneID
        let inOriginalActiveLane = selection.current.worklaneID == originalActiveID

        // Pan/create the target lane before horizontal centering. Neighbor
        // carriers are lazy, so centering first can no-op when the user
        // crosses into a not-yet-mounted worklane.
        peekView.centerOn(
            worklaneID: selection.current.worklaneID,
            animated: animated
        )

        if inOriginalActiveLane {
            // The selected pane lives in the lane the underlying anchor
            // strip is bound to — center horizontally on it.
            appCanvasView.paneStripView.centerPeekOnPane(
                selection.current.paneID,
                animated: animated
            )
        } else {
            // The selected pane lives in a neighbor carrier — ask the
            // overlay to center that carrier on the pane.
            peekView.centerHorizontally(
                paneID: selection.current.paneID,
                animated: animated
            )
        }

        refreshPeekOverlay()
    }

    func peekDidClose(_ controller: WorklanePeekController) {
        updatePeekSidebarFocusOverride(nil)
        // Pass the just-committed pane as diagnostic context; the zoom-in
        // itself lands on the pane strip's neutral horizontal origin.
        let committedPaneID = worklaneStore.activeWorklane?.paneStripState.focusedPaneID
        TerminalViewportDiagnostics.shared.record(
            .rootPeekDidClose,
            context: TerminalViewportDiagnostics.Context(
                paneID: committedPaneID,
                worklaneID: worklaneStore.activeWorklaneID,
                laneRole: .activeCanvas
            )
        )
        appCanvasView.paneStripView.configureViewportDiagnostics(
            worklaneID: worklaneStore.activeWorklaneID,
            laneRole: .activeCanvas
        )
        appCanvasView.paneStripView.endPeekZoomIn(
            animated: true,
            centerOnPaneID: committedPaneID
        )
        peekView.isHidden = true
        peekView.detach()
        peekKeyMonitor.uninstall()
    }

    private func updatePeekSidebarFocusOverride(_ reference: WorklaneStore.PaneReference?) {
        let nextOverride = reference.map {
            WorklaneSidebarFocusOverride(worklaneID: $0.worklaneID, paneID: $0.paneID)
        }
        guard peekSidebarFocusOverride != nextOverride else {
            return
        }

        peekSidebarFocusOverride = nextOverride
        renderCoordinator.renderSidebar()
    }

    private func refreshPeekOverlay() {
        guard case let .peeking(selection, _) = peekController.phase else { return }
        let content = peekHUDContent(for: selection.current)
        // Layout out the canvas first so livePaneFrame is stable.
        appCanvasView.layoutSubtreeIfNeeded()
        peekView.update(
            highlightedPaneID: selection.current.paneID,
            hudContent: content
        )
    }

    private func peekHUDContent(
        for ref: WorklaneStore.PaneReference
    ) -> WorklanePeekHUDView.Content {
        guard let worklane = worklaneStore.worklanes.first(where: { $0.id == ref.worklaneID }),
              let context = worklane.paneContext(for: ref.paneID)
        else {
            return .init()
        }
        let presentation = context.presentation
        let proctitle: String? = {
            if let tool = presentation.recognizedTool { return tool.displayName }
            let trimmed = presentation.rememberedTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
        let folder: String? = presentation.cwd.flatMap { path in
            let last = (path as NSString).lastPathComponent
            return last.isEmpty ? nil : last
        }
        let branch: String? = {
            let trimmed = presentation.branchDisplayText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
        return WorklanePeekHUDView.Content(
            proctitle: proctitle,
            folder: folder,
            branch: branch
        )
    }
}
