import AppKit

enum ServerMenuOrdering {
    static func sortedForDisplay(_ servers: [DetectedServer]) -> [DetectedServer] {
        servers.sorted { lhs, rhs in
            let displayComparison = lhs.display.localizedStandardCompare(rhs.display)
            if displayComparison != .orderedSame {
                return displayComparison == .orderedAscending
            }

            let originComparison = lhs.origin.localizedStandardCompare(rhs.origin)
            if originComparison != .orderedSame {
                return originComparison == .orderedAscending
            }

            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}

enum WindowDragSuppressionTarget: Equatable {
    case globalSearchControls
    case proxyIcon
}

@MainActor
protocol ProxyWindowDragSuppressionControlling: AnyObject {
    var isProxyWindowDragSuppressionActive: Bool { get }
    func restoreProxySuppression()
}

@MainActor
private final class ProxyAwareWindow: NSWindow, ProxyWindowDragSuppressionControlling {
    var suppressionTargetAtPoint: ((NSPoint, NSEvent.EventType) -> WindowDragSuppressionTarget?)?
    var proxyMouseDownHandler: ((NSEvent) -> Void)?
    var isProxyWindowDragSuppressionActive: Bool { armedSuppressionTarget != nil }

    private var previousMovableState: Bool?
    private var armedSuppressionTarget: WindowDragSuppressionTarget?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            maybeSuppressWindowDragging(for: event)
        case .leftMouseUp:
            break
        default:
            break
        }

        super.sendEvent(event)

        switch event.type {
        case .leftMouseDown:
            if armedSuppressionTarget == .proxyIcon, let handler = proxyMouseDownHandler {
                handler(event)
            }
        case .leftMouseUp:
            restoreWindowDraggingIfNeeded()
        default:
            break
        }
    }

    func restoreProxySuppression() {
        restoreWindowDraggingIfNeeded()
    }

    private func maybeSuppressWindowDragging(for event: NSEvent) {
        guard armedSuppressionTarget == nil else {
            return
        }
        guard let suppressionTarget = suppressionTargetAtPoint?(event.locationInWindow, event.type) else {
            return
        }

        armedSuppressionTarget = suppressionTarget
        previousMovableState = isMovable
        if isMovable {
            isMovable = false
        }
    }

    private func restoreWindowDraggingIfNeeded() {
        defer {
            previousMovableState = nil
            armedSuppressionTarget = nil
        }

        guard let previousMovableState else {
            return
        }
        if isMovable != previousMovableState {
            isMovable = previousMovableState
        }
    }

