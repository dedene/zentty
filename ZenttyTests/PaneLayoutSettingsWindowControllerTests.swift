import XCTest
@testable import Zentty

@MainActor
final class PaneLayoutSettingsWindowControllerTests: XCTestCase {
    func test_settings_window_shows_both_display_classes_and_selected_presets() throws {
        let controller = PaneLayoutSettingsWindowController(
            preferences: PaneLayoutPreferences(
                laptopPreset: .compact,
                largeDisplayPreset: .roomy
            ),
            onUpdate: { _, _ in }
        )

        controller.showWindow(nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? PaneLayoutSettingsViewController
        )
        contentController.loadViewIfNeeded()

        XCTAssertEqual(contentController.sectionTitlesForTesting, ["Laptop", "Large Display"])
        XCTAssertEqual(contentController.selectedPresetTitlesForTesting, ["Compact", "Roomy"])
    }
}
