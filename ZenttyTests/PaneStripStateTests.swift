import XCTest
@testable import Zentty

final class PaneStripStateTests: XCTestCase {
    func test_initial_focus_defaults_to_first_column_and_pane() {
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["logs"]),
                makeColumn("right", paneIDs: ["editor"]),
            ]
        )

        XCTAssertEqual(state.focusedColumn?.id, PaneColumnID("left"))
        XCTAssertEqual(state.focusedPane?.id, PaneID("logs"))
    }

    func test_move_focus_right_restores_last_focused_pane_for_target_column() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["logs"]),
                makeColumn(
                    "right",
                    paneIDs: ["build", "tests", "shell"],
                    focusedPaneID: PaneID("tests"),
                    lastFocusedPaneID: PaneID("tests")
                ),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        state.moveFocusRight()

        XCTAssertEqual(state.focusedColumn?.id, PaneColumnID("right"))
        XCTAssertEqual(state.focusedPane?.id, PaneID("tests"))
    }

    func test_move_focus_up_and_down_stays_within_focused_column() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                ),
                makeColumn("right", paneIDs: ["shell"])
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        state.moveFocusDown()
        XCTAssertEqual(state.focusedPane?.id, PaneID("bottom"))

        state.moveFocusDown()
        XCTAssertEqual(state.focusedPane?.id, PaneID("bottom"))

        state.moveFocusUp()
        XCTAssertEqual(state.focusedPane?.id, PaneID("middle"))

        XCTAssertEqual(state.focusedColumn?.id, PaneColumnID("stack"))
    }

    func test_closing_focused_pane_prefers_lower_neighbor_inside_column() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let closedPane = state.closeFocusedPane(singleColumnWidth: 900)

        XCTAssertEqual(closedPane?.id, PaneID("middle"))
        XCTAssertEqual(state.focusedPane?.id, PaneID("bottom"))
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("top"), PaneID("bottom")])
    }

    func test_vertical_split_is_refused_when_equalized_height_would_violate_minimum() {
        var state = PaneStripState(
            columns: [
                makeColumn("stack", paneIDs: ["top", "bottom"])
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didInsert = state.insertPaneVertically(
            PaneState(id: PaneID("third"), title: "third"),
            in: PaneColumnID("stack"),
            availableHeight: 420,
            minimumPaneHeight: 160
        )

        XCTAssertFalse(didInsert)
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("top"), PaneID("bottom")])
    }

    private func makeColumn(
        _ rawID: String,
        paneIDs: [String],
        width: CGFloat = 640,
        focusedPaneID: PaneID? = nil,
        lastFocusedPaneID: PaneID? = nil
    ) -> PaneColumnState {
        PaneColumnState(
            id: PaneColumnID(rawID),
            panes: paneIDs.map { PaneState(id: PaneID($0), title: $0) },
            width: width,
            focusedPaneID: focusedPaneID,
            lastFocusedPaneID: lastFocusedPaneID
        )
    }
}
