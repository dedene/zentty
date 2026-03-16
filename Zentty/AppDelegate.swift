import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenuBuilder.installIfNeeded(on: NSApp)

        let windowController = MainWindowController()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.windowController = windowController
    }

    @objc
    func showSettingsWindow(_ sender: Any?) {
        windowController?.showSettingsWindow(sender)
    }

    @objc
    func newWorkspace(_ sender: Any?) {
        windowController?.newWorkspace(sender)
    }

    @objc
    func splitRight(_ sender: Any?) {
        windowController?.splitRight(sender)
    }

    @objc
    func splitLeft(_ sender: Any?) {
        windowController?.splitLeft(sender)
    }

    @objc
    func focusLeftPane(_ sender: Any?) {
        windowController?.focusLeftPane(sender)
    }

    @objc
    func focusRightPane(_ sender: Any?) {
        windowController?.focusRightPane(sender)
    }

    @objc
    func focusFirstPane(_ sender: Any?) {
        windowController?.focusFirstPane(sender)
    }

    @objc
    func focusLastPane(_ sender: Any?) {
        windowController?.focusLastPane(sender)
    }

    var settingsWindowForTesting: NSWindow? {
        windowController?.settingsWindowForTesting
    }
}
