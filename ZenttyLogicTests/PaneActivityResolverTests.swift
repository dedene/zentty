import XCTest
@testable import Zentty

final class PaneActivityResolverTests: XCTestCase {
    // MARK: - Tile (unchanged behaviour)

    func test_tile_in_active_worklane_is_visible_and_focused_when_window_is_key() {
        XCTAssertEqual(
            resolve(.tile),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: true)
        )
    }

    func test_tile_not_focused_when_it_is_not_the_focused_pane() {
        XCTAssertEqual(
            resolve(.tile, isFocusedPane: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: false)
        )
    }

    func test_tile_not_focused_when_window_is_not_key() {
        XCTAssertEqual(
            resolve(.tile, windowIsKey: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: false)
        )
    }

    func test_tile_occluded_when_window_is_hidden() {
        XCTAssertEqual(
            resolve(.tile, windowIsVisible: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_tile_in_inactive_worklane_is_occluded() {
        XCTAssertEqual(
            resolve(.tile, isActiveWorklane: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_tile_in_peek_visible_worklane_is_visible_but_not_focused() {
        XCTAssertEqual(
            resolve(.tile, isActiveWorklane: false, isPeekVisible: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: false)
        )
    }

    func test_tile_ignores_floatsHidden() {
        XCTAssertEqual(
            resolve(.tile, floatsHidden: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: true)
        )
    }

    // MARK: - Floating

    func test_floating_in_active_worklane_is_visible_and_focused() {
        XCTAssertEqual(
            resolve(.floating),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: true)
        )
    }

    func test_hidden_float_not_visible() {
        XCTAssertEqual(
            resolve(.floating, floatsHidden: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_floating_in_peek_visible_neighbour_stays_occluded() {
        // Peek previews render the strip only; floats of a neighbour lane are not drawn.
        XCTAssertEqual(
            resolve(.floating, isActiveWorklane: false, isPeekVisible: true, isFocusedPane: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_floating_occluded_when_window_is_hidden() {
        XCTAssertEqual(
            resolve(.floating, windowIsVisible: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    // MARK: - PiP

    func test_pip_visible_in_active_worklane() {
        XCTAssertEqual(
            resolve(.pip, isFocusedPane: false),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: false)
        )
    }

    func test_pip_never_focused() {
        XCTAssertEqual(
            resolve(.pip, isFocusedPane: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: false)
        )
    }

    func test_hidden_pip_not_visible() {
        XCTAssertEqual(
            resolve(.pip, floatsHidden: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    // MARK: - Peek open

    func test_floating_not_visible_while_peek_open() {
        XCTAssertEqual(
            resolve(.floating, isPeekOpen: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_pip_not_visible_while_peek_open() {
        XCTAssertEqual(
            resolve(.pip, isFocusedPane: false, isPeekOpen: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_tile_unaffected_by_peek_open() {
        XCTAssertEqual(
            resolve(.tile, isPeekOpen: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: true, isFocused: true)
        )
    }

    // MARK: - Minimized

    func test_minimized_never_visible_even_when_window_becomes_key() {
        XCTAssertEqual(
            resolve(.minimized, windowIsVisible: true, windowIsKey: true, isFocusedPane: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_minimized_stays_occluded_while_peek_shows_its_worklane() {
        XCTAssertEqual(
            resolve(.minimized, isActiveWorklane: false, isPeekVisible: true),
            TerminalSurfaceActivity(keepsRuntimeLive: true, isVisible: false, isFocused: false)
        )
    }

    func test_every_mode_keeps_runtime_live() {
        let modes: [PanePresentationMode] = [.tile, .floating, .pip, .minimized]
        for mode in modes {
            for hidden in [false, true] {
                for active in [false, true] {
                    XCTAssertTrue(
                        resolve(mode, floatsHidden: hidden, isActiveWorklane: active).keepsRuntimeLive,
                        "\(mode) hidden=\(hidden) active=\(active)"
                    )
                }
            }
        }
    }

    // MARK: - Mode mapping

    func test_presentation_mode_maps_float_modes() {
        XCTAssertEqual(PanePresentationMode(.floating), .floating)
        XCTAssertEqual(PanePresentationMode(.pip(corner: .topLeft, order: 0)), .pip)
        XCTAssertEqual(PanePresentationMode(.minimized(order: 2)), .minimized)
    }

    // MARK: - Helpers

    private func resolve(
        _ mode: PanePresentationMode,
        floatsHidden: Bool = false,
        isActiveWorklane: Bool = true,
        isPeekVisible: Bool = false,
        windowIsVisible: Bool = true,
        windowIsKey: Bool = true,
        isFocusedPane: Bool = true,
        isPeekOpen: Bool = false
    ) -> TerminalSurfaceActivity {
        PaneActivityResolver.activity(
            for: PaneActivityInput(
                mode: mode,
                floatsHidden: floatsHidden,
                isActiveWorklane: isActiveWorklane,
                isPeekVisible: isPeekVisible,
                windowIsVisible: windowIsVisible,
                windowIsKey: windowIsKey,
                isFocusedPane: isFocusedPane,
                isPeekOpen: isPeekOpen
            )
        )
    }
}
