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
    private let paneLayoutDefaults: UserDefaults
    private var settingsWindowController: PaneLayoutSettingsWindowController?

    override init() {
        let initialFrame = Self.defaultFrame()
        let paneLayoutDefaults = UserDefaults.standard
        let initialLayoutContext = Self.initialPaneLayoutContext(
            initialFrame: initialFrame,
            sidebarWidth: SidebarWidthPreference.restoredWidth(from: .standard),
            paneLayoutDefaults: paneLayoutDefaults
        )

        let rootViewController = RootViewController(
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
        self.paneLayoutDefaults = paneLayoutDefaults
        self.window = window
        super.init()
        window.delegate = self
    }

    func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(sender)
        layoutTrafficLights()
        rootViewController.activateWindowBindingsIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
    }

    func showSettingsWindow(_ sender: Any?) {
        let controller: PaneLayoutSettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let settingsWindowController = PaneLayoutSettingsWindowController(
                preferences: rootViewController.paneLayoutPreferencesForTesting,
                onUpdate: { [weak self] displayClass, preset in
                    guard let self else {
                        return
                    }

                    var preferences = self.rootViewController.paneLayoutPreferencesForTesting
                    switch displayClass {
                    case .laptop:
                        preferences.laptopPreset = preset
                    case .largeDisplay:
                        preferences.largeDisplayPreset = preset
                    }
                    self.rootViewController.updatePaneLayoutPreferences(preferences)
                    self.settingsWindowController?.update(preferences: preferences)
                }
            )
            self.settingsWindowController = settingsWindowController
            controller = settingsWindowController
        }

        controller.update(preferences: rootViewController.paneLayoutPreferencesForTesting)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc
    func newWorkspace(_ sender: Any?) {
        handle(.newWorkspace)
    }

    @objc
    func splitRight(_ sender: Any?) {
        handle(.pane(.splitAfterFocusedPane))
    }

    @objc
    func splitLeft(_ sender: Any?) {
        handle(.pane(.splitBeforeFocusedPane))
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
    func focusFirstPane(_ sender: Any?) {
        handle(.pane(.focusFirst))
    }

    @objc
    func focusLastPane(_ sender: Any?) {
        handle(.pane(.focusLast))
    }

    var settingsWindowForTesting: NSWindow? {
        settingsWindowController?.window
    }

    var workspaceTitlesForTesting: [String] {
        rootViewController.workspaceTitlesForTesting
    }

    var activeWorkspaceTitleForTesting: String? {
        rootViewController.activeWorkspaceTitleForTesting
    }

    var activePaneTitlesForTesting: [String] {
        rootViewController.activePaneTitlesForTesting
    }

    var focusedPaneTitleForTesting: String? {
        rootViewController.focusedPaneTitleForTesting
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
            leadingVisibleInset: sidebarWidth + ShellMetrics.shellGap
        )
    }
}
