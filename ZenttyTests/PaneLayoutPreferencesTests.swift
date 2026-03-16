import XCTest
@testable import Zentty

final class PaneLayoutPreferencesTests: XCTestCase {
    override func tearDown() {
        PaneLayoutPreferenceStore.resetForTesting()
        super.tearDown()
    }

    func test_restored_preferences_use_default_presets() {
        let preferences = PaneLayoutPreferenceStore.restoredPreferences(
            from: PaneLayoutPreferenceStore.userDefaultsForTesting()
        )

        XCTAssertEqual(preferences.laptopPreset, .compact)
        XCTAssertEqual(preferences.largeDisplayPreset, .balanced)
    }

    func test_persisted_presets_restore_per_display_class() {
        let defaults = PaneLayoutPreferenceStore.userDefaultsForTesting()

        PaneLayoutPreferenceStore.persist(.roomy, for: .laptop, in: defaults)
        PaneLayoutPreferenceStore.persist(.compact, for: .largeDisplay, in: defaults)

        let preferences = PaneLayoutPreferenceStore.restoredPreferences(from: defaults)

        XCTAssertEqual(preferences.laptopPreset, .roomy)
        XCTAssertEqual(preferences.largeDisplayPreset, .compact)
    }

    func test_display_class_resolution_prefers_screen_width_when_available() {
        let displayClass = PaneDisplayClassResolver.resolve(
            screenWidth: 1728,
            viewportWidth: 1180
        )

        XCTAssertEqual(displayClass, .largeDisplay)
    }

    func test_display_class_resolution_falls_back_to_viewport_width() {
        let displayClass = PaneDisplayClassResolver.resolve(
            screenWidth: nil,
            viewportWidth: 1024
        )

        XCTAssertEqual(displayClass, .laptop)
    }

    func test_layout_context_uses_ratio_based_widths_for_new_panes() {
        let preferences = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced
        )

        let laptopContext = preferences.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let largeDisplayContext = preferences.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1720,
            leadingVisibleInset: 290
        )

        XCTAssertEqual(laptopContext.newPaneWidth, 800, accuracy: 0.001)
        XCTAssertEqual(largeDisplayContext.newPaneWidth, 860, accuracy: 0.001)
    }

    func test_single_pane_width_always_uses_full_readable_width() {
        let preferences = PaneLayoutPreferences(
            laptopPreset: .roomy,
            largeDisplayPreset: .compact
        )

        let laptopContext = preferences.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let largeDisplayContext = preferences.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1720,
            leadingVisibleInset: 290
        )

        XCTAssertEqual(laptopContext.singlePaneWidth, 894, accuracy: 0.001)
        XCTAssertEqual(largeDisplayContext.singlePaneWidth, 1414, accuracy: 0.001)
    }
}
