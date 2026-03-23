import XCTest
@testable import Zentty

final class SidebarVisibilityControllerTests: XCTestCase {
    override func tearDown() {
        SidebarVisibilityPreference.reset()
        super.tearDown()
    }

    func test_restored_visibility_defaults_to_pinned_open() {
        let visibility = SidebarVisibilityPreference.restoredVisibility(
            from: SidebarVisibilityPreference.userDefaults()
        )

        XCTAssertEqual(visibility, .pinnedOpen)
    }

    func test_persisted_hidden_visibility_restores_hidden() {
        let defaults = SidebarVisibilityPreference.userDefaults()

        SidebarVisibilityPreference.persist(.hidden, in: defaults)

        XCTAssertEqual(
            SidebarVisibilityPreference.restoredVisibility(from: defaults),
            .hidden
        )
    }

    func test_toggle_cycles_between_pinned_open_and_hidden() {
        var controller = SidebarVisibilityController(mode: .pinnedOpen)

        controller.handle(.togglePressed)
        XCTAssertEqual(controller.mode, .hidden)
        XCTAssertEqual(controller.persistedMode, .hidden)

        controller.handle(.togglePressed)
        XCTAssertEqual(controller.mode, .pinnedOpen)
        XCTAssertEqual(controller.persistedMode, .pinnedOpen)
    }

    func test_hidden_hover_rail_entry_reveals_temporary_peek() {
        var controller = SidebarVisibilityController(mode: .hidden)

        controller.handle(.hoverRailEntered)

        XCTAssertEqual(controller.mode, .hoverPeek)
        XCTAssertEqual(controller.persistedMode, .hidden)
    }

    func test_toggle_from_hover_peek_promotes_to_pinned_open() {
        var controller = SidebarVisibilityController(mode: .hidden)
        controller.handle(.hoverRailEntered)

        controller.handle(.togglePressed)

        XCTAssertEqual(controller.mode, .pinnedOpen)
        XCTAssertEqual(controller.persistedMode, .pinnedOpen)
    }

    func test_dismiss_timer_elapsed_hides_peek_after_pointer_leaves_targets() {
        var controller = SidebarVisibilityController(mode: .hidden)
        controller.handle(.hoverRailEntered)
        controller.handle(.hoverRailExited)

        controller.handle(.dismissTimerElapsed)

        XCTAssertEqual(controller.mode, .hidden)
        XCTAssertEqual(controller.persistedMode, .hidden)
    }

    func test_dismiss_timer_elapsed_does_not_hide_peek_if_pointer_reentered_sidebar() {
        var controller = SidebarVisibilityController(mode: .hidden)
        controller.handle(.hoverRailEntered)
        controller.handle(.hoverRailExited)
        controller.handle(.sidebarEntered)

        controller.handle(.dismissTimerElapsed)

        XCTAssertEqual(controller.mode, .hoverPeek)
        XCTAssertEqual(controller.persistedMode, .hidden)
    }

    func test_effective_leading_inset_is_reserved_only_when_pinned_open() {
        XCTAssertEqual(
            SidebarVisibilityController(mode: .pinnedOpen).effectiveLeadingInset(sidebarWidth: 280),
            288,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarVisibilityController(mode: .hidden).effectiveLeadingInset(sidebarWidth: 280),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarVisibilityController(mode: .hoverPeek).effectiveLeadingInset(sidebarWidth: 280),
            0,
            accuracy: 0.001
        )
    }

    func test_resize_handle_is_shown_only_when_pinned_open() {
        XCTAssertTrue(SidebarVisibilityController(mode: .pinnedOpen).showsResizeHandle)
        XCTAssertFalse(SidebarVisibilityController(mode: .hidden).showsResizeHandle)
        XCTAssertFalse(SidebarVisibilityController(mode: .hoverPeek).showsResizeHandle)
    }

    func test_sidebar_transition_profile_caps_standard_duration_under_point_three_seconds() {
        XCTAssertEqual(SidebarTransitionProfile.standardDuration, 0.24, accuracy: 0.001)
        XCTAssertLessThan(SidebarTransitionProfile.standardDuration, 0.3)
    }

    func test_sidebar_transition_profile_uses_shorter_reduced_motion_duration() {
        XCTAssertEqual(SidebarTransitionProfile.reducedMotionDuration, 0.14, accuracy: 0.001)
        XCTAssertLessThan(SidebarTransitionProfile.reducedMotionDuration, SidebarTransitionProfile.standardDuration)
    }

    func test_sidebar_toggle_visuals_use_dark_tint_on_light_active_background() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F5F1E8") ?? .white,
                foreground: NSColor(hexString: "#1E1C18") ?? .black,
                cursorColor: NSColor(hexString: "#D6A453") ?? .orange,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: nil,
                backgroundBlurRadius: nil
            ),
            reduceTransparency: false
        )

        let tint = SidebarToggleVisuals.contentTintColor(theme: theme, isActive: true)

        XCTAssertTrue(tint.isDarkThemeColor)
    }

    func test_sidebar_toggle_visuals_use_clear_background_and_border_in_all_states() {
        let theme = ZenttyTheme.fallback(for: nil)

        let activeBackground = SidebarToggleVisuals.backgroundColor(theme: theme, isActive: true)
        let inactiveBackground = SidebarToggleVisuals.backgroundColor(theme: theme, isActive: false)
        let activeBorder = SidebarToggleVisuals.borderColor(theme: theme, isActive: true)
        let inactiveBorder = SidebarToggleVisuals.borderColor(theme: theme, isActive: false)

        XCTAssertEqual(activeBackground.srgbClamped.alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(inactiveBackground.srgbClamped.alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(activeBorder.srgbClamped.alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(inactiveBorder.srgbClamped.alphaComponent, 0, accuracy: 0.001)
    }

    func test_sidebar_toggle_icon_factory_falls_back_when_symbol_is_unavailable() {
        let image = SidebarToggleIconFactory.makeImage(symbolProvider: { _, _ -> NSImage? in nil })

        XCTAssertNotNil(image)
        XCTAssertEqual(image.size.width, 15, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 15, accuracy: 0.001)
    }

    @MainActor
    func test_sidebar_toggle_button_configures_active_state() {
        let button = SidebarToggleButton()
        let theme = ZenttyTheme.fallback(for: nil)

        button.configure(theme: theme, isActive: true, animated: false)
        XCTAssertTrue(button.isActive)

        button.configure(theme: theme, isActive: false, animated: false)
        XCTAssertFalse(button.isActive)
    }
}
