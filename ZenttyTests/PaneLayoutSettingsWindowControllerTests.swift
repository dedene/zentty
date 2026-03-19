import XCTest
@testable import Zentty

@MainActor
final class PaneLayoutSettingsWindowControllerTests: XCTestCase {
    func test_settings_window_shows_behavior_labels_and_summary_copy() throws {
        let preferences = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced,
            ultrawidePreset: .balanced
        )
        let controller = PaneLayoutSettingsWindowController(preferences: preferences)

        controller.showWindow(nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? PaneLayoutSettingsViewController
        )
        contentController.loadViewIfNeeded()

        XCTAssertEqual(contentController.sectionTitles, ["Laptop", "Large Display", "Ultrawide Hybrid"])
        XCTAssertEqual(contentController.presetSummary, [
            "Laptop behavior: preserve the active pane, then scroll horizontally.",
            "Large Display behavior: preserve the active pane with slightly denser columns.",
            "Ultrawide Hybrid behavior: first split is 50/50, then keep horizontal scrolling."
        ])
    }
}
