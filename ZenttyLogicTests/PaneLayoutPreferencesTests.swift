import XCTest
@testable import Zentty

final class PaneLayoutPreferencesTests: XCTestCase {
    override func tearDown() {
        PaneLayoutPreferenceStore.reset()
        super.tearDown()
    }

    func test_restored_preferences_use_default_presets() {
        let preferences = PaneLayoutPreferenceStore.restoredPreferences(
            from: PaneLayoutPreferenceStore.userDefaults()
        )

        XCTAssertEqual(preferences.laptopPreset, .compact)
        XCTAssertEqual(preferences.largeDisplayPreset, .balanced)
        XCTAssertEqual(preferences.ultrawidePreset, .balanced)
    }

    func test_display_class_titles_use_behavior_labels() {
        XCTAssertEqual(DisplayClass.laptop.title, "Laptop")
        XCTAssertEqual(DisplayClass.largeDisplay.title, "Large Display")
        XCTAssertEqual(DisplayClass.ultrawide.title, "Ultrawide Hybrid")
    }

    func test_persisted_presets_restore_per_display_class() {
        let defaults = PaneLayoutPreferenceStore.userDefaults()

        PaneLayoutPreferenceStore.persist(.roomy, for: .laptop, in: defaults)
        PaneLayoutPreferenceStore.persist(.compact, for: .largeDisplay, in: defaults)
        PaneLayoutPreferenceStore.persist(.compact, for: .ultrawide, in: defaults)

        let preferences = PaneLayoutPreferenceStore.restoredPreferences(from: defaults)

        XCTAssertEqual(preferences.laptopPreset, .roomy)
        XCTAssertEqual(preferences.largeDisplayPreset, .compact)
        XCTAssertEqual(preferences.ultrawidePreset, .compact)
    }

    func test_display_class_resolution_uses_viewport_width_even_when_screen_is_wider() {
        let displayClass = PaneDisplayClassResolver.resolve(
            screenWidth: 1728,
            viewportWidth: 1180
        )

        XCTAssertEqual(displayClass, .laptop)
    }

    func test_display_class_resolution_uses_viewport_ultrawide_threshold() {
        let displayClass = PaneDisplayClassResolver.resolve(
            screenWidth: 3440,
            viewportWidth: 2880
        )

        XCTAssertEqual(displayClass, .ultrawide)
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
            largeDisplayPreset: .balanced,
            ultrawidePreset: .compact
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
        let ultrawideContext = preferences.makeLayoutContext(
            displayClass: .ultrawide,
            viewportWidth: 3440,
            leadingVisibleInset: 290
        )

        XCTAssertEqual(laptopContext.newPaneWidth, 606.667, accuracy: 0.001)
        XCTAssertEqual(largeDisplayContext.newPaneWidth, 715, accuracy: 0.001)
        XCTAssertEqual(ultrawideContext.newPaneWidth, 1260, accuracy: 0.001)
    }

    func test_first_split_is_resized_only_for_ultrawide_display_class() {
        let preferences = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced,
            ultrawidePreset: .roomy
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
        let ultrawideContext = preferences.makeLayoutContext(
            displayClass: .ultrawide,
            viewportWidth: 3440,
            leadingVisibleInset: 290
        )

        XCTAssertNil(laptopContext.firstPaneWidthAfterSingleSplit)
        XCTAssertNil(largeDisplayContext.firstPaneWidthAfterSingleSplit)
        XCTAssertEqual(ultrawideContext.firstPaneWidthAfterSingleSplit ?? 0, 1572, accuracy: 0.001)

        XCTAssertEqual(laptopContext.newPaneWidth(existingPaneCount: 1), 606.667, accuracy: 0.001)
        XCTAssertEqual(largeDisplayContext.newPaneWidth(existingPaneCount: 1), 715, accuracy: 0.001)
        XCTAssertEqual(ultrawideContext.newPaneWidth(existingPaneCount: 1), 1572, accuracy: 0.001)
    }

    func test_single_pane_width_always_uses_full_readable_width() {
        let preferences = PaneLayoutPreferences(
            laptopPreset: .roomy,
            largeDisplayPreset: .compact,
            ultrawidePreset: .compact
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
        let ultrawideContext = preferences.makeLayoutContext(
            displayClass: .ultrawide,
            viewportWidth: 3440,
            leadingVisibleInset: 290
        )

        XCTAssertEqual(laptopContext.singlePaneWidth, 910, accuracy: 0.001)
        XCTAssertEqual(largeDisplayContext.singlePaneWidth, 1430, accuracy: 0.001)
        XCTAssertEqual(ultrawideContext.singlePaneWidth, 3150, accuracy: 0.001)
    }

    func test_sidebar_visibility_uses_shared_edge_aligned_layout_sizing_in_all_states() {
        XCTAssertEqual(PaneLayoutSizing.forSidebarVisibility(.pinnedOpen), .edgeAligned)
        XCTAssertEqual(PaneLayoutSizing.forSidebarVisibility(.hidden), .edgeAligned)
        XCTAssertEqual(PaneLayoutSizing.forSidebarVisibility(.hoverPeek), .edgeAligned)
    }
}
