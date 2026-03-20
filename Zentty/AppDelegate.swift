import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let runtimeRegistry: PaneRuntimeRegistry
    private var windowController: MainWindowController?

    init(shouldOpenMainWindow: Bool = true, runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry()) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistry = runtimeRegistry
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenuBuilder.installIfNeeded(on: NSApp)

        guard shouldOpenMainWindow else { return }

        let windowController = MainWindowController(runtimeRegistry: runtimeRegistry)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.windowController = windowController
    }

    @objc
    func showSettingsWindow(_ sender: Any?) {
        windowController?.showSettingsWindow(sender)
    }

    #if DEBUG
    var settingsWindow: NSWindow? {
        windowController?.settingsWindow
    }
    #endif
}
