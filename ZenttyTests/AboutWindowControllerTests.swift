import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AboutWindowControllerTests: XCTestCase {
    func test_about_window_uses_native_chrome_layout_and_metadata() throws {
        let controller = makeController()
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(controller.window?.title, "About Zentty")
        XCTAssertEqual(controller.window?.titleVisibility, .visible)
        XCTAssertFalse(controller.window?.titlebarAppearsTransparent == true)
        XCTAssertFalse(controller.window?.styleMask.contains(.fullSizeContentView) == true)
        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)

        XCTAssertEqual(contentView.bounds.size.width, 360, accuracy: 0.5)
        XCTAssertEqual(contentView.bounds.size.height, 456, accuracy: 0.5)
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

    func test_docs_button_opens_docs_url() throws {
        var openedURLs: [URL] = []
        let controller = makeController { openedURLs.append($0) }
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        try clickButton(titled: "Docs", in: controller.window)

        XCTAssertEqual(openedURLs, [try XCTUnwrap(URL(string: "https://zentty.org/docs"))])
    }

    func test_licenses_button_opens_dedicated_licenses_window() throws {
        let licensesWindowController = LicensesWindowController()
        let controller = makeController(onLicensesRequested: {
            licensesWindowController.show(sender: nil)
        })
        addTeardownBlock { controller.window?.close() }
        addTeardownBlock { licensesWindowController.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        try clickButton(titled: "Licenses", in: controller.window)
        waitForLayout("licenses window opened")

        let licensesWindow = try XCTUnwrap(licensesWindowController.window)
        XCTAssertTrue(licensesWindow.isVisible)
        XCTAssertEqual(licensesWindow.title, "Third-Party Licenses")
    }

    private func makeController(
        urlOpener: @escaping (URL) -> Void = { _ in },
        onLicensesRequested: @escaping () -> Void = {}
    ) -> AboutWindowController {
        AboutWindowController(
            metadata: AboutMetadata(version: "1.2.3", build: "456", commit: "abc1234"),
            urlOpener: urlOpener,
            onLicensesRequested: onLicensesRequested
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
