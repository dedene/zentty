import AppKit

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
    private let sidebarWidthDefaults: UserDefaults
    private let sidebarVisibilityDefaults: UserDefaults
    private let paneLayoutDefaults: UserDefaults
    private var settingsWindowController: PaneLayoutSettingsWindowController?
    private let closeTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.close")
    private let miniTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.mini")
    private let zoomTrafficLightOverlay = InactiveTrafficLightOverlayView(identifier: "trafficLightOverlay.zoom")
    private var isApplicationActive = true
    private var isWindowKey = true

    init(
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard
    ) {
        let initialFrame = Self.defaultFrame()
        let initialScreenWidth = NSScreen.main?.visibleFrame.width
        let sidebarVisibility = SidebarVisibilityPreference.restoredVisibility(from: sidebarVisibilityDefaults)
        let initialLayoutContext = Self.initialPaneLayoutContext(
            initialFrame: initialFrame,
            sidebarWidth: SidebarWidthPreference.restoredWidth(
                from: sidebarWidthDefaults,
                availableWidth: initialScreenWidth
            ),
            sidebarVisibility: sidebarVisibility,
            paneLayoutDefaults: paneLayoutDefaults
        )

        let rootViewController = RootViewController(
            runtimeRegistry: runtimeRegistry,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults,
            initialLayoutContext: initialLayoutContext
        )
        rootViewController.loadViewIfNeeded()
        let window = NSWindow(
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

        self.rootViewController = rootViewController
        self.sidebarWidthDefaults = sidebarWidthDefaults
        self.sidebarVisibilityDefaults = sidebarVisibilityDefaults
        self.paneLayoutDefaults = paneLayoutDefaults
        self.window = window
        super.init()
        window.delegate = self
        rootViewController.onWindowChromeNeedsUpdate = { [weak self] in
            self?.updateTrafficLightAppearance()
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
        layoutTrafficLights()
        rootViewController.activateWindowBindingsIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
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
        let controller: PaneLayoutSettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let settingsWindowController = PaneLayoutSettingsWindowController(
                preferences: rootViewController.currentPaneLayoutPreferences
            )
            self.settingsWindowController = settingsWindowController
            controller = settingsWindowController
        }

        controller.update(preferences: rootViewController.currentPaneLayoutPreferences)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc
    func newWorkspace(_ sender: Any?) {
        handle(.newWorkspace)
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

    var workspaceTitles: [String] {
        rootViewController.workspaceTitles
    }

    var activeWorkspaceTitle: String? {
        rootViewController.activeWorkspaceTitle
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

    private func handle(_ action: AppAction) {
        rootViewController.handle(action)
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
        updateTrafficLightAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.updateTrafficLightAppearance()
        }
    }

    private func updateTrafficLightAppearance() {
        let inactiveFillColor = (isWindowKey && isApplicationActive)
            ? nil
            : TrafficLightTintResolver.inactiveBezelColor(
                theme: rootViewController.currentWindowTheme,
                sidebarVisibilityMode: rootViewController.sidebarVisibilityMode
            )

        [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].forEach { button in
            guard let button else {
                return
            }

            button.wantsLayer = true
            button.layer?.masksToBounds = true
            button.layer?.cornerRadius = button.bounds.height / 2
            button.layer?.backgroundColor = nil
            button.layer?.borderWidth = 0
            button.layer?.borderColor = nil
            button.bezelColor = nil
            button.needsDisplay = true
        }

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
        sidebarWidth: CGFloat,
        sidebarVisibility: SidebarVisibilityMode,
        paneLayoutDefaults: UserDefaults
    ) -> PaneLayoutContext {
        let preferences = PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults)
        let viewportWidth = max(1, initialFrame.width - (ShellMetrics.outerInset * 2))
        let displayClass = PaneDisplayClassResolver.resolve(
            screen: NSScreen.main ?? NSScreen.screens.first,
            viewportWidth: viewportWidth
        )

        return preferences.makeLayoutContext(
            displayClass: displayClass,
            viewportWidth: viewportWidth,
            leadingVisibleInset: SidebarVisibilityController(mode: sidebarVisibility)
                .effectiveLeadingInset(sidebarWidth: sidebarWidth),
            sizing: PaneLayoutSizing.forSidebarVisibility(sidebarVisibility)
        )
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
