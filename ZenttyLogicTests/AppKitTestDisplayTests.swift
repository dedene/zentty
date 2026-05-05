import AppKit
import XCTest

@MainActor
final class AppKitTestDisplayTests: AppKitTestCase {
    func test_prepareForAppKitTesting_moves_window_to_configured_screen() throws {
        guard let screenName = AppKitTestDisplay.screenNameFromEnvironment else {
            throw XCTSkip("ZENTTY_TEST_SCREEN_NAME is not set")
        }
        let screen = try XCTUnwrap(AppKitTestDisplay.screen(named: screenName))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }

        XCTAssertTrue(
            window.frame.intersects(screen.visibleFrame),
            "Prepared AppKit test windows should land on \(screenName)"
        )
    }
}
