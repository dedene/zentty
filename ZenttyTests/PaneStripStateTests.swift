import XCTest
@testable import Zentty

final class PaneStripStateTests: XCTestCase {
    private let sidebarInset: CGFloat = 290

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
        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn, .standardColumn, .standardColumn])
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
        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn, .standardColumn, .standardColumn])
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
        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn, .standardColumn])
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
        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn])
    }

    func test_first_pane_defaults_to_leading_readable_role() {
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn, .standardColumn])
    }

    func test_single_pane_uses_readable_width_when_sidebar_inset_is_present() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
            ],
            focusedPaneID: PaneID("shell")
        )

        let items = state.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].widthRole, .leadingReadable)
        XCTAssertEqual(items[0].width, 894, accuracy: 0.001)
    }

    func test_multi_pane_uses_stable_role_based_widths() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
                makePane("pane-2"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        let items = state.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(items.map(\.widthRole), [.leadingReadable, .standardColumn, .standardColumn])
        XCTAssertEqual(items[0].width, 894, accuracy: 0.001)
        XCTAssertEqual(items[1].width, 587, accuracy: 0.001)
        XCTAssertEqual(items[2].width, 587, accuracy: 0.001)
    }

    func test_focus_change_does_not_change_layout_widths() {
        let editorFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
                makePane("pane-2"),
            ],
            focusedPaneID: PaneID("pane-1")
        )
        let shellFocusedState = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
                makePane("pane-2"),
            ],
            focusedPaneID: PaneID("shell")
        )

        let editorFocusedItems = editorFocused.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )
        let shellFocusedItems = shellFocusedState.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(editorFocusedItems.map(\.width), shellFocusedItems.map(\.width))
    }

    func test_inserting_pane_preserves_existing_widths() {
        var state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )
        let originalItems = state.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        state.insertPane(makePane("pane-2"), placement: .afterFocused)
        let updatedItems = state.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(updatedItems[0].width, originalItems[0].width, accuracy: 0.001)
        XCTAssertEqual(updatedItems[1].width, originalItems[1].width, accuracy: 0.001)
        XCTAssertEqual(updatedItems[2].width, 587, accuracy: 0.001)
    }

    func test_closing_leading_pane_promotes_new_first_pane_to_readable_role() {
        var state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
                makePane("pane-2"),
            ],
            focusedPaneID: PaneID("shell")
        )

        _ = state.closeFocusedPane()

        XCTAssertEqual(state.panes.map(\.title), ["pane-1", "pane-2"])
        XCTAssertEqual(state.panes.map(\.widthRole), [.leadingReadable, .standardColumn])
    }

    func test_standard_column_width_is_independent_of_pane_count() {
        let twoPaneState = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )
        let threePaneState = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
                makePane("pane-2"),
            ],
            focusedPaneID: PaneID("pane-2")
        )

        let twoPaneItems = twoPaneState.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )
        let threePaneItems = threePaneState.layoutItems(
            in: CGSize(width: 1200, height: 780),
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(twoPaneItems[1].width, threePaneItems[1].width, accuracy: 0.001)
        XCTAssertEqual(threePaneItems[1].width, threePaneItems[2].width, accuracy: 0.001)
    }

    func test_narrow_layout_clamps_role_based_widths_to_minimum() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("pane-1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        let items = state.layoutItems(
            in: CGSize(width: 560, height: 780),
            leadingVisibleInset: sidebarInset
        )
        XCTAssertEqual(items[0].width, PaneLayoutSizing.balanced.minimumPaneWidth)
        XCTAssertEqual(items[1].width, PaneLayoutSizing.balanced.minimumPaneWidth)
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
