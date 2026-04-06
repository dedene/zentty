import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private enum Layout {
        static let windowSize = NSSize(width: 576, height: 544)
    }

    private let aboutViewController: AboutViewController

    init(
        metadata: AboutMetadata = AboutMetadata.load(from: .main),
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        appearance: NSAppearance? = nil
    ) {
        let aboutViewController = AboutViewController(
            metadata: metadata,
            urlOpener: urlOpener
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About Zentty"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = appearance
        window.center()
        window.contentViewController = aboutViewController
        window.setContentSize(Layout.windowSize)
        window.contentMinSize = Layout.windowSize

        self.aboutViewController = aboutViewController
        super.init(window: window)
        aboutViewController.applyAppearance(appearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(sender: Any?) {
        window?.center()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        aboutViewController.applyAppearance(appearance)
    }

    var versionValueForTesting: String { aboutViewController.versionValueForTesting }
    var buildValueForTesting: String { aboutViewController.buildValueForTesting }
    var commitValueForTesting: String { aboutViewController.commitValueForTesting }
    var windowAppearanceMatchForTesting: NSAppearance.Name? {
        window?.appearance?.bestMatch(from: [.darkAqua, .aqua])
    }
    var contentAppearanceMatchForTesting: NSAppearance.Name? {
        aboutViewController.appearanceMatchForTesting
    }
}
