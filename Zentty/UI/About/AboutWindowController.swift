import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private enum Layout {
        static let windowSize = NSSize(width: 500, height: 544)
    }

    private let aboutViewController: AboutViewController
    private let runtime: any LibghosttyRuntimeProviding

    init(
        metadata: AboutMetadata = AboutMetadata.load(from: .main),
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        appearance: NSAppearance? = nil,
        theme: ZenttyTheme? = nil,
        runtime: any LibghosttyRuntimeProviding = LibghosttyRuntime.shared
    ) {
        let resolvedTheme = theme ?? ZenttyTheme.fallback(for: appearance)
        let aboutViewController = AboutViewController(
            metadata: metadata,
            urlOpener: urlOpener,
            theme: resolvedTheme
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
        self.runtime = runtime
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
        if let window {
            runtime.applyBackgroundBlur(to: window)
        }
    }

    var versionValueForTesting: String { aboutViewController.versionValueForTesting }
    var buildValueForTesting: String { aboutViewController.buildValueForTesting }
    var commitValueForTesting: String { aboutViewController.commitValueForTesting }
    var surfaceBackgroundTokenForTesting: String { aboutViewController.surfaceBackgroundTokenForTesting }
    var commitColorTokenForTesting: String { aboutViewController.commitColorTokenForTesting }
    var docsButtonBackgroundTokenForTesting: String { aboutViewController.docsButtonBackgroundTokenForTesting }
    var docsButtonTextColorTokenForTesting: String { aboutViewController.docsButtonTextColorTokenForTesting }
    var windowAppearanceMatchForTesting: NSAppearance.Name? {
        window?.appearance?.bestMatch(from: [.darkAqua, .aqua])
    }
    var contentAppearanceMatchForTesting: NSAppearance.Name? {
        aboutViewController.appearanceMatchForTesting
    }
}
