import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WindowChromeTitlebarGestureTests: AppKitTestCase {
    // MARK: - Resolver

    func test_single_click_stays_a_window_drag() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 1, isFullscreen: false, doubleClickActionPreference: "Maximize"),
            .windowDrag
        )
    }

    func test_double_click_resolves_maximize_preference_to_zoom() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Maximize"),
            .zoom
        )
    }

    func test_double_click_defaults_to_zoom_without_or_with_unknown_preference() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: nil),
            .zoom
        )
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Unrecognized"),
            .zoom
        )
    }

    func test_double_click_resolves_fill_preference_to_fill() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Fill"),
            .fill
        )
    }

    func test_double_click_resolves_minimize_preference_to_miniaturize() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "Minimize"),
            .miniaturize
        )
    }

    func test_double_click_with_none_preference_still_drags_the_window() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: false, doubleClickActionPreference: "None"),
            .windowDrag
        )
    }

    func test_double_click_in_fullscreen_still_drags_the_window() {
        XCTAssertEqual(
            WindowChromeTitlebarGesture.resolve(clickCount: 2, isFullscreen: true, doubleClickActionPreference: "Maximize"),
            .windowDrag
        )
    }
}
