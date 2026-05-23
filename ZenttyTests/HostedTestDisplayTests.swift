import AppKit
import XCTest

@MainActor
final class HostedTestDisplayTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool {
            super.invokeTest()
        }
    }

    func test_prepareForHostedTesting_moves_window_to_named_screen() throws {
        let screenName = HostedTestDisplay.screenNameFromEnvironment
        let screen = try XCTUnwrap(
            HostedTestDisplay.screen(named: screenName) ?? NSScreen.main ?? NSScreen.screens.first
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }
        let originalFrame = window.frame

        window.prepareForHostedTesting(onScreenNamed: screen.localizedName)

        let expectedFrame = HostedTestDisplay.centeredFrame(
            forWindowFrame: originalFrame,
            on: screen
        )

        XCTAssertEqual(window.frame.integral, expectedFrame.integral)
        XCTAssertTrue(window.frame.intersects(screen.visibleFrame), "Prepared test windows should land on the requested screen")
    }

    func test_prepareForHostedTesting_does_not_move_window_without_matching_screen() {
        let screen = HostedTestDisplay.screen(named: "ZenttyTests.Missing.\(UUID().uuidString)")

        XCTAssertNil(screen)
    }

    func test_screenNameMatching_accepts_macos_duplicate_suffix() {
        XCTAssertTrue(HostedTestDisplay.screenName("ZenttyTests (2)", matches: "ZenttyTests"))
        XCTAssertFalse(HostedTestDisplay.screenName("ZenttyTests Backup", matches: "ZenttyTests"))
    }
}
