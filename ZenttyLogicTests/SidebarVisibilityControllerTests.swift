import XCTest
@testable import Zentty

final class SidebarVisibilityControllerTests: AppKitTestCase {
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

    func test_global_search_focus_reveals_hidden_sidebar_as_non_persistent_peek() {
        var controller = SidebarVisibilityController(mode: .hidden)

        controller.handle(.globalSearchFocusEntered)

        XCTAssertEqual(controller.mode, .hoverPeek)
        XCTAssertEqual(controller.persistedMode, .hidden)
        XCTAssertTrue(controller.isFloating)
    }

    func test_global_search_focus_keeps_peek_open_until_focus_released() {
        var controller = SidebarVisibilityController(mode: .hidden)
        controller.handle(.globalSearchFocusEntered)
        controller.handle(.dismissTimerElapsed)

        XCTAssertEqual(controller.mode, .hoverPeek)

        controller.handle(.globalSearchFocusExited)
        controller.handle(.dismissTimerElapsed)

        XCTAssertEqual(controller.mode, .hidden)
        XCTAssertEqual(controller.persistedMode, .hidden)
    }

    func test_effective_leading_inset_is_reserved_only_when_pinned_open() {
        XCTAssertEqual(
            SidebarVisibilityController(mode: .pinnedOpen).effectiveLeadingInset(sidebarWidth: 280),
            280 + ShellMetrics.shellGap,
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

    func test_effective_leading_inset_preserves_available_width_based_sidebar_max() {
        let availableWidth: CGFloat = 1_600
        let resolvedSidebarWidth = SidebarWidthPreference.maximumWidth(for: availableWidth)

        XCTAssertGreaterThan(resolvedSidebarWidth, SidebarWidthPreference.maximumWidth)
        XCTAssertEqual(
            SidebarVisibilityController(mode: .pinnedOpen).effectiveLeadingInset(
                sidebarWidth: resolvedSidebarWidth,
                availableWidth: availableWidth
            ),
            resolvedSidebarWidth + ShellMetrics.shellGap,
            accuracy: 0.001
        )
    }

    func test_resize_handle_is_shown_only_when_pinned_open() {
        XCTAssertTrue(SidebarVisibilityController(mode: .pinnedOpen).showsResizeHandle)
        XCTAssertFalse(SidebarVisibilityController(mode: .hidden).showsResizeHandle)
        XCTAssertFalse(SidebarVisibilityController(mode: .hoverPeek).showsResizeHandle)
    }

    func test_sidebar_transition_profile_caps_standard_duration_under_point_three_seconds() {
        XCTAssertGreaterThan(SidebarTransitionProfile.standardDuration, 0)
        XCTAssertLessThan(SidebarTransitionProfile.standardDuration, 0.3)
    }

    func test_sidebar_transition_profile_uses_shorter_reduced_motion_duration() {
        XCTAssertGreaterThan(SidebarTransitionProfile.reducedMotionDuration, 0)
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

        let tint = SidebarToggleVisuals.contentTintColor(theme: theme, isHovered: false)

        XCTAssertTrue(tint.isDarkThemeColor)
    }

    func test_sidebar_toggle_button_drops_hover_when_superview_moves_away_from_cursor() {
        // Regression: clicking the toggle animates the enclosing
        // LeadingChromeControlsBar's leading constraint — the button's own
        // frame (relative to its superview) does not change. NSTrackingArea
        // also does not synthesize mouseExited when the tracking rect moves
        // under a stationary cursor. The button must reconcile its cached
        // hover flag against the real cursor position when its *superview*
        // moves.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let button = SidebarToggleButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        parent.addSubview(button)

        // Cursor inside bounds → superview frame change reconciles to hovered.
        button.cursorLocationProvider = { NSPoint(x: 14, y: 14) }
        parent.frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertTrue(button.isHovered)

        // Cursor outside bounds → superview frame change reconciles to not
        // hovered, without needing a real mouseExited event.
        button.cursorLocationProvider = { NSPoint(x: -100, y: -100) }
        parent.frame = NSRect(x: 300, y: 100, width: 200, height: 100)
        XCTAssertFalse(button.isHovered)
    }

    func test_inactive_traffic_light_tint_uses_composited_sidebar_surface_when_sidebar_is_pinned_open() {
        let theme = makeTrafficLightTheme()

        let tint = TrafficLightTintResolver.inactiveBezelColor(
            theme: theme,
            sidebarVisibilityMode: .pinnedOpen
        )

        XCTAssertEqual(
            tint.themeToken,
            expectedInactiveTrafficLightTint(
                for: theme,
                sidebarVisibilityMode: .pinnedOpen
            ).themeToken
        )
    }

    func test_inactive_traffic_light_tint_uses_window_background_when_sidebar_is_hidden_or_hover_peek() {
        let theme = makeTrafficLightTheme()
        let expected = expectedInactiveTrafficLightTint(
            for: theme,
            sidebarVisibilityMode: .hidden
        )

        let hiddenTint = TrafficLightTintResolver.inactiveBezelColor(
            theme: theme,
            sidebarVisibilityMode: .hidden
        )
        let hoverPeekTint = TrafficLightTintResolver.inactiveBezelColor(
            theme: theme,
            sidebarVisibilityMode: .hoverPeek
        )

        XCTAssertEqual(hiddenTint.themeToken, expected.themeToken)
        XCTAssertEqual(hoverPeekTint.themeToken, expected.themeToken)
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

    private func makeTrafficLightTheme() -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#111418") ?? .black,
                foreground: NSColor(hexString: "#E7EDF5") ?? .white,
                cursorColor: NSColor(hexString: "#6CB6FF") ?? .systemBlue,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: nil,
                backgroundBlurRadius: 12
            ),
            reduceTransparency: false
        )
    }

    private func expectedInactiveTrafficLightTint(
        for theme: ZenttyTheme,
        sidebarVisibilityMode: SidebarVisibilityMode
    ) -> NSColor {
        switch sidebarVisibilityMode {
        case .pinnedOpen:
            let compositedSidebar = theme.sidebarBackground.composited(over: theme.windowBackground)
            return compositedSidebar.mixed(towards: .black, amount: 0.10)
        case .hidden, .hoverPeek:
            let base = theme.windowBackground.srgbClamped.withAlphaComponent(1)
            let amount: CGFloat = base.isDarkThemeColor ? 0.24 : 0.12
            return base.mixed(towards: .white, amount: amount)
        }
    }
}
