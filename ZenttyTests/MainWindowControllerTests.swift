import XCTest
@testable import Zentty

@MainActor
final class MainWindowControllerTests: XCTestCase {
    func test_main_window_starts_with_expected_content_size() {
        let controller = MainWindowController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let windowFrame = controller.window.frame
        let visibleFrame = controller.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        XCTAssertNil(controller.window.contentViewController)
        XCTAssertNotNil(controller.window.contentView)
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertNotNil(visibleFrame)
        XCTAssertLessThan(windowFrame.width, visibleFrame?.width ?? 0)
        XCTAssertLessThan(windowFrame.height, visibleFrame?.height ?? 0)
    }

    func test_main_window_keeps_resizable_style() {
        let controller = MainWindowController()

        XCTAssertTrue(controller.window.styleMask.contains(.resizable))
    }

    func test_show_window_does_not_reset_manual_frame_changes() {
        let controller = MainWindowController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let window = controller.window

        let manualFrame = NSRect(x: 120, y: 140, width: 1180, height: 760)
        window.setFrame(manualFrame, display: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(window.frame.integral, manualFrame.integral)

        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(window.frame.integral, manualFrame.integral)
    }

    func test_show_window_repositions_traffic_lights_with_comfortable_inset() throws {
        let controller = MainWindowController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let buttonSuperview = try XCTUnwrap(closeButton.superview)
        let topInset = buttonSuperview.bounds.maxY - closeButton.frame.maxY

        XCTAssertEqual(closeButton.frame.minX, ShellMetrics.trafficLightLeadingInset, accuracy: 1.0)
        XCTAssertEqual(topInset, ShellMetrics.trafficLightTopInset, accuracy: 1.0)
    }
}
