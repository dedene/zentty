import AppKit

enum WindowDragSuppressionTarget: Equatable {
    case globalSearchHUD
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

    let window: NSWindow
    let windowID: WindowID
    private let rootViewController: RootViewController
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private let openWithService: OpenWithServing
    private var settingsWindowController: SettingsWindowController?
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

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        configStore: AppConfigStore? = nil,
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        notificationStore: NotificationStore = NotificationStore(),
        openWithService: OpenWithServing = OpenWithService(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard,
        windowIndex: Int = 0
    ) {
        let resolvedConfigStore = configStore ?? AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.MainWindowController"),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )
        let initialFrame = Self.defaultFrame()
        let initialLayoutContext = Self.initialPaneLayoutContext(
            initialFrame: initialFrame,
            config: resolvedConfigStore.current
        )

        let rootViewController = RootViewController(
            windowID: windowID,
            configStore: resolvedConfigStore,
            appUpdateStateStore: appUpdateStateStore,
            openWithService: openWithService,
            runtimeRegistry: runtimeRegistry,
            notificationStore: notificationStore,
            initialLayoutContext: initialLayoutContext
        )
        rootViewController.loadViewIfNeeded()
        let window = ProxyAwareWindow(
            contentRect: initialFrame,
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
        let toolbar = NSToolbar(identifier: "be.zenjoy.Zentty.MainToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.isOpaque = false
        // Starts transparent; RootViewController.apply(theme:) syncs the real theme color
        // into window.backgroundColor so the rounded-corner shadow halo composites against
        // the shell fill instead of nothing (which is what produces the white seam).
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        rootViewController.view.frame = NSRect(origin: .zero, size: initialFrame.size)
        rootViewController.view.autoresizingMask = [.width, .height]
        window.contentView = rootViewController.view
        if !CommandLine.arguments.contains("-ApplePersistenceIgnoreState") {
            let autosaveName = windowIndex == 0 ? "MainWindow" : "ZenttyWindow-\(windowIndex)"
            window.setFrameAutosaveName(autosaveName)
        }

        self.rootViewController = rootViewController
        self.windowID = windowID
        self.runtimeRegistry = runtimeRegistry
        self.configStore = resolvedConfigStore
        self.openWithService = openWithService
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
        rootViewController.onShowSettingsRequested = { [weak self] in
            self?.showSettingsWindow(section: .general, sender: nil)
        }
        rootViewController.onCheckForUpdatesRequested = { [weak self] in
            self?.onCheckForUpdatesRequested?()
        }
        rootViewController.onNavigateToNotificationRequested = { [weak self] windowID, worklaneID, paneID in
            self?.onNavigateToNotificationRequested?(windowID, worklaneID, paneID)
        }
        rootViewController.onCloseWindowRequested = { [weak self] in
            self?.closeWindowBypassingConfirmation()
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
    func toggleZoomOut(_ sender: Any?) {
        handle(.pane(.toggleZoomOut))
    }

    @objc
    func copyFocusedPanePath(_ sender: Any?) {
        handle(.copyFocusedPanePath)
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

    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID) {
        #if DEBUG
        lastNavigateRequestWorklaneID = worklaneID
        lastNavigateRequestPaneID = paneID
        #endif
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rootViewController.navigateToPane(worklaneID: worklaneID, paneID: paneID)
    }

    func containsWorklane(_ worklaneID: WorklaneID) -> Bool {
        rootViewController.containsWorklane(worklaneID)
    }

    func containsPane(worklaneID: WorklaneID, paneID: PaneID) -> Bool {
        rootViewController.containsPane(worklaneID: worklaneID, paneID: paneID)
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

    private func showOpenWithMenu() {
        let menu = makeOpenWithMenu()
        let anchorRect = rootViewController.chromeView.openWithMenuAnchorRect
        let menuLocation = NSPoint(x: anchorRect.minX, y: anchorRect.maxY)
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

    private func rememberOpenWithPrimaryTarget(_ stableID: String) {
        guard configStore.current.openWith.primaryTargetID != stableID else {
            return
        }

        try? configStore.update { config in
            config.openWith.primaryTargetID = stableID
        }
    }

    private func layoutTrafficLights() {
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
                .effectiveLeadingInset(sidebarWidth: config.sidebar.width),
            sizing: PaneLayoutSizing.forSidebarVisibility(config.sidebar.visibility)
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
            return rootViewController.isCommandAvailable(commandID)
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
