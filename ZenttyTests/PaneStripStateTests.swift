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

    func test_width_assignments_use_primary_for_focus_and_secondary_for_neighbors() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor"),
            widthProfile: PaneWidthProfile(primary: 408, secondary: 248)
        )

        let items = state.layoutItems

        XCTAssertEqual(items.map(\.width), [248, 408, 248])
        XCTAssertEqual(items.map(\.isFocused), [false, true, false])
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

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
    }
}
