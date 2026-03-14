import XCTest
@testable import Zentty

final class PaneStripStateTests: XCTestCase {
    func test_initial_focus_defaults_to_first_pane() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ]
        )

        XCTAssertEqual(state.focusedPane?.title, "logs")
        XCTAssertEqual(state.focusedIndex, 0)
    }

    func test_insert_after_focused_places_new_pane_adjacent_and_focuses_it() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        state.insertPane(makePane("shell"), placement: .afterFocused)

        XCTAssertEqual(state.panes.map(\.title), ["logs", "editor", "shell", "tests"])
        XCTAssertEqual(state.focusedPane?.title, "shell")
        XCTAssertEqual(state.focusedIndex, 2)
    }

    func test_insert_before_focused_places_new_pane_adjacent_and_focuses_it() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        state.insertPane(makePane("shell"), placement: .beforeFocused)

        XCTAssertEqual(state.panes.map(\.title), ["logs", "shell", "editor", "tests"])
        XCTAssertEqual(state.focusedPane?.title, "shell")
        XCTAssertEqual(state.focusedIndex, 1)
    }

    func test_close_focused_pane_prefers_right_neighbor_when_available() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
                makePane("shell"),
            ],
            focusedPaneID: PaneID("editor")
        )

        let closedPane = state.closeFocusedPane()

        XCTAssertEqual(closedPane?.title, "editor")
        XCTAssertEqual(state.panes.map(\.title), ["logs", "tests", "shell"])
        XCTAssertEqual(state.focusedPane?.title, "tests")
        XCTAssertEqual(state.focusedIndex, 1)
    }

    func test_close_last_focused_pane_falls_back_to_left_neighbor() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        let closedPane = state.closeFocusedPane()

        XCTAssertEqual(closedPane?.title, "tests")
        XCTAssertEqual(state.panes.map(\.title), ["logs", "editor"])
        XCTAssertEqual(state.focusedPane?.title, "editor")
        XCTAssertEqual(state.focusedIndex, 1)
    }

    func test_wide_layout_clamps_pane_width_to_maximum() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        let items = state.layoutItems(in: CGSize(width: 2200, height: 780))
        XCTAssertEqual(items[0].width, 1087, accuracy: 0.001)
        XCTAssertEqual(items[1].width, 1087, accuracy: 0.001)
        XCTAssertEqual(items[2].width, 1087, accuracy: 0.001)
    }

    func test_narrow_layout_clamps_pane_width_to_minimum() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        let items = state.layoutItems(in: CGSize(width: 560, height: 780))
        XCTAssertEqual(items[0].width, PaneLayoutSizing.balanced.minimumPaneWidth)
        XCTAssertEqual(items[1].width, PaneLayoutSizing.balanced.minimumPaneWidth)
        XCTAssertEqual(items[2].width, PaneLayoutSizing.balanced.minimumPaneWidth)
    }

    func test_layout_uses_one_stable_pane_width_across_focus_states() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let otherFocusedState = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        let compactItems = state.layoutItems(in: CGSize(width: 960, height: 780))
        let shiftedFocusItems = otherFocusedState.layoutItems(in: CGSize(width: 960, height: 780))

        XCTAssertEqual(compactItems.map(\.width), shiftedFocusItems.map(\.width))
        XCTAssertEqual(Set(compactItems.map(\.width)).count, 1)
        XCTAssertEqual(compactItems.map(\.isFocused), [false, true, false])
        XCTAssertEqual(shiftedFocusItems.map(\.isFocused), [false, false, true])
    }

    func test_single_pane_uses_full_available_width() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
            ],
            focusedPaneID: PaneID("shell")
        )

        let items = state.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].width, 1184, accuracy: 0.001)
    }

    func test_multi_pane_uses_half_width_by_default_like_niri_columns() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        let items = state.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(items[0].width, 587, accuracy: 0.001)
        XCTAssertEqual(items[1].width, 587, accuracy: 0.001)
    }

    func test_two_pane_layout_preserves_symmetric_outer_margins() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        let items = state.layoutItems(in: CGSize(width: 1200, height: 780))
        let sizing = PaneLayoutSizing.balanced
        let totalWidth = items.map(\.width).reduce(0, +) + sizing.interPaneSpacing
        let contentWidth = 1200 - (sizing.horizontalInset * 2)

        XCTAssertEqual(totalWidth, contentWidth, accuracy: 0.001)
    }

    func test_layout_height_expands_with_container_height() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        let compactItems = state.layoutItems(in: CGSize(width: 1200, height: 520))
        let tallItems = state.layoutItems(in: CGSize(width: 1200, height: 820))

        XCTAssertLessThan(compactItems[1].height, tallItems[1].height)
        XCTAssertGreaterThan(tallItems[1].height, 360)
    }

    func test_move_focus_commands_stop_at_strip_edges() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ]
        )

        state.moveFocusLeft()
        XCTAssertEqual(state.focusedPane?.title, "logs")

        state.moveFocusRight()
        XCTAssertEqual(state.focusedPane?.title, "editor")

        state.moveFocusRight()
        XCTAssertEqual(state.focusedPane?.title, "tests")

        state.moveFocusRight()
        XCTAssertEqual(state.focusedPane?.title, "tests")

        state.moveFocusToFirst()
        XCTAssertEqual(state.focusedPane?.title, "logs")

        state.moveFocusToLast()
        XCTAssertEqual(state.focusedPane?.title, "tests")
    }

    func test_focus_pane_ignores_unknown_ids() {
        var state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ]
        )

        state.focusPane(id: PaneID("missing"))

        XCTAssertEqual(state.focusedPane?.title, "logs")
    }

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
    }
}
