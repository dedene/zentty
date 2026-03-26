import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private var windowController: MainWindowController?

    init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        configStore: AppConfigStore = AppConfigStore()
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistry = runtimeRegistry
        self.configStore = configStore
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenuBuilder.installIfNeeded(on: NSApp)

        guard shouldOpenMainWindow else { return }

        let windowController = MainWindowController(
            runtimeRegistry: runtimeRegistry,
            configStore: configStore
        )
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
