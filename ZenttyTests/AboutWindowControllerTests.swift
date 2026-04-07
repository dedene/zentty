import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class AboutWindowControllerTests: XCTestCase {
    func test_about_window_uses_expected_chrome_layout_and_metadata() throws {
        let controller = makeController()
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(controller.window?.title, "About Zentty")
        XCTAssertEqual(controller.window?.titleVisibility, .hidden)
        XCTAssertTrue(controller.window?.titlebarAppearsTransparent == true)
        XCTAssertTrue(controller.window?.styleMask.contains(.fullSizeContentView) == true)
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.frame.size.width, 500, accuracy: 0.5)
        XCTAssertEqual(window.frame.size.height, 544, accuracy: 0.5)
        XCTAssertNotNil(controller.window?.contentView?.firstDescendantLabel(stringValue: "Zentty"))
        XCTAssertNotNil(
            controller.window?.contentView?.firstDescendantLabel(
                stringValue: "Zentty is a Ghostty-based native macOS terminal for agent-native development."
            )
        )
        XCTAssertEqual(controller.versionValueForTesting, "1.2.3")
        XCTAssertEqual(controller.buildValueForTesting, "456")
        XCTAssertEqual(controller.commitValueForTesting, "abc1234")
    }

    func test_about_window_applies_injected_appearance() throws {
        let controller = AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            appearance: NSAppearance(named: .darkAqua)
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(controller.windowAppearanceMatchForTesting, .darkAqua)
        XCTAssertEqual(controller.contentAppearanceMatchForTesting, .darkAqua)
    }

    func test_applyAppearance_updates_about_window_and_content_palette() throws {
        let controller = makeController()
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        controller.applyAppearance(NSAppearance(named: .darkAqua))
        waitForLayout("dark appearance applied")

        XCTAssertEqual(controller.windowAppearanceMatchForTesting, .darkAqua)
        XCTAssertEqual(controller.contentAppearanceMatchForTesting, .darkAqua)

        controller.applyAppearance(NSAppearance(named: .aqua))
        waitForLayout("light appearance applied")

        XCTAssertEqual(controller.windowAppearanceMatchForTesting, .aqua)
        XCTAssertEqual(controller.contentAppearanceMatchForTesting, .aqua)
    }

    func test_about_window_applies_injected_theme_to_surface_and_blur() throws {
        let theme = makeTheme(
            background: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.32, alpha: 0.68),
            foreground: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
            cursor: NSColor(srgbRed: 0.34, green: 0.82, blue: 0.66, alpha: 1)
        )
        let runtime = LibghosttyRuntimeProviderSpy()
        let controller = AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            appearance: NSAppearance(named: .darkAqua),
            theme: theme,
            runtime: runtime
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(controller.surfaceBackgroundTokenForTesting, theme.windowBackground.themeToken)
        XCTAssertEqual(controller.docsButtonBackgroundTokenForTesting, theme.openWithChromeBackground.themeToken)
        XCTAssertEqual(controller.docsButtonTextColorTokenForTesting, theme.openWithChromePrimaryTint.themeToken)
        XCTAssertEqual(runtime.blurredWindows, [try XCTUnwrap(controller.window)])
    }

    func test_applyTheme_updates_open_about_window_live() throws {
        let initialTheme = makeTheme(
            background: NSColor(srgbRed: 0.17, green: 0.20, blue: 0.28, alpha: 0.72),
            foreground: NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1),
            cursor: NSColor(srgbRed: 0.28, green: 0.62, blue: 0.97, alpha: 1)
        )
        let updatedTheme = makeTheme(
            background: NSColor(srgbRed: 0.72, green: 0.82, blue: 0.89, alpha: 0.80),
            foreground: NSColor(srgbRed: 0.11, green: 0.15, blue: 0.19, alpha: 1),
            cursor: NSColor(srgbRed: 0.92, green: 0.48, blue: 0.18, alpha: 1)
        )
        let runtime = LibghosttyRuntimeProviderSpy()
        let controller = AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            appearance: NSAppearance(named: .darkAqua),
            theme: initialTheme,
            runtime: runtime
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        let initialSurfaceToken = controller.surfaceBackgroundTokenForTesting
        let initialCommitToken = controller.commitColorTokenForTesting
        let initialButtonBackgroundToken = controller.docsButtonBackgroundTokenForTesting

        controller.applyTheme(updatedTheme)
        waitForLayout("theme updated")

        XCTAssertEqual(controller.surfaceBackgroundTokenForTesting, updatedTheme.windowBackground.themeToken)
        XCTAssertNotEqual(controller.surfaceBackgroundTokenForTesting, initialSurfaceToken)
        XCTAssertNotEqual(controller.commitColorTokenForTesting, initialCommitToken)
        XCTAssertEqual(controller.docsButtonBackgroundTokenForTesting, updatedTheme.openWithChromeBackground.themeToken)
        XCTAssertNotEqual(controller.docsButtonBackgroundTokenForTesting, initialButtonBackgroundToken)
        XCTAssertEqual(runtime.blurredWindows.count, 2)
    }

    func test_github_button_opens_repository_url() throws {
        var openedURLs: [URL] = []
        let controller = makeController { openedURLs.append($0) }
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        try clickButton(titled: "GitHub", in: controller.window)

        XCTAssertEqual(openedURLs, [try XCTUnwrap(URL(string: "https://github.com/dedene/zentty"))])
    }

    func test_placeholder_buttons_do_not_open_urls_yet() throws {
        var openedURLs: [URL] = []
        let controller = makeController { openedURLs.append($0) }
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        try clickButton(titled: "Docs", in: controller.window)
        try clickButton(titled: "Licenses", in: controller.window)

        XCTAssertTrue(openedURLs.isEmpty)
    }

    func test_about_buttons_do_not_draw_native_button_title() throws {
        let controller = makeController()
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        let button = try findButton(titled: "GitHub", in: controller.window)

        XCTAssertEqual(button.attributedTitle.string, "")
    }

    func test_about_action_buttons_hide_native_button_title_and_keep_accessible_label() throws {
        let controller = makeController()
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        let button = try XCTUnwrap(controller.window?.contentView?.firstDescendantButton(titled: "GitHub"))

        XCTAssertEqual(button.attributedTitle.string, "")
        XCTAssertEqual(button.accessibilityLabel(), "GitHub")
    }

    private func makeController(
        urlOpener: @escaping (URL) -> Void = { _ in }
    ) -> AboutWindowController {
        AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            urlOpener: urlOpener
        )
    }

    private func makeTheme(
        background: NSColor,
        foreground: NSColor,
        cursor: NSColor
    ) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: background,
                foreground: foreground,
                cursorColor: cursor,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: background.alphaComponent,
                backgroundBlurRadius: 22
            ),
            reduceTransparency: false
        )
    }

    private func clickButton(titled title: String, in window: NSWindow?) throws {
        let button = try findButton(titled: title, in: window)
        button.performClick(button)
    }

    private func findButton(titled title: String, in window: NSWindow?) throws -> NSButton {
        try XCTUnwrap(window?.contentView?.firstDescendantButton(titled: title))
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let expectation = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}

@MainActor
private final class LibghosttyRuntimeProviderSpy: LibghosttyRuntimeProviding {
    private(set) var blurredWindows: [NSWindow] = []

    func makeSurface(
        for hostView: LibghosttyView,
        paneID: PaneID,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        fatalError("Not used in AboutWindowControllerTests")
    }

    func reloadConfig() {}

    func applyBackgroundBlur(to window: NSWindow) {
        blurredWindows.append(window)
    }
}

private extension NSView {
    func firstDescendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }

        for subview in subviews {
            if let match = subview.firstDescendantButton(titled: title) {
                return match
            }
        }

        return nil
    }

    func firstDescendantLabel(stringValue: String) -> NSTextField? {
        if let label = self as? NSTextField, label.stringValue == stringValue {
            return label
        }

        for subview in subviews {
            if let match = subview.firstDescendantLabel(stringValue: stringValue) {
                return match
            }
        }

        return nil
    }
}
