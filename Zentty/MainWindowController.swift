import AppKit

@MainActor
protocol ProxyWindowDragSuppressionControlling: AnyObject {
    var isProxyWindowDragSuppressionActive: Bool { get }
    func restoreProxySuppression()
}

@MainActor
private final class ProxyAwareWindow: NSWindow, ProxyWindowDragSuppressionControlling {
    var shouldSuppressWindowDragAtPoint: ((NSPoint, NSEvent.EventType) -> Bool)?
    var proxyMouseDownHandler: ((NSEvent) -> Void)?
    var isProxyWindowDragSuppressionActive: Bool { didArmProxySuppression }

    private var previousMovableState: Bool?
    private var didArmProxySuppression = false

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
            if didArmProxySuppression, let handler = proxyMouseDownHandler {
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
        guard !didArmProxySuppression else {
            return
        }
        guard shouldSuppressWindowDragAtPoint?(event.locationInWindow, event.type) == true else {
            return
        }

        didArmProxySuppression = true
        previousMovableState = isMovable
        if isMovable {
            isMovable = false
        }
    }

    private func restoreWindowDraggingIfNeeded() {
        defer {
            previousMovableState = nil
            didArmProxySuppression = false
        }

        guard let previousMovableState else {
            return
        }
        if isMovable != previousMovableState {
            isMovable = previousMovableState
        }
    }

