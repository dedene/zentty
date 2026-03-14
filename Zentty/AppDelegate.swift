import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowController = MainWindowController()
        windowController.showWindow(nil)
        self.windowController = windowController
    }
}