    @discardableResult
    func handleProxySuppressionEventForTesting(
        location: NSPoint,
        eventType: NSEvent.EventType,
        invokeProxyHandler: Bool = false
    ) -> Bool {
        let event = NSEvent.mouseEvent(
            with: eventType,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        var didInvokeProxyHandler = false
        switch eventType {
        case .leftMouseDown, .leftMouseDragged:
            if let event {
                maybeSuppressWindowDragging(for: event)
                if eventType == .leftMouseDown,
                   armedSuppressionTarget == .proxyIcon,
                   invokeProxyHandler,
                   let handler = proxyMouseDownHandler {
                    handler(event)
                    didInvokeProxyHandler = true
                }
            }
        case .leftMouseUp:
            restoreWindowDraggingIfNeeded()
        default:
            break
        }

        return didInvokeProxyHandler
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private enum Layout {
        static let initialMinimumSize = NSSize(width: 960, height: 600)
        static let screenInset = CGSize(width: 48, height: 40)
        static let widthRatio: CGFloat = 0.92
        static let heightRatio: CGFloat = 0.9
    }

    private enum OpenWithMenuContent {
        static let emptyStateTitle = "No enabled installed apps"
        static let settingsTitle = "Choose Apps…"
    }

    private enum ServerMenuContent {
        static let emptyStateTitle = "No detected servers"
        static let copyURLTitle = "Copy URL"
        static let settingsTitle = "Dev Server Settings…"
        static let manageTitle = "Manage Servers…"
        static let hiddenTitle = "Hidden…"
        static func ignorePortTitle(_ port: Int) -> String { "Ignore port \(port)" }
        static func stopIgnoringPortTitle(_ port: Int) -> String { "Stop ignoring port \(port)" }
        static func ignoredPortHint(_ port: Int) -> String { "Ignored port \(port)" }
    }

    private static func isPreferredServerBrowser(_ browser: ServerBrowserTarget, preferredBrowserID: String) -> Bool {
        ServerBrowserCatalog.preferenceMatchesTarget(preferredBrowserID, target: browser)
    }

    private static var isHostedTestMode: Bool {
        CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    let window: NSWindow
    let windowID: WindowID
    let windowOrder: Int
    private let rootViewController: RootViewController
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private let openWithService: OpenWithServing
    private let serverOpenService: ServerOpening
    private var settingsWindowController: SettingsWindowController?
    private let windowedToolbar: NSToolbar
    private let closeTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.close")
    private let miniTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.mini")
    private let zoomTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.zoom")
    private var isApplicationActive = true
    private var isWindowKey = true
    private var shouldBypassNextCloseConfirmation = false
    var onWindowDidClose: ((MainWindowController) -> Void)?
    var onWindowAppearanceDidChange: ((NSAppearance?, ZenttyTheme) -> Void)?
    var onCheckForUpdatesRequested: (() -> Void)?
    var onNavigateToNotificationRequested: ((WindowID, WorklaneID, PaneID) -> Void)?
    var onMovePaneToNewWindowRequested: ((MainWindowController, PaneID?) -> Void)?
    var onMovePaneToWorklaneRequested: ((MainWindowController, MovePaneToWorklaneRequest) -> Void)?
    var onMovePaneToNewWorklaneInThisWindowRequested: ((MainWindowController, PaneID) -> Void)?
    var moveToWorklaneCatalogProvider: ((MainWindowController, PaneID) -> WorklaneDestinationCatalog?)?
    var onWorkspaceStateDidChange: (() -> Void)?

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        configStore: AppConfigStore? = nil,
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        notificationStore: NotificationStore = NotificationStore(),
        openWithService: OpenWithServing = OpenWithService(),
        serverOpenService: ServerOpening = ServerOpenService(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        windowIndex: Int = 0,
        initialPaneLayoutFrame: NSRect? = nil,
        initialWorkspaceState: WindowWorkspaceState? = nil
    ) {
        let resolvedConfigStore = configStore ?? AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.MainWindowController"),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )
        let initialWindowFrame = Self.defaultFrame()
        let initialLayoutFrame = initialPaneLayoutFrame ?? initialWindowFrame
        let initialLayoutContext = Self.initialPaneLayoutContext(
            initialFrame: initialLayoutFrame,
            config: resolvedConfigStore.current
        )

        let rootViewController = RootViewController(
            windowID: windowID,
            configStore: resolvedConfigStore,
            appUpdateStateStore: appUpdateStateStore,
            openWithService: openWithService,
            serverOpenService: serverOpenService,
            runtimeRegistry: runtimeRegistry,
            notificationStore: notificationStore,
            initialLayoutContext: initialLayoutContext,
            initialWorkspaceState: initialWorkspaceState
        )
        rootViewController.loadViewIfNeeded()
        let window = ProxyAwareWindow(
            contentRect: initialWindowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Zentty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Attaching an empty toolbar bumps the native window corner radius on macOS Tahoe
        // from the titlebar-only ~16pt up to the toolbar-window 26pt, which matches our
        // ChromeGeometry.outerWindowRadius exactly. No visible toolbar chrome (empty + transparent).
        // Detached in fullscreen so the auto-hiding reveal band stays titlebar-sized.
        let toolbar = NSToolbar(identifier: "be.zenjoy.Zentty.MainToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        self.windowedToolbar = toolbar
        window.isOpaque = false
        // Starts transparent; RootViewController.apply(theme:) syncs the real theme color
        // into window.backgroundColor so the rounded-corner shadow halo composites against
        // the shell fill instead of nothing (which is what produces the white seam).
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        rootViewController.view.frame = NSRect(origin: .zero, size: initialWindowFrame.size)
        rootViewController.view.autoresizingMask = [.width, .height]
        window.contentView = rootViewController.view
        if !Self.isHostedTestMode {
            window.setFrameAutosaveName(Self.windowFrameAutosaveName(forWindowIndex: windowIndex))
        }

        self.rootViewController = rootViewController
        self.windowID = windowID
        self.windowOrder = windowIndex
        self.runtimeRegistry = runtimeRegistry
        self.configStore = resolvedConfigStore
        self.openWithService = openWithService
        self.serverOpenService = serverOpenService
        self.window = window
        super.init()
        window.delegate = self
        rootViewController.onWindowChromeNeedsUpdate = { [weak self] in
            self?.syncWindowAppearance()
            self?.updateTrafficLightAppearance()
        }
        rootViewController.onOpenWithPrimaryRequested = { [weak self] in
            self?.performOpenWithPrimaryAction()
        }
        rootViewController.onOpenWithMenuRequested = { [weak self] in
            self?.showOpenWithMenu()
        }
        rootViewController.onServerPrimaryRequested = { [weak self] in
            self?.performServerPrimaryAction()
        }
        rootViewController.onServerMenuRequested = { [weak self] in
            self?.showServerMenu()
        }
        rootViewController.onShowSettingsRequested = { [weak self] in
            self?.showSettingsWindow(section: .general, sender: nil)
        }
        rootViewController.onShowSettingsSectionRequested = { [weak self] section in
            self?.showSettingsWindow(section: section, sender: nil)
        }
        rootViewController.onCheckForUpdatesRequested = { [weak self] in
            self?.onCheckForUpdatesRequested?()
        }
        rootViewController.onNavigateToNotificationRequested = { [weak self] windowID, worklaneID, paneID in
            self?.onNavigateToNotificationRequested?(windowID, worklaneID, paneID)
        }
        rootViewController.onMovePaneToNewWindowRequested = { [weak self] paneID in
            guard let self else { return }
            self.onMovePaneToNewWindowRequested?(self, paneID)
        }
        rootViewController.moveToWorklaneCatalogProvider = { [weak self] paneID in
            guard let self else { return nil }
            return self.moveToWorklaneCatalogProvider?(self, paneID)
        }
        rootViewController.onCloseWindowRequested = { [weak self] in
            self?.closeWindowBypassingConfirmation()
        }
        rootViewController.onWorkspaceStateDidChange = { [weak self] in
            self?.onWorkspaceStateDidChange?()
        }
        window.suppressionTargetAtPoint = { [weak rootViewController] point, eventType in
            rootViewController?.windowDragSuppressionTarget(at: point, eventType: eventType)
        }
        window.proxyMouseDownHandler = { [weak rootViewController] event in
            rootViewController?.deliverProxyMouseDown(event)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showWindow(_ sender: Any?) {
        isWindowKey = true
        if !window.isVisible, window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            // No saved frame — cascade from the current key window if one exists.
            if let keyWindow = NSApp.keyWindow, keyWindow !== window {
                let cascaded = keyWindow.cascadeTopLeft(from: .zero)
                window.cascadeTopLeft(from: cascaded)
            }
        }
        window.makeKeyAndOrderFront(sender)
        rootViewController.view.needsLayout = true
        rootViewController.view.layoutSubtreeIfNeeded()
        syncWindowAppearance()
        layoutTrafficLights()
        rootViewController.activateWindowBindingsIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldBypassNextCloseConfirmation {
            shouldBypassNextCloseConfirmation = false
            return true
        }

        let appDelegate = NSApp.delegate as? AppDelegate
        let isLastWindow = (appDelegate?.windowControllerCount ?? 1) <= 1
        // When this is the last window, applicationShouldTerminate handles confirmation — skip here to avoid double-prompt.
        guard !isLastWindow,
              configStore.current.confirmations.confirmBeforeClosingWindow,
              anyPaneRequiresQuitConfirmation else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "All panes and running processes in this window will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = terminalAppearance

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.closeWindowBypassingConfirmation()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        runtimeRegistry.destroyAll()
        onWindowDidClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        rootViewController.handleWindowDidResize()
        layoutTrafficLights()
        onWorkspaceStateDidChange?()
    }

    func windowDidMove(_ notification: Notification) {
        onWorkspaceStateDidChange?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        isWindowKey = true
        layoutTrafficLights()
        refreshTrafficLightAppearanceAfterFocusChange()
    }

    func windowDidResignKey(_ notification: Notification) {
        isWindowKey = false
        refreshTrafficLightAppearanceAfterFocusChange()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        rootViewController.setFullScreenLayout(true, animated: false)
        // Drop the toolbar so the auto-hiding reveal band is titlebar-only
        // instead of the merged unified-compact titlebar+toolbar height.
        window.toolbar = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        rootViewController.setFullScreenLayout(false, animated: false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window.toolbar = windowedToolbar
        window.toolbarStyle = .unifiedCompact
        layoutTrafficLights()
    }

    /// Tells macOS to auto-hide the titlebar+toolbar band (and menu bar, dock)
    /// in native fullscreen. Without `.autoHideToolbar`, the `.unifiedCompact`
    /// toolbar renders as a permanent opaque strip at the top of the screen
    /// even when empty. With it, the system slides the strip out of view and
    /// reveals it on top-edge hover — restoring traffic lights at the same
    /// time.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideMenuBar, .autoHideToolbar, .autoHideDock])
    }

    func showSettingsWindow(_ sender: Any?) {
        showSettingsWindow(section: .general, sender: sender)
    }

    func showSettingsWindow(section: SettingsSection, sender: Any?) {
        let controller: SettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let settingsWindowController = SettingsWindowController(
                configStore: configStore,
                openWithService: openWithService,
                serverOpening: serverOpenService,
                runtimeErrorReportingEnabled: ErrorReportingRuntimeState.isEnabledForCurrentProcess,
                appearance: terminalAppearance,
                initialSection: section
            )
            self.settingsWindowController = settingsWindowController
            controller = settingsWindowController
        }

        controller.show(section: section, sender: sender)
    }

    @objc
    func newWorklane(_ sender: Any?) {
        handle(.newWorklane)
    }

    @objc
    func openBookmarksPopover(_ sender: Any?) {
        handle(.openBookmarksPopover)
    }

    @objc
    func nextWorklane(_ sender: Any?) {
        handle(.nextWorklane)
    }

    @objc
    func previousWorklane(_ sender: Any?) {
        handle(.previousWorklane)
    }

    @objc
    func toggleSidebar(_ sender: Any?) {
        handle(.toggleSidebar)
    }

    @objc
    func navigateBack(_ sender: Any?) {
        handle(.navigateBack)
    }

    @objc
    func navigateForward(_ sender: Any?) {
        handle(.navigateForward)
    }

    @objc
    func splitHorizontally(_ sender: Any?) {
        handle(.pane(.splitHorizontally))
    }

    @objc
    func splitVertically(_ sender: Any?) {
        handle(.pane(.splitVertically))
    }

    @objc
    func addPaneRight(_ sender: Any?) {
        handle(.pane(.splitHorizontally))
    }

    @objc
    func forceSplitRight(_ sender: Any?) {
        handle(.pane(.splitRightVisibly))
    }

    @objc
    func forceAddPaneRight(_ sender: Any?) {
        handle(.pane(.addPaneRightWithoutResizing))
    }

    @objc
    func runLastCommandAgain(_ sender: Any?) {
        let paneID = (sender as? NSMenuItem)?.representedObject as? PaneID
        rootViewController.runLastCommandAgain(in: paneID)
    }

    @objc
    func addPaneLeft(_ sender: Any?) {
        handle(.pane(.splitBeforeFocusedPane))
    }

    @objc
    func addPaneDown(_ sender: Any?) {
        handle(.pane(.splitVertically))
    }

    @objc
    func addPaneUp(_ sender: Any?) {
        handle(.pane(.splitVerticallyBefore))
    }

    @objc
    func arrangePaneWidthFull(_ sender: Any?) {
        handle(.pane(.arrangeHorizontally(.fullWidth)))
    }

    @objc
    func arrangePaneWidthHalves(_ sender: Any?) {
        handle(.pane(.arrangeHorizontally(.halfWidth)))
    }

    @objc
    func arrangePaneWidthThirds(_ sender: Any?) {
        handle(.pane(.arrangeHorizontally(.thirds)))
    }

    @objc
    func arrangePaneWidthQuarters(_ sender: Any?) {
        handle(.pane(.arrangeHorizontally(.quarters)))
    }

    @objc
    func arrangePaneHeightFull(_ sender: Any?) {
        handle(.pane(.arrangeVertically(.fullHeight)))
    }

    @objc
    func arrangePaneHeightTwoPerColumn(_ sender: Any?) {
        handle(.pane(.arrangeVertically(.twoPerColumn)))
    }

    @objc
    func arrangePaneHeightThreePerColumn(_ sender: Any?) {
        handle(.pane(.arrangeVertically(.threePerColumn)))
    }

    @objc
    func arrangePaneHeightFourPerColumn(_ sender: Any?) {
        handle(.pane(.arrangeVertically(.fourPerColumn)))
    }

    @objc
    func arrangeWidthGoldenFocusWide(_ sender: Any?) {
        handle(.pane(.arrangeGoldenRatio(.focusWide)))
    }

    @objc
    func arrangeWidthGoldenFocusNarrow(_ sender: Any?) {
        handle(.pane(.arrangeGoldenRatio(.focusNarrow)))
    }

    @objc
    func arrangeHeightGoldenFocusTall(_ sender: Any?) {
        handle(.pane(.arrangeGoldenRatio(.focusTall)))
    }

    @objc
    func arrangeHeightGoldenFocusShort(_ sender: Any?) {
        handle(.pane(.arrangeGoldenRatio(.focusShort)))
    }

    @objc
    func closeFocusedPane(_ sender: Any?) {
        handle(.pane(.closeFocusedPane))
    }

    @objc
    func restoreClosedPane(_ sender: Any?) {
        handle(.pane(.restoreClosedPane))
    }

    @objc
    func focusLeftPane(_ sender: Any?) {
        handle(.pane(.focusLeft))
    }

    @objc
    func focusPreviousPane(_ sender: Any?) {
        handle(.pane(.focusPreviousPaneBySidebarOrder))
    }

    @objc
    func focusNextPane(_ sender: Any?) {
        handle(.pane(.focusNextPaneBySidebarOrder))
    }

    @objc
    func focusRightPane(_ sender: Any?) {
        handle(.pane(.focusRight))
    }

    @objc
    func focusUpInColumn(_ sender: Any?) {
        handle(.pane(.focusUp))
    }

    @objc
    func focusDownInColumn(_ sender: Any?) {
        handle(.pane(.focusDown))
    }

    @objc
    func focusFirstColumn(_ sender: Any?) {
        handle(.pane(.focusFirstColumn))
    }

    @objc
    func focusLastColumn(_ sender: Any?) {
        handle(.pane(.focusLastColumn))
    }

    @objc
    func resizePaneLeft(_ sender: Any?) {
        handle(.pane(.resizeLeft))
    }

    @objc
    func resizePaneRight(_ sender: Any?) {
        handle(.pane(.resizeRight))
    }

    @objc
    func resizePaneUp(_ sender: Any?) {
        handle(.pane(.resizeUp))
    }

    @objc
    func resizePaneDown(_ sender: Any?) {
        handle(.pane(.resizeDown))
    }

    @objc
    func resetPaneLayout(_ sender: Any?) {
        handle(.pane(.resetLayout))
    }

    @objc
    func copyFocusedPanePath(_ sender: Any?) {
        handle(.copyFocusedPanePath)
    }

    @objc
    func cleanCopy(_ sender: Any?) {
        handle(.cleanCopy)
    }

    @objc
    func copyRaw(_ sender: Any?) {
        handle(.copyRaw)
    }

    @objc
    func find(_ sender: Any?) {
        handle(.find)
    }

    @objc
    func globalFind(_ sender: Any?) {
        handle(.globalFind)
    }

    @objc
    func useSelectionForFind(_ sender: Any?) {
        handle(.useSelectionForFind)
    }

    @objc
    func findNext(_ sender: Any?) {
        handle(.findNext)
    }

    @objc
    func findPrevious(_ sender: Any?) {
        handle(.findPrevious)
    }

    @objc
    func showCommandPalette(_ sender: Any?) {
        handle(.showCommandPalette)
    }

    @objc
    func openSettings(_ sender: Any?) {
        handle(.openSettings)
    }

    @objc
    func closeCurrentWindow(_ sender: Any?) {
        handle(.closeWindow)
    }

    @objc
    func reloadConfig(_ sender: Any?) {
        handle(.reloadConfig)
    }

    @objc
    func splitRight(_ sender: Any?) {
        splitHorizontally(sender)
    }

    @objc
    func splitLeft(_ sender: Any?) {
        splitVertically(sender)
    }

    @objc
    func focusFirstPane(_ sender: Any?) {
        focusFirstColumn(sender)
    }

    @objc
    func focusLastPane(_ sender: Any?) {
        focusLastColumn(sender)
    }

    var settingsWindow: NSWindow? {
        settingsWindowController?.window
    }

    var worklaneStore: WorklaneStore {
        rootViewController.worklaneStore
    }

    var menuBarDisplayTitle: String {
        "Window \(windowOrder + 1)"
    }

    func focusWorklane(id worklaneID: WorklaneID) {
        window.makeKeyAndOrderFront(nil)
        if !Self.isHostedTestMode {
            NSApp.activate(ignoringOtherApps: true)
        }
        rootViewController.worklaneStore.selectWorklane(id: worklaneID)
    }

    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID) {
        #if DEBUG
        lastNavigateRequestWorklaneID = worklaneID
        lastNavigateRequestPaneID = paneID
        #endif
        window.makeKeyAndOrderFront(nil)
        if !Self.isHostedTestMode {
            NSApp.activate(ignoringOtherApps: true)
        }
        rootViewController.navigateToPane(worklaneID: worklaneID, paneID: paneID)
    }

    func containsWorklane(_ worklaneID: WorklaneID) -> Bool {
        rootViewController.containsWorklane(worklaneID)
    }

    func containsPane(worklaneID: WorklaneID, paneID: PaneID) -> Bool {
        rootViewController.containsPane(worklaneID: worklaneID, paneID: paneID)
    }

    func containsPane(_ paneID: PaneID) -> Bool {
        rootViewController.containsPane(paneID)
    }

    func worklaneID(containing paneID: PaneID) -> WorklaneID? {
        rootViewController.worklaneID(containing: paneID)
    }

    @objc
    func movePaneToNewWindow(_ sender: Any?) {
        onMovePaneToNewWindowRequested?(self, representedPaneID(from: sender) ?? rootViewController.focusedPaneID())
    }

    @objc
    func movePaneToWorklane(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let request = item.representedObject as? MovePaneToWorklaneRequest else {
            return
        }
        onMovePaneToWorklaneRequested?(self, request)
    }

    @objc
    func movePaneToNewWorklaneInThisWindow(_ sender: Any?) {
        guard let paneID = representedPaneID(from: sender) ?? rootViewController.focusedPaneID() else {
            return
        }
        onMovePaneToNewWorklaneInThisWindowRequested?(self, paneID)
    }

    func canMovePaneToNewWindow(paneID: PaneID?) -> Bool {
        guard let paneID = paneID ?? rootViewController.focusedPaneID() else {
            return false
        }

        return rootViewController.canSplitOutPaneToNewWindow(paneID: paneID)
    }

    func availableWorklaneSummaries(excluding worklaneID: WorklaneID?) -> [WorklaneDestinationSummary] {
        rootViewController.worklaneStore.destinationSummaries(
            windowID: windowID,
            excluding: worklaneID
        )
    }

    func paneCount(in worklaneID: WorklaneID) -> Int {
        rootViewController.worklaneStore.worklanes
            .first(where: { $0.id == worklaneID })?
            .paneStripState.panes.count ?? 0
    }

    func transferPaneToWorklaneInThisWindow(paneID: PaneID, targetWorklaneID: WorklaneID) {
        let store = rootViewController.worklaneStore
        ensureSourceWorklaneActive(for: paneID, in: store)
        store.transferPaneToWorklane(
            paneID: paneID,
            targetWorklaneID: targetWorklaneID,
            singleColumnWidth: store.layoutContext.singlePaneWidth
        )
    }

    func transferPaneToNewWorklaneInThisWindow(paneID: PaneID) {
        let store = rootViewController.worklaneStore
        ensureSourceWorklaneActive(for: paneID, in: store)
        store.transferPaneToNewWorklane(
            paneID: paneID,
            singleColumnWidth: store.layoutContext.singlePaneWidth
        )
    }

    /// `transferPaneToWorklane` and `transferPaneToNewWorklane` use
    /// `activeWorklaneID` as the source. When the menu fires from the sidebar
    /// (or any context where the right-clicked pane isn't in the active
    /// worklane), pre-select so the transfer targets the right source.
    private func ensureSourceWorklaneActive(for paneID: PaneID, in store: WorklaneStore) {
        guard let sourceWorklaneID = store.worklanes.first(where: { worklane in
            worklane.paneStripState.panes.contains { $0.id == paneID }
        })?.id, sourceWorklaneID != store.activeWorklaneID else {
            return
        }
        store.selectWorklane(id: sourceWorklaneID)
    }

    func extractPaneForCrossWindowTransfer(
        paneID: PaneID
    ) -> (payload: WorklaneStore.ExtractedPanePayload, runtime: PaneRuntime?)? {
        let store = rootViewController.worklaneStore
        let runtime = runtimeRegistry.detachRuntime(for: paneID)
        guard let payload = store.extractPaneForCrossWindowTransfer(
            paneID: paneID,
            singleColumnWidth: store.layoutContext.singlePaneWidth
        ) else {
            if let runtime { runtimeRegistry.adoptRuntime(runtime, for: paneID) }
            return nil
        }
        return (payload, runtime)
    }

    /// Inserts the pane into the destination worklane, adopts the runtime, then
    /// publishes the structural changes.
    /// Returns `true` on success. On failure (target worklane gone), neither the
    /// runtime nor the pane state is added — the caller still owns the runtime.
    @discardableResult
    func acceptCrossWindowPane(
        payload: WorklaneStore.ExtractedPanePayload,
        runtime: PaneRuntime?,
        targetWorklaneID: WorklaneID
    ) -> Bool {
        let store = rootViewController.worklaneStore
        guard store.worklanes.contains(where: { $0.id == targetWorklaneID }) else {
            return false
        }

        var didInsert = false
        store.batchUpdate {
            didInsert = store.insertExtractedPane(
                payload,
                intoWorklane: targetWorklaneID,
                singleColumnWidth: store.layoutContext.singlePaneWidth
            )
        }
        guard didInsert else {
            return false
        }
        if let runtime {
            runtimeRegistry.adoptRuntime(runtime, for: payload.pane.id)
        }
        store.notify(.paneStructure(targetWorklaneID))
        store.notify(.activeWorklaneChanged)
        return true
    }

    func splitOutPaneForNewWindow(
        paneID: PaneID,
        destinationWindowID: WindowID
    ) -> (result: PaneSplitOutResult, runtime: PaneRuntime?)? {
        guard rootViewController.canSplitOutPaneToNewWindow(paneID: paneID) else {
            return nil
        }

        let runtime = runtimeRegistry.detachRuntime(for: paneID)
        guard let result = rootViewController.splitOutPaneToNewWindow(
            paneID: paneID,
            destinationWindowID: destinationWindowID
        ) else {
            if let runtime {
                runtimeRegistry.adoptRuntime(runtime, for: paneID)
            }
            return nil
        }

        return (result, runtime)
    }

    func showSplitOutWindow(cascadingFrom sourceFrame: NSRect) {
        isWindowKey = true
        window.setFrame(sourceFrame, display: false)
        window.cascadeTopLeft(from: NSPoint(x: sourceFrame.minX, y: sourceFrame.maxY))
        window.makeKeyAndOrderFront(nil)
        syncWindowAppearance()
        layoutTrafficLights()
        rootViewController.activateWindowBindingsIfNeeded()
    }

    // MARK: - Pane IPC

    func handlePaneIPCCommand(_ command: PaneCommand) {
        rootViewController.handlePaneIPCCommand(command)
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
        rootViewController.splitWithLayout(
            placement: placement,
            isHorizontal: isHorizontal,
            layout: layout,
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
        try rootViewController.applyGrid(
            sourcePaneID: sourcePaneID,
            rows: rows,
            columns: columns,
            command: command,
            includeSource: includeSource,
            focus: focus
        )
    }

    @discardableResult
    func createWorklaneForGrid() -> (worklaneID: WorklaneID, paneID: PaneID)? {
        let worklaneID = rootViewController.createWorklaneForGrid()
        guard let paneID = rootViewController.focusedPaneID() else {
            return nil
        }
        return (worklaneID, paneID)
    }

    func gridWindowWorkspaceState(
        inheritingFrom sourcePaneID: PaneID,
        destinationWindowID: WindowID
    ) -> WindowWorkspaceState? {
        rootViewController.gridWindowWorkspaceState(
            inheritingFrom: sourcePaneID,
            destinationWindowID: destinationWindowID
        )
    }

    @discardableResult
    func launchDeferredPane(id paneID: PaneID, nativeCommand: String) -> Bool {
        rootViewController.launchDeferredPane(id: paneID, nativeCommand: nativeCommand)
    }

    @discardableResult
    func setPaneTitle(id paneID: PaneID, title: String) -> Bool {
        rootViewController.setPaneTitle(id: paneID, title: title)
    }

    func paneListEntries(for worklaneID: WorklaneID) -> [PaneListEntry] {
        rootViewController.paneListEntries(for: worklaneID)
    }

    func taskManagerPaneSources() -> [TaskManagerPaneSource] {
        rootViewController.taskManagerPaneSources(
            windowID: windowID,
            windowTitle: window.title.isEmpty ? "Window \(windowOrder + 1)" : window.title
        )
    }

    func resolvePaneID(_ target: String, in worklaneID: WorklaneID) -> PaneID? {
        rootViewController.resolvePaneID(target, in: worklaneID)
    }

    func focusPane(id: PaneID, in worklaneID: WorklaneID) {
        rootViewController.focusPaneByID(id, in: worklaneID)
    }

    func closePane(id: PaneID) {
        rootViewController.closePaneByID(id)
    }

    /// Used by `TmuxCompatIPCHandler` for `tmux send-keys`. Returns true when
    /// the pane has a live runtime and the text was forwarded; false when the
    /// pane is unknown or its runtime hasn't been created yet.
    @discardableResult
    func sendText(_ text: String, to paneID: PaneID) -> Bool {
        guard let runtime = runtimeRegistry.runtime(for: paneID) else {
            return false
        }
        runtime.adapter.sendText(text)
        return true
    }

    @discardableResult
    func submitCommand(_ command: String, to paneID: PaneID) -> Bool {
        guard let runtime = runtimeRegistry.runtime(for: paneID) else {
            return false
        }
        runtime.adapter.submitCommand(command)
        return true
    }

    func readText(from paneID: PaneID, includeScrollback: Bool, lineLimit: Int?) -> String? {
        guard let runtime = runtimeRegistry.runtime(for: paneID),
              let reader = runtime.adapter as? TerminalTextReading
        else {
            return nil
        }
        return reader.readText(includeScrollback: includeScrollback, lineLimit: lineLimit)
    }

    /// Re-load the in-memory `WorklaneStore.teamAnchorByWorklaneID` from disk
    /// and emit `.teamAnchorsChanged` for any worklane that changed. Called
    /// by `TmuxCompatIPCHandler` after every store-mutating subcommand so
    /// the title strip's LEADER star redraws.
    func refreshTeamAnchors() {
        rootViewController.worklaneStore.refreshTeamAnchors()
    }

    @discardableResult
    func setWorklaneColor(_ color: WorklaneColor?, on id: WorklaneID) -> Bool {
        rootViewController.setWorklaneColor(color, on: id)
    }

    func resizeFocusedColumnToFraction(_ fraction: CGFloat) {
        rootViewController.resizeFocusedColumnToFraction(fraction)
    }

    func resizeColumnContainingPane(id paneID: PaneID, toFraction fraction: CGFloat) {
        rootViewController.resizeColumnContainingPane(id: paneID, toFraction: fraction)
    }

    func columnWidthForPane(id paneID: PaneID, in worklaneID: WorklaneID) -> CGFloat? {
        rootViewController.columnWidthForPane(id: paneID, in: worklaneID)
    }

    func resizeColumnContainingPaneToWidth(id paneID: PaneID, width: CGFloat) {
        rootViewController.resizeColumnContainingPaneToWidth(id: paneID, width: width)
    }

    func resizeFocusedPaneHeightToFraction(_ fraction: CGFloat) {
        rootViewController.resizeFocusedPaneHeightToFraction(fraction)
    }

    func handleServerIPCCommand(
        _ command: ServerIPCCommand,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        try rootViewController.handleServerIPCCommand(command, target: target)
    }

    func equalizeFocusedColumnPaneHeights() {
        rootViewController.equalizeFocusedColumnPaneHeights()
    }

    func tearDownRuntime() {
        runtimeRegistry.destroyAll()
    }

    func closeWindowBypassingConfirmation() {
        shouldBypassNextCloseConfirmation = true
        window.close()
    }

    var anyPaneRequiresQuitConfirmation: Bool {
        rootViewController.anyPaneRequiresQuitConfirmation
    }

    var terminalAppearance: NSAppearance? {
        let theme = currentWindowTheme
        let isDark = theme.windowBackground.isDarkThemeColor
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    var currentWindowTheme: ZenttyTheme {
        rootViewController.currentWindowTheme
    }

    private func syncWindowAppearance() {
        let appearance = terminalAppearance
        window.appearance = appearance
        settingsWindowController?.applyAppearance(appearance)
        onWindowAppearanceDidChange?(appearance, currentWindowTheme)
    }

    var worklaneTitles: [String] {
        rootViewController.worklaneTitles
    }

    var activeWorklaneTitle: String? {
        rootViewController.activeWorklaneTitle
    }

    var activePaneTitles: [String] {
        rootViewController.activePaneTitles
    }

    var focusedPaneTitle: String? {
        rootViewController.focusedPaneTitle
    }

    var sidebarToggleMinX: CGFloat {
        rootViewController.sidebarToggleMinX
    }

    var sidebarToggleMidY: CGFloat {
        rootViewController.sidebarToggleMidY
    }

    var isSidebarToggleActive: Bool {
        rootViewController.isSidebarToggleActive
    }

    private func performOpenWithPrimaryAction() {
        guard
            let target = rootViewController.primaryOpenWithTarget,
            let context = rootViewController.focusedOpenWithContext
        else {
            NSSound.beep()
            return
        }

        rememberOpenWithPrimaryTarget(target.stableID)
        _ = openWithService.open(target: target, workingDirectory: context.workingDirectory)
    }

    private func performServerPrimaryAction() {
        guard let server = rootViewController.activeServerContext.primaryServer else {
            NSSound.beep()
            return
        }

        _ = rootViewController.openServer(server)
    }

    private func showServerMenu() {
        let menu = makeServerMenu()
        let anchorRect = rootViewController.chromeView.serverMenuAnchorRect
        let menuLocation = NSPoint(x: anchorRect.minX, y: anchorRect.minY)
        menu.popUp(positioning: nil, at: menuLocation, in: rootViewController.chromeView)
    }

    private func makeServerMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        let context = rootViewController.activeServerContext
        let model = ServerMenuModel(context: context)

        if model.isEmpty {
            let item = NSMenuItem(title: ServerMenuContent.emptyStateTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for entry in model.visible {
                let item = NSMenuItem(title: entry.server.display, action: #selector(handleServerMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.server
                item.toolTip = entry.server.url.absoluteString
                item.state = entry.isPrimary ? .on : .off
                menu.addItem(item)
            }

            if !model.manageable.isEmpty || !model.hidden.isEmpty {
                if !model.visible.isEmpty {
                    menu.addItem(.separator())
                }
                if !model.manageable.isEmpty {
                    menu.addItem(makeManageServersMenuItem(model.manageable))
                }
                if !model.hidden.isEmpty {
                    menu.addItem(makeHiddenServersMenuItem(model.hidden))
                }
            }

            if let primaryServer = context.primaryServer {
                menu.addItem(.separator())
                let copyItem = NSMenuItem(title: ServerMenuContent.copyURLTitle, action: #selector(handleCopyServerURL(_:)), keyEquivalent: "")
                copyItem.target = self
                copyItem.representedObject = primaryServer
                menu.addItem(copyItem)
            }
        }

        menu.addItem(.separator())
        let preferredBrowserID = configStore.current.serverDetection.preferredBrowserID
        rootViewController.availableServerBrowsers.forEach { browser in
            let item = NSMenuItem(title: browser.displayName, action: #selector(handleServerBrowserMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = browser
            item.image = serverOpenService.icon(for: browser)
            item.isEnabled = browser.isAvailable && context.primaryServer != nil
            item.state = Self.isPreferredServerBrowser(
                browser,
                preferredBrowserID: preferredBrowserID
            ) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: ServerMenuContent.settingsTitle,
            action: #selector(handleServerSettingsMenuItem(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    private func makeManageServersMenuItem(_ entries: [ServerMenuModel.Entry]) -> NSMenuItem {
        let parent = NSMenuItem(title: ServerMenuContent.manageTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "")
        submenu.autoenablesItems = false

        for entry in entries {
            guard let port = entry.port else {
                continue
            }
            let serverItem = NSMenuItem(title: entry.server.display, action: nil, keyEquivalent: "")
            let serverSubmenu = NSMenu(title: "")
            serverSubmenu.autoenablesItems = false
            let ignoreItem = NSMenuItem(
                title: ServerMenuContent.ignorePortTitle(port),
                action: #selector(handleIgnorePort(_:)),
                keyEquivalent: ""
            )
            ignoreItem.target = self
            ignoreItem.representedObject = port
            serverSubmenu.addItem(ignoreItem)
            serverItem.submenu = serverSubmenu
            submenu.addItem(serverItem)
        }

        parent.submenu = submenu
        return parent
    }

    private func makeHiddenServersMenuItem(_ entries: [ServerMenuModel.Entry]) -> NSMenuItem {
        let parent = NSMenuItem(title: ServerMenuContent.hiddenTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "")
        submenu.autoenablesItems = false

        for entry in entries {
            guard let port = entry.port else {
                continue
            }
            let serverItem = NSMenuItem(title: entry.server.display, action: nil, keyEquivalent: "")
            serverItem.toolTip = ServerMenuContent.ignoredPortHint(port)
            let serverSubmenu = NSMenu(title: "")
            serverSubmenu.autoenablesItems = false
            let stopItem = NSMenuItem(
                title: ServerMenuContent.stopIgnoringPortTitle(port),
                action: #selector(handleStopIgnoringPort(_:)),
                keyEquivalent: ""
            )
            stopItem.target = self
            stopItem.representedObject = port
            serverSubmenu.addItem(stopItem)
            serverItem.submenu = serverSubmenu
            submenu.addItem(serverItem)
        }

        parent.submenu = submenu
        return parent
    }

    @objc
    private func handleServerMenuItem(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? DetectedServer else {
            return
        }

        _ = rootViewController.openServer(server)
    }

    @objc
    private func handleIgnorePort(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.ignoredPortRules = ServerPortRule.addingPort(
                port,
                to: config.serverDetection.ignoredPortRules
            )
        }
    }

    @objc
    private func handleStopIgnoringPort(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.ignoredPortRules = ServerPortRule.removingPort(
                port,
                from: config.serverDetection.ignoredPortRules
            )
        }
    }

    @objc
    private func handleCopyServerURL(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? DetectedServer else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.url.absoluteString, forType: .string)
    }

    @objc
    private func handleServerBrowserMenuItem(_ sender: NSMenuItem) {
        guard
            let browser = sender.representedObject as? ServerBrowserTarget,
            let server = rootViewController.activeServerContext.primaryServer
        else {
            return
        }

        rootViewController.rememberServerBrowser(browser.stableID)
        _ = rootViewController.openServer(server, browserID: browser.stableID)
    }

    @objc
    private func handleServerSettingsMenuItem(_ sender: Any?) {
        showSettingsWindow(section: .devServers, sender: sender)
    }

    private func showOpenWithMenu() {
        let menu = makeOpenWithMenu()
        let anchorRect = rootViewController.chromeView.openWithMenuAnchorRect
        let menuLocation = NSPoint(x: anchorRect.minX, y: anchorRect.minY)
        menu.popUp(positioning: nil, at: menuLocation, in: rootViewController.chromeView)
    }

    private func makeOpenWithMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        let hasLocalContext = rootViewController.focusedOpenWithContext != nil
        let availableTargets = rootViewController.availableOpenWithTargets
        let primaryStableID = rootViewController.primaryOpenWithTarget?.stableID
        openWithService.preloadIcons(for: availableTargets)

        if availableTargets.isEmpty {
            let item = NSMenuItem(title: OpenWithMenuContent.emptyStateTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            availableTargets.forEach { target in
                menu.addItem(
                    makeOpenWithMenuItem(
                        target: target,
                        isEnabled: hasLocalContext,
                        isSelected: target.stableID == primaryStableID
                    )
                )
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeOpenWithSettingsMenuItem())
        return menu
    }

    private func makeOpenWithMenuItem(
        target: OpenWithResolvedTarget,
        isEnabled: Bool,
        isSelected: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: target.displayName, action: #selector(handleOpenWithMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        item.image = openWithService.icon(for: target)
        item.isEnabled = isEnabled
        item.state = isSelected ? .on : .off
        return item
    }

    private func makeOpenWithSettingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: OpenWithMenuContent.settingsTitle,
            action: #selector(handleOpenWithSettingsMenuItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    @objc
    private func handleOpenWithMenuItem(_ sender: NSMenuItem) {
        guard
            let target = sender.representedObject as? OpenWithResolvedTarget,
            let context = rootViewController.focusedOpenWithContext
        else {
            return
        }

        rememberOpenWithPrimaryTarget(target.stableID)
        _ = openWithService.open(target: target, workingDirectory: context.workingDirectory)
    }

    private func performOpenWithMenuSelection(stableID: String) {
        guard let target = rootViewController.availableOpenWithTargets.first(where: { $0.stableID == stableID }) else {
            return
        }

        let item = NSMenuItem(title: target.displayName, action: nil, keyEquivalent: "")
        item.representedObject = target
        handleOpenWithMenuItem(item)
    }

    @objc
    private func handleOpenWithSettingsMenuItem(_ sender: Any?) {
        showSettingsWindow(section: .openWith, sender: sender)
    }

    private func handle(_ action: AppAction) {
        rootViewController.handle(action)
    }

    private func representedPaneID(from sender: Any?) -> PaneID? {
        guard let representedObject = (sender as? NSMenuItem)?.representedObject else {
            return nil
        }

        if let paneID = representedObject as? PaneID {
            return paneID
        }

        if let rawValue = representedObject as? String {
            return PaneID(rawValue)
        }

        return nil
    }

    private func rememberOpenWithPrimaryTarget(_ stableID: String) {
        guard configStore.current.openWith.primaryTargetID != stableID else {
            return
        }

        try? configStore.update { config in
            config.openWith.primaryTargetID = stableID
        }
    }

    private func layoutTrafficLights() {
        // In native fullscreen the system re-hosts the traffic lights in the
        // auto-hiding titlebar overlay. Forcing them back to our custom frame
        // lands them outside the revealed strip, so the user never sees them
        // on hover. Let AppKit place them natively in fullscreen.
        if window.styleMask.contains(.fullScreen) {
            return
        }

        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let miniButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton),
            let buttonSuperview = closeButton.superview
        else {
            return
        }

        let buttons = [closeButton, miniButton, zoomButton]
        let targetY = buttonSuperview.bounds.maxY - ChromeGeometry.trafficLightTopInset - closeButton.frame.height
        var nextX = ChromeGeometry.trafficLightLeadingInset

        buttons.forEach { button in
            var frame = button.frame
            frame.origin.x = nextX
            frame.origin.y = targetY
            button.frame = frame.integral
            nextX = frame.maxX + ChromeGeometry.trafficLightSpacing
        }

        syncInactiveTrafficLightOverlayFrames(
            for: [
                (closeButton, closeTrafficLightOverlay),
                (miniButton, miniTrafficLightOverlay),
                (zoomButton, zoomTrafficLightOverlay),
            ]
        )

        let anchorPointInWindow = buttonSuperview.convert(
            NSPoint(x: zoomButton.frame.maxX, y: zoomButton.frame.midY),
            to: nil
        )
        let anchorPointInContent = rootViewController.view.convert(anchorPointInWindow, from: nil)
        rootViewController.updateTrafficLightAnchor(anchorPointInContent)
        updateTrafficLightAppearance()
    }

    @objc
    private func applicationDidBecomeActive(_ notification: Notification) {
        isApplicationActive = true
        refreshTrafficLightAppearanceAfterFocusChange()
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        isApplicationActive = false
        refreshTrafficLightAppearanceAfterFocusChange()
    }

    private func refreshTrafficLightAppearanceAfterFocusChange() {
        layoutTrafficLights()
        DispatchQueue.main.async { [weak self] in
            self?.layoutTrafficLights()
        }
    }

    private func updateTrafficLightAppearance() {
        let inactiveFillColor = (isWindowKey && isApplicationActive)
            ? nil
            : TrafficLightTintResolver.inactiveBezelColor(
                theme: rootViewController.currentWindowTheme,
                sidebarVisibilityMode: rootViewController.sidebarVisibilityMode
            )

        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let miniButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton)
        else {
            return
        }

        [closeButton, miniButton, zoomButton].forEach { button in
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            button.layer?.cornerRadius = button.bounds.height / 2
            button.layer?.backgroundColor = nil
            button.layer?.borderWidth = 0
            button.layer?.borderColor = nil
            button.bezelColor = nil
            button.needsDisplay = true
        }

        syncInactiveTrafficLightOverlayFrames(
            for: [
                (closeButton, closeTrafficLightOverlay),
                (miniButton, miniTrafficLightOverlay),
                (zoomButton, zoomTrafficLightOverlay),
            ]
        )

        [closeTrafficLightOverlay, miniTrafficLightOverlay, zoomTrafficLightOverlay].forEach {
            $0.apply(fillColor: inactiveFillColor)
        }
    }

    private func syncInactiveTrafficLightOverlayFrames(
        for pairs: [(button: NSButton, overlay: InactiveTrafficLightOverlayView)]
    ) {
        pairs.forEach { button, overlay in
            guard let hostView = button.superview else {
                overlay.removeFromSuperview()
                return
            }

            if overlay.superview !== hostView {
                overlay.removeFromSuperview()
                hostView.addSubview(overlay, positioned: .above, relativeTo: button)
            } else {
                overlay.removeFromSuperviewWithoutNeedingDisplay()
                hostView.addSubview(overlay, positioned: .above, relativeTo: button)
            }

            overlay.frame = button.frame.integral
        }
    }

    private static func defaultFrame() -> NSRect {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let maxWidth = max(Layout.initialMinimumSize.width, visibleFrame.width - Layout.screenInset.width)
            let maxHeight = max(Layout.initialMinimumSize.height, visibleFrame.height - Layout.screenInset.height)
            let targetWidth = min(maxWidth, max(Layout.initialMinimumSize.width, visibleFrame.width * Layout.widthRatio))
            let targetHeight = min(maxHeight, max(Layout.initialMinimumSize.height, visibleFrame.height * Layout.heightRatio))
            let origin = NSPoint(
                x: visibleFrame.midX - (targetWidth / 2),
                y: visibleFrame.midY - (targetHeight / 2)
            )

            return NSRect(origin: origin, size: NSSize(width: targetWidth, height: targetHeight)).integral
        }

        return NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func initialPaneLayoutContext(
        initialFrame: NSRect,
        config: AppConfig
    ) -> PaneLayoutContext {
        let viewportWidth = max(1, initialFrame.width - (ShellMetrics.outerInset * 2))
        let displayClass = PaneDisplayClassResolver.resolve(
            screen: NSScreen.main ?? NSScreen.screens.first,
            viewportWidth: viewportWidth
        )

        return config.paneLayout.makeLayoutContext(
            displayClass: displayClass,
            viewportWidth: viewportWidth,
            leadingVisibleInset: SidebarVisibilityController(mode: config.sidebar.visibility)
                .effectiveLeadingInset(
                    sidebarWidth: config.sidebar.width,
                    availableWidth: initialFrame.width
                ),
            sizing: PaneLayoutSizing.forSidebarVisibility(config.sidebar.visibility)
        )
    }

    static func defaultFrameForRestore() -> NSRect {
        defaultFrame()
    }

    static func validatedPaneLayoutSeedFrameForRestore(_ frame: WorkspaceRecipe.WindowFrame?) -> NSRect? {
        guard let frame else {
            return nil
        }

        return validatedPaneLayoutSeedFrameForRestore(frame.rect)
    }

    static func validatedPaneLayoutSeedFrameForRestore(_ frame: NSRect?) -> NSRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.width >= 320,
              frame.height >= 240
        else {
            return nil
        }

        return frame.integral
    }

    static func legacyAutosavedFrameForRestore(
        windowIndex: Int,
        defaults: UserDefaults = .standard
    ) -> NSRect? {
        let defaultsKey = "NSWindow Frame \(windowFrameAutosaveName(forWindowIndex: windowIndex))"
        guard let value = defaults.string(forKey: defaultsKey) else {
            return nil
        }

        let components = value.split(whereSeparator: \.isWhitespace)
        guard components.count >= 4,
              let x = Double(components[0]),
              let y = Double(components[1]),
              let width = Double(components[2]),
              let height = Double(components[3]) else {
            return nil
        }

        return validatedPaneLayoutSeedFrameForRestore(
            NSRect(
                x: x,
                y: y,
                width: width,
                height: height
            )
        )
    }

    static func windowFrameAutosaveName(forWindowIndex windowIndex: Int) -> String {
        windowIndex == 0 ? "MainWindow" : "ZenttyWindow-\(windowIndex)"
    }

    static func initialPaneLayoutContextForRestore(
        initialFrame: NSRect,
        config: AppConfig
    ) -> PaneLayoutContext {
        initialPaneLayoutContext(initialFrame: initialFrame, config: config)
    }

    var workspaceRecipeWindow: WorkspaceRecipe.Window {
        let workspaceState = rootViewController.workspaceState
        return WorkspaceRecipeExporter.makeWindow(
            windowID: windowID,
            frame: window.frame,
            worklanes: workspaceState.worklanes,
            activeWorklaneID: workspaceState.activeWorklaneID
        )
    }

    var discoveryWorkspaceState: WindowWorkspaceState {
        rootViewController.workspaceState
    }

    var sessionRestoreDraftWindow: SessionRestoreDraftWindow? {
        let workspaceState = rootViewController.workspaceState
        return SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: windowID,
            worklanes: workspaceState.worklanes
        )
    }

    #if DEBUG
    private var lastNavigateRequestWorklaneID: WorklaneID?
    private var lastNavigateRequestPaneID: PaneID?

    var lastNavigateRequestWorklaneIDForTesting: WorklaneID? {
        lastNavigateRequestWorklaneID
    }

    var lastNavigateRequestPaneIDForTesting: PaneID? {
        lastNavigateRequestPaneID
    }

    func performOpenWithPrimaryActionForTesting() {
        performOpenWithPrimaryAction()
    }

    func performOpenWithMenuSelectionForTesting(stableID: String) {
        performOpenWithMenuSelection(stableID: stableID)
    }

    func injectFocusedPaneShellContextForTesting(path: String, scope: PaneShellContextScope = .local) {
        guard let paneID = rootViewController.focusedPaneIDForTesting,
              let worklaneID = rootViewController.activeWorklaneIDForTesting else {
            return
        }

        rootViewController.applyAgentStatusPayloadForTesting(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: scope,
                    path: path,
                    home: "/Users/peter",
                    user: "peter",
                    host: scope == .local ? "mbp" : "remote"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    var rootViewControllerForTesting: RootViewController {
        rootViewController
    }

    var windowIDForTesting: WindowID {
        windowID
    }

    var focusedPaneEnvironmentForTesting: [String: String]? {
        rootViewController.paneStripStateForTesting.focusedPane?.sessionRequest.environmentVariables
    }

    func openWithMenuForTesting() -> NSMenu {
        makeOpenWithMenu()
    }

    func performOpenWithMenuItemForTesting(_ item: NSMenuItem) {
        switch item.action {
        case #selector(handleOpenWithMenuItem(_:)):
            handleOpenWithMenuItem(item)
        case #selector(handleOpenWithSettingsMenuItem(_:)):
            handleOpenWithSettingsMenuItem(item)
        default:
            break
        }
    }

    func windowDragSuppressionTargetForTesting(
        at point: NSPoint,
        eventType: NSEvent.EventType
    ) -> WindowDragSuppressionTarget? {
        rootViewController.windowDragSuppressionTarget(at: point, eventType: eventType)
    }

    @discardableResult
    func handleProxySuppressionEventForTesting(
        location: NSPoint,
        eventType: NSEvent.EventType,
        invokeProxyHandler: Bool = false
    ) -> Bool {
        (window as? ProxyAwareWindow)?.handleProxySuppressionEventForTesting(
            location: location,
            eventType: eventType,
            invokeProxyHandler: invokeProxyHandler
        ) ?? false
    }

    var isWindowMovableForTesting: Bool {
        window.isMovable
    }
    #endif
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action,
           let commandID = AppCommandRegistry.commandID(forMenuAction: action) {
            switch commandID {
            case .cleanCopy, .copyRaw:
                return rootViewController.focusedTerminalHasSelection
            case .movePaneToNewWindow:
                return canMovePaneToNewWindow(paneID: representedPaneID(from: menuItem))
            default:
                return rootViewController.isCommandAvailable(commandID)
            }
        }

        switch menuItem.action {
        case #selector(addPaneRight(_:)),
             #selector(addPaneLeft(_:)),
             #selector(forceSplitRight(_:)),
             #selector(forceAddPaneRight(_:)):
            return rootViewController.isCommandAvailable(.splitHorizontally)
        case #selector(addPaneDown(_:)), #selector(addPaneUp(_:)):
            return rootViewController.isCommandAvailable(.splitVertically)
        default:
            break
        }
        return true
    }
}

enum TrafficLightTintResolver {
    static func inactiveBezelColor(
        theme: ZenttyTheme,
        sidebarVisibilityMode: SidebarVisibilityMode
    ) -> NSColor {
        switch sidebarVisibilityMode {
        case .pinnedOpen:
            let baseColor = theme.sidebarBackground
                .composited(over: theme.windowBackground)
                .withAlphaComponent(1)
            return baseColor.mixed(towards: NSColor.black, amount: 0.10)
        case .hidden, .hoverPeek:
            let baseColor = theme.windowBackground.srgbClamped.withAlphaComponent(1)
            let amount: CGFloat = baseColor.isDarkThemeColor ? 0.24 : 0.12
            return baseColor.mixed(towards: .white, amount: amount)
        }
    }
}

@MainActor
private final class InactiveTrafficLightOverlayView: NSView {
    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        layer?.borderColor = nil
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(fillColor: NSColor?) {
        layer?.backgroundColor = fillColor?.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
        isHidden = fillColor == nil
    }
}
