import AppKit
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

        XCTAssertEqual(window.frame.size.width, 576, accuracy: 0.5)
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

    private func makeController(
        urlOpener: @escaping (URL) -> Void = { _ in }
    ) -> AboutWindowController {
        AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            urlOpener: urlOpener
        )
    }

    private func clickButton(titled title: String, in window: NSWindow?) throws {
        let button = try XCTUnwrap(window?.contentView?.firstDescendantButton(titled: title))
        button.performClick(button)
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let expectation = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
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