    func handleProxySuppressionEventForTesting(location: NSPoint, eventType: NSEvent.EventType) {
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

        switch eventType {
        case .leftMouseDown, .leftMouseDragged:
            if let event {
                maybeSuppressWindowDragging(for: event)
            }
        case .leftMouseUp:
            restoreWindowDraggingIfNeeded()
        default:
            break
        }
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

    let window: NSWindow
    private let rootViewController: RootViewController
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private let openWithService: OpenWithServing
    private let openWithPopoverController = OpenWithPopoverController()
    private var settingsWindowController: SettingsWindowController?
    private let closeTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.close")
    private let miniTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.mini")
    private let zoomTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.zoom")
    private var isApplicationActive = true
    private var isWindowKey = true

    init(
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        configStore: AppConfigStore? = nil,
        openWithService: OpenWithServing = OpenWithService(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard
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
            configStore: resolvedConfigStore,
            openWithService: openWithService,
            runtimeRegistry: runtimeRegistry,
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        rootViewController.view.frame = NSRect(origin: .zero, size: initialFrame.size)
        rootViewController.view.autoresizingMask = [.width, .height]
        window.contentView = rootViewController.view
        if !CommandLine.arguments.contains("-ApplePersistenceIgnoreState") {
            window.setFrameAutosaveName("MainWindow")
        }

        self.rootViewController = rootViewController
        self.runtimeRegistry = runtimeRegistry
        self.configStore = resolvedConfigStore
        self.openWithService = openWithService
        self.window = window
        super.init()
        window.delegate = self
        openWithPopoverController.onSelectTarget = { [weak self] stableID in
            self?.performOpenWithMenuSelection(stableID: stableID)
        }
        openWithPopoverController.onOpenSettings = { [weak self] in
            self?.handleOpenWithSettingsMenuItem(nil)
        }
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
            self?.showSettingsWindow(section: .shortcuts, sender: nil)
        }
        window.shouldSuppressWindowDragAtPoint = { [weak rootViewController] point, eventType in
            rootViewController?.shouldSuppressWindowDrag(at: point, eventType: eventType) == true
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
        window.makeKeyAndOrderFront(sender)
        syncWindowAppearance()
        layoutTrafficLights()
        rootViewController.activateWindowBindingsIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        // The main window is never re-opened after close — destroyAll is a one-way teardown.
        runtimeRegistry.destroyAll()
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
        openWithPopoverController.close()
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
    func focusLeftPane(_ sender: Any?) {
        handle(.pane(.focusLeft))
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rootViewController.navigateToPane(worklaneID: worklaneID, paneID: paneID)
    }

    var anyPaneRequiresQuitConfirmation: Bool {
        rootViewController.anyPaneRequiresQuitConfirmation
    }

    var terminalAppearance: NSAppearance? {
        let theme = rootViewController.currentWindowTheme
        let isDark = theme.windowBackground.isDarkThemeColor
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func syncWindowAppearance() {
        let appearance = terminalAppearance
        window.appearance = appearance
        settingsWindowController?.applyAppearance(appearance)
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
        if openWithPopoverController.isShown {
            openWithPopoverController.close()
            return
        }

        let hasLocalContext = rootViewController.focusedOpenWithContext != nil
        let availableTargets = rootViewController.availableOpenWithTargets
        let items = availableTargets.map {
            OpenWithPopoverItem(
                stableID: $0.stableID,
                title: $0.displayName,
                icon: openWithService.icon(for: $0),
                isEnabled: hasLocalContext,
                isSelected: $0.stableID == rootViewController.primaryOpenWithTarget?.stableID
            )
        }

        openWithPopoverController.show(
            relativeTo: rootViewController.chromeView.openWithMenuAnchorRect,
            of: rootViewController.chromeView,
            theme: rootViewController.currentWindowTheme,
            items: items.isEmpty
                ? [
                    OpenWithPopoverItem(
                        stableID: "__empty__",
                        title: "No enabled installed apps",
                        icon: nil,
                        isEnabled: false,
                        isSelected: false
                    )
                ]
                : items
        )
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

    func performOpenWithPrimaryActionForTesting() {
        performOpenWithPrimaryAction()
    }

    func performOpenWithMenuSelectionForTesting(stableID: String) {
        performOpenWithMenuSelection(stableID: stableID)
    }

    func injectFocusedPaneShellContextForTesting(path: String, scope: PaneShellContextScope = .local) {
        guard let paneID = rootViewController.focusedPaneIDForTesting else {
            return
        }

        rootViewController.applyAgentStatusPayloadForTesting(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
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

    var isOpenWithPopoverShownForTesting: Bool {
        openWithPopoverController.isShown
    }

    var openWithPopoverSelectedStableIDForTesting: String? {
        openWithPopoverController.selectedStableIDForTesting
    }

    var openWithPopoverEnabledStableIDsForTesting: [String] {
        openWithPopoverController.enabledStableIDsForTesting
    }

    var openWithPopoverDisabledStableIDsForTesting: [String] {
        openWithPopoverController.disabledStableIDsForTesting
    }

    var openWithPopoverHighlightedStableIDForTesting: String? {
        openWithPopoverController.highlightedStableIDForTesting
    }

    func shouldSuppressWindowDragForTesting(at point: NSPoint, eventType: NSEvent.EventType) -> Bool {
        rootViewController.shouldSuppressWindowDrag(at: point, eventType: eventType)
    }

    func handleProxySuppressionEventForTesting(location: NSPoint, eventType: NSEvent.EventType) {
        (window as? ProxyAwareWindow)?.handleProxySuppressionEventForTesting(location: location, eventType: eventType)
    }

    var isWindowMovableForTesting: Bool {
        window.isMovable
    }

    func dismissOpenWithPopoverWithEscapeForTesting() {
        openWithPopoverController.dismissWithEscapeForTesting()
    }

    func performOpenWithPopoverOutsideClickDismissalForTesting() {
        openWithPopoverController.performOutsideClickDismissalForTesting()
    }

    func moveOpenWithPopoverSelectionDownForTesting() {
        openWithPopoverController.moveSelectionDownForTesting()
    }

    func activateOpenWithPopoverSelectionForTesting() {
        openWithPopoverController.activateSelectionForTesting()
    }

    func performOpenWithSettingsActionForTesting() {
        openWithPopoverController.performSettingsActionForTesting()
    }

    func simulateOpenWithPopoverRowHoverForTesting(stableID: String) {
        openWithPopoverController.simulateHoverRowForTesting(stableID: stableID)
    }

    func simulateOpenWithPopoverRowExitForTesting(stableID: String) {
        openWithPopoverController.simulateExitRowForTesting(stableID: stableID)
    }

    func simulateOpenWithPopoverSettingsHoverForTesting() {
        openWithPopoverController.simulateHoverSettingsForTesting()
    }

    var openWithPopoverSettingsBackgroundTokenForTesting: String {
        openWithPopoverController.settingsBackgroundTokenForTesting
    }

    var openWithPopoverSettingsBorderTokenForTesting: String {
        openWithPopoverController.settingsBorderTokenForTesting
    }

    func openWithPopoverRowBackgroundTokenForTesting(stableID: String) -> String {
        openWithPopoverController.rowBackgroundTokenForTesting(stableID: stableID)
    }

    func openWithPopoverRowBorderTokenForTesting(stableID: String) -> String {
        openWithPopoverController.rowBorderTokenForTesting(stableID: stableID)
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
