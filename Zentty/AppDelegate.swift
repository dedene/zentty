import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Zentty"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSViewController()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
