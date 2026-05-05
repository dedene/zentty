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
        let frame = HostedTestDisplay.centeredFrame(
            forWindowFrame: NSRect(x: 0, y: 0, width: 320, height: 180),
            on: screen
        )

        XCTAssertTrue(
            frame.intersects(screen.visibleFrame),
            "Prepared test windows should land on the requested screen"
        )
    }

    func test_prepareForHostedTesting_does_not_move_window_without_matching_screen() {
        let screen = HostedTestDisplay.screen(named: "ZenttyTests.Missing.\(UUID().uuidString)")

        XCTAssertNil(screen)
    }
}
