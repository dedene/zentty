import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private enum Layout {
        static let windowSize = NSSize(width: 360, height: 456)
    }

    private let aboutViewController: AboutViewController

    init(
        metadata: AboutMetadata = AboutMetadata.load(from: .main),
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        onLicensesRequested: @escaping () -> Void = {},
        appearance: NSAppearance? = nil,
        theme: ZenttyTheme? = nil
    ) {
        let resolvedTheme = theme ?? ZenttyTheme.fallback(for: appearance)
        let aboutViewController = AboutViewController(
            metadata: metadata,
            urlOpener: urlOpener,
            onLicensesRequested: onLicensesRequested,
            theme: resolvedTheme
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Zentty"
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.center()
        window.contentViewController = aboutViewController
        window.setContentSize(Layout.windowSize)
        window.contentMinSize = Layout.windowSize

        self.aboutViewController = aboutViewController
        super.init(window: window)
        aboutViewController.applyAppearance(appearance)
        applyTheme(resolvedTheme)
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

    func applyTheme(_ theme: ZenttyTheme) {
        aboutViewController.applyTheme(theme)
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
