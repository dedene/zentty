import XCTest
@testable import Zentty

final class PaneStripStateTests: XCTestCase {
    func test_initial_focus_defaults_to_first_pane() {
        let state = PaneStripState(
            panes: [
                makePane("logs", width: 920),
                makePane("editor", width: 760),
                makePane("tests", width: 760),
            ]
        )

        XCTAssertEqual(state.focusedPane?.title, "logs")
        XCTAssertEqual(state.focusedIndex, 0)
    }

    func test_insert_after_focused_places_new_pane_adjacent_and_focuses_it() {
        var state = PaneStripState(
            panes: [
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 760),
            ],
            focusedPaneID: PaneID("editor")
        )

        state.insertPane(makePane("shell", width: 820), placement: .afterFocused)

        XCTAssertEqual(state.panes.map(\.title), ["logs", "editor", "shell", "tests"])
        XCTAssertEqual(state.focusedPane?.title, "shell")
        XCTAssertEqual(state.focusedIndex, 2)
        XCTAssertEqual(state.panes.map(\.width), [1040, 760, 820, 760])
    }

    func test_insert_before_focused_places_new_pane_adjacent_and_focuses_it() {
        var state = PaneStripState(
            panes: [
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 760),
            ],
            focusedPaneID: PaneID("editor")
        )

        state.insertPane(makePane("shell", width: 820), placement: .beforeFocused)

        XCTAssertEqual(state.panes.map(\.title), ["logs", "shell", "editor", "tests"])
        XCTAssertEqual(state.focusedPane?.title, "shell")
        XCTAssertEqual(state.focusedIndex, 1)
        XCTAssertEqual(state.panes.map(\.width), [1040, 820, 760, 760])
    }

    func test_close_focused_pane_prefers_right_neighbor_when_available() {
        var state = PaneStripState(
            panes: [
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 760),
                makePane("shell", width: 820),
            ],
            focusedPaneID: PaneID("editor")
        )

        let closedPane = state.closeFocusedPane()

        XCTAssertEqual(closedPane?.title, "editor")
        XCTAssertEqual(state.panes.map(\.title), ["logs", "tests", "shell"])
        XCTAssertEqual(state.focusedPane?.title, "tests")
        XCTAssertEqual(state.focusedIndex, 1)
        XCTAssertEqual(state.panes.map(\.width), [1040, 760, 820])
    }

    func test_close_last_focused_pane_falls_back_to_left_neighbor() {
        var state = PaneStripState(
            panes: [
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 820),
            ],
            focusedPaneID: PaneID("tests")
        )

        let closedPane = state.closeFocusedPane()

        XCTAssertEqual(closedPane?.title, "tests")
        XCTAssertEqual(state.panes.map(\.title), ["logs", "editor"])
        XCTAssertEqual(state.focusedPane?.title, "editor")
        XCTAssertEqual(state.focusedIndex, 1)
        XCTAssertEqual(state.panes.map(\.width), [1040, 760])
    }

    func test_single_pane_uses_stored_width() {
        let state = PaneStripState(
            panes: [makePane("shell", width: 894)],
            focusedPaneID: PaneID("shell")
        )

        let items = state.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].width, 894, accuracy: 0.001)
    }

    func test_multi_pane_uses_stored_widths_without_normalizing_roles() {
        let state = PaneStripState(
            panes: [
                makePane("shell", width: 1040),
                makePane("pane-1", width: 760),
                makePane("pane-2", width: 820),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        let items = state.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(items.map(\.width), [1040, 760, 820])
    }

    func test_focus_change_does_not_change_layout_widths() {
        let editorFocused = PaneStripState(
            panes: [
                makePane("shell", width: 1040),
                makePane("pane-1", width: 760),
                makePane("pane-2", width: 820),
            ],
            focusedPaneID: PaneID("pane-1")
        )
        let shellFocusedState = PaneStripState(
            panes: [
                makePane("shell", width: 1040),
                makePane("pane-1", width: 760),
                makePane("pane-2", width: 820),
            ],
            focusedPaneID: PaneID("shell")
        )

        let editorFocusedItems = editorFocused.layoutItems(in: CGSize(width: 1200, height: 780))
        let shellFocusedItems = shellFocusedState.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(editorFocusedItems.map(\.width), shellFocusedItems.map(\.width))
    }

    func test_inserting_pane_preserves_existing_widths() {
        var state = PaneStripState(
            panes: [
                makePane("shell", width: 1040),
                makePane("pane-1", width: 760),
            ],
            focusedPaneID: PaneID("pane-1")
        )
        let originalItems = state.layoutItems(in: CGSize(width: 1200, height: 780))

        state.insertPane(makePane("pane-2", width: 820), placement: .afterFocused)
        let updatedItems = state.layoutItems(in: CGSize(width: 1200, height: 780))

        XCTAssertEqual(updatedItems[0].width, originalItems[0].width, accuracy: 0.001)
        XCTAssertEqual(updatedItems[1].width, originalItems[1].width, accuracy: 0.001)
        XCTAssertEqual(updatedItems[2].width, 820, accuracy: 0.001)
    }

    func test_closing_from_two_to_one_can_expand_remaining_pane_width() {
        var state = PaneStripState(
            panes: [
                makePane("shell", width: 760),
                makePane("pane-1", width: 820),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        _ = state.closeFocusedPane(singlePaneWidth: 1180)

        XCTAssertEqual(state.panes.map(\.title), ["shell"])
        XCTAssertEqual(state.panes.map(\.width), [1180])
    }

    func test_closing_from_three_to_two_preserves_surviving_widths() {
        var state = PaneStripState(
            panes: [
                makePane("shell", width: 1040),
                makePane("pane-1", width: 760),
                makePane("pane-2", width: 820),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        _ = state.closeFocusedPane(singlePaneWidth: 1180)

        XCTAssertEqual(state.panes.map(\.title), ["shell", "pane-2"])
        XCTAssertEqual(state.panes.map(\.width), [1040, 820])
    }

    func test_layout_height_expands_with_container_height() {
        let state = PaneStripState(
            panes: [
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 820),
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
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 820),
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
                makePane("logs", width: 1040),
                makePane("editor", width: 760),
                makePane("tests", width: 820),
            ]
        )

        state.focusPane(id: PaneID("missing"))

        XCTAssertEqual(state.focusedPane?.title, "logs")
    }

    private func makePane(_ title: String, width: CGFloat) -> PaneState {
        PaneState(id: PaneID(title), title: title, width: width)
    }
}
