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

    func test_movePane_within_same_column_preserves_heights_and_reorders_in_place() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [1, 2, 3],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didMove = state.movePane(
            id: PaneID("top"),
            toColumnID: PaneColumnID("stack"),
            atPaneIndex: 3
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("middle"), PaneID("bottom"), PaneID("top")])
        XCTAssertEqual(state.columns[0].paneHeights, [2, 3, 1])
        XCTAssertEqual(state.focusedPane?.id, PaneID("top"))
    }

    func test_movePane_within_same_column_uses_reduced_space_target_index_for_downward_moves() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [1, 2, 3],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didMove = state.movePane(
            id: PaneID("top"),
            toColumnID: PaneColumnID("stack"),
            atPaneIndex: 1
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("middle"), PaneID("top"), PaneID("bottom")])
        XCTAssertEqual(state.columns[0].paneHeights, [2, 1, 3])
        XCTAssertEqual(state.focusedPane?.id, PaneID("top"))
    }

    func test_movePane_within_same_column_same_slot_is_treated_as_handled_drop() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [1, 2, 3],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didMove = state.movePane(
            id: PaneID("middle"),
            toColumnID: PaneColumnID("stack"),
            atPaneIndex: 1
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("top"), PaneID("middle"), PaneID("bottom")])
        XCTAssertEqual(state.columns[0].paneHeights, [1, 2, 3])
        XCTAssertEqual(state.focusedPane?.id, PaneID("middle"))
    }

    func test_movePane_into_existing_column_preserves_dragged_height_ratio() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "source",
                    paneIDs: ["alpha", "beta"],
                    width: 320,
                    paneHeights: [2, 3],
                    focusedPaneID: PaneID("alpha"),
                    lastFocusedPaneID: PaneID("alpha")
                ),
                makeColumn(
                    "target",
                    paneIDs: ["one", "two"],
                    width: 420,
                    paneHeights: [5, 7],
                    focusedPaneID: PaneID("one"),
                    lastFocusedPaneID: PaneID("one")
                ),
            ],
            focusedColumnID: PaneColumnID("source")
        )

        let didMove = state.movePane(
            id: PaneID("alpha"),
            toColumnID: PaneColumnID("target"),
            atPaneIndex: 1
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(state.columns[0].panes.map(\.id), [PaneID("beta")])
        XCTAssertEqual(state.columns[0].paneHeights, [5])
        XCTAssertEqual(state.columns[1].panes.map(\.id), [PaneID("one"), PaneID("alpha"), PaneID("two")])
        XCTAssertEqual(state.columns[1].paneHeights, [5, 2, 7])
        XCTAssertEqual(state.focusedColumn?.id, PaneColumnID("target"))
        XCTAssertEqual(state.focusedPane?.id, PaneID("alpha"))
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

    func test_resize_vertical_divider_adjusts_only_adjacent_panes() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [200, 300, 400]
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didResize = state.resizeDivider(
            .pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("top")),
            delta: 50,
            availableSize: CGSize(width: 1200, height: 920),
            minimumSizeByPaneID: [
                PaneID("top"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("bottom"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.lastInteractedDivider, .pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("top")))
        let heights = state.columns[0].resolvedPaneHeights(totalHeight: 920, spacing: state.layoutSizing.interPaneSpacing)
        XCTAssertEqual(heights[0], 251.77777777777777, accuracy: 0.001)
        XCTAssertEqual(heights[1], 252.66666666666669, accuracy: 0.001)
        XCTAssertEqual(heights[2], 403.55555555555554, accuracy: 0.001)
    }

    func test_resize_horizontal_divider_respects_column_minimums() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 500),
                PaneState(id: PaneID("right"), title: "right", width: 500),
            ],
            focusedPaneID: PaneID("left")
        )

        let didResize = state.resizeDivider(
            .column(afterColumnID: PaneColumnID("column-left")),
            delta: -400,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 360, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 320, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 680, accuracy: 0.001)
    }

    func test_horizontal_resize_target_uses_focused_right_edge_for_adjacent_right_divider() {
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 500),
                PaneState(id: PaneID("right"), title: "right", width: 500),
            ],
            focusedPaneID: PaneID("left")
        )

        let target = state.horizontalResizeTarget(for: .column(afterColumnID: PaneColumnID("column-left")))

        XCTAssertEqual(
            target,
            PaneHorizontalResizeTarget(
                columnID: PaneColumnID("column-left"),
                edge: .right,
                divider: .column(afterColumnID: PaneColumnID("column-left"))
            )
        )
    }

    func test_horizontal_resize_target_retargets_non_adjacent_left_divider_to_focused_left_edge() {
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle-left", paneIDs: ["middle-left"], width: 360),
                makeColumn("focused", paneIDs: ["focused"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("focused")
        )

        let target = state.horizontalResizeTarget(for: .column(afterColumnID: PaneColumnID("left")))

        XCTAssertEqual(
            target,
            PaneHorizontalResizeTarget(
                columnID: PaneColumnID("focused"),
                edge: .left,
                divider: .column(afterColumnID: PaneColumnID("middle-left"))
            )
        )
    }

    func test_resize_horizontal_edge_only_resizes_target_column() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("middle"),
                    edge: .left,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -60,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(applied, 60, accuracy: 0.001)
        XCTAssertEqual(state.columns[0].width, 320, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 480, accuracy: 0.001)
        XCTAssertEqual(state.columns[2].width, 520, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("left")))
    }

    func test_resize_horizontal_edge_clamps_target_column_to_visible_width() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 500),
                makeColumn("right", paneIDs: ["right"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: 600,
            availableSize: CGSize(width: 800, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertGreaterThan(applied, 0)
        XCTAssertEqual(state.columns[0].width, 800, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 500, accuracy: 0.001)
    }

    func test_resize_horizontal_edge_clamps_target_column_to_visible_width_when_sidebar_is_visible() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 500),
                makeColumn("right", paneIDs: ["right"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: 600,
            availableSize: CGSize(width: 800, height: 700),
            leadingVisibleInset: 200,
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertGreaterThan(applied, 0)
        XCTAssertEqual(state.columns[0].width, 600, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 500, accuracy: 0.001)
    }

    func test_resize_horizontal_edge_stops_at_total_strip_width_floor() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 600),
                makeColumn("right", paneIDs: ["right"], width: 600),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -400,
            availableSize: CGSize(width: 1000, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertLessThan(applied, 0)
        XCTAssertEqual(state.columns[0].width, 394, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 600, accuracy: 0.001)
        XCTAssertEqual(
            state.columns.reduce(0) { $0 + $1.width } + state.layoutSizing.interPaneSpacing,
            1000,
            accuracy: 0.001
        )
    }

    func test_resize_horizontal_edge_is_refused_when_strip_is_already_at_width_floor() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 394),
                makeColumn("right", paneIDs: ["right"], width: 600),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -20,
            availableSize: CGSize(width: 1000, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(applied, 0, accuracy: 0.001)
        XCTAssertEqual(state.columns[0].width, 394, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 600, accuracy: 0.001)
    }

    func test_resize_horizontal_edge_uses_visible_width_floor_when_sidebar_is_visible() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 400),
                makeColumn("right", paneIDs: ["right"], width: 400),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -100,
            availableSize: CGSize(width: 1000, height: 700),
            leadingVisibleInset: 200,
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertLessThan(applied, 0)
        XCTAssertEqual(state.columns[0].width, 394, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 400, accuracy: 0.001)
        XCTAssertEqual(
            state.columns.reduce(0) { $0 + $1.width } + state.layoutSizing.interPaneSpacing,
            800,
            accuracy: 0.001
        )
    }

    func test_equalize_vertical_divider_only_equalizes_the_adjacent_pair() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [200, 300, 400]
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didEqualize = state.equalizeDivider(
            .pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("top")),
            availableSize: CGSize(width: 1200, height: 920)
        )

        XCTAssertTrue(didEqualize)
        let heights = state.columns[0].resolvedPaneHeights(totalHeight: 920, spacing: state.layoutSizing.interPaneSpacing)
        XCTAssertEqual(heights[0], 252.22222222222223, accuracy: 0.001)
        XCTAssertEqual(heights[1], 252.22222222222223, accuracy: 0.001)
        XCTAssertEqual(heights[2], 403.55555555555554, accuracy: 0.001)
    }

    func test_preferred_divider_uses_last_interacted_divider_for_matching_axis() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["logs"]),
                makeColumn("right", paneIDs: ["editor", "tests"], focusedPaneID: PaneID("editor"))
            ],
            focusedColumnID: PaneColumnID("right")
        )

        state.markDividerInteraction(.pane(columnID: PaneColumnID("right"), afterPaneID: PaneID("editor")))

        XCTAssertEqual(
            state.preferredDivider(for: .vertical),
            .pane(columnID: PaneColumnID("right"), afterPaneID: PaneID("editor"))
        )
    }

    func test_preferred_divider_ignores_last_interacted_divider_when_focus_moved_away() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["logs", "build"], focusedPaneID: PaneID("logs")),
                makeColumn("right", paneIDs: ["editor", "tests"], focusedPaneID: PaneID("editor"))
            ],
            focusedColumnID: PaneColumnID("left")
        )

        state.markDividerInteraction(.pane(columnID: PaneColumnID("right"), afterPaneID: PaneID("editor")))

        XCTAssertEqual(
            state.preferredDivider(for: .vertical),
            .pane(columnID: PaneColumnID("left"), afterPaneID: PaneID("logs"))
        )
    }

    func test_resize_focused_pane_right_shrinks_last_column_without_resizing_neighbors() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 600),
                PaneState(id: PaneID("right"), title: "right", width: 600),
            ],
            focusedPaneID: PaneID("right")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: 40,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 600, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 594, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("column-left")))
    }

    func test_resize_focused_pane_left_shrinks_middle_column_without_resizing_neighbors() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 400),
                makeColumn("middle", paneIDs: ["middle"], width: 400),
                makeColumn("right", paneIDs: ["right"], width: 500),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: -50,
            availableSize: CGSize(width: 1000, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 400, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 350, accuracy: 0.001)
        XCTAssertEqual(state.columns[2].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("left")))
    }

    func test_resize_focused_pane_right_grows_middle_column_without_resizing_neighbors() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 400),
                makeColumn("middle", paneIDs: ["middle"], width: 400),
                makeColumn("right", paneIDs: ["right"], width: 500),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: 50,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 400, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 450, accuracy: 0.001)
        XCTAssertEqual(state.columns[2].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("middle")))
    }

    func test_resize_focused_pane_left_shrinks_first_column_without_resizing_neighbors() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 600),
                PaneState(id: PaneID("right"), title: "right", width: 600),
            ],
            focusedPaneID: PaneID("left")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: -40,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 594, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 600, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("column-left")))
    }

    func test_resize_focused_pane_right_grows_first_column_using_the_only_adjacent_split() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 500),
                PaneState(id: PaneID("right"), title: "right", width: 500),
            ],
            focusedPaneID: PaneID("left")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: 40,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 540, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("column-left")))
    }

    func test_resize_focused_pane_left_grows_last_column_using_the_only_adjacent_split() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 500),
                PaneState(id: PaneID("right"), title: "right", width: 500),
            ],
            focusedPaneID: PaneID("right")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: -40,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        XCTAssertEqual(state.columns[0].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 540, accuracy: 0.001)
        XCTAssertEqual(state.lastInteractedDivider, .column(afterColumnID: PaneColumnID("column-left")))
    }

    func test_resize_focused_pane_is_refused_when_only_one_column_exists() {
        var state = PaneStripState(
            panes: [
                PaneState(id: PaneID("solo"), title: "solo", width: 500),
            ],
            focusedPaneID: PaneID("solo")
        )

        let didResize = state.resizeFocusedPane(
            in: .horizontal,
            delta: 40,
            availableSize: CGSize(width: 1200, height: 700),
            minimumSizeByPaneID: [
                PaneID("solo"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertFalse(didResize)
        XCTAssertEqual(state.columns[0].width, 500, accuracy: 0.001)
    }

    func test_resize_focused_pane_down_shrinks_bottom_pane_when_bottom_is_focused() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [300, 300],
                    focusedPaneID: PaneID("bottom"),
                    lastFocusedPaneID: PaneID("bottom")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let didResize = state.resizeFocusedPane(
            in: .vertical,
            delta: -40,
            availableSize: CGSize(width: 1200, height: 706),
            minimumSizeByPaneID: [
                PaneID("top"): PaneMinimumSize(width: 320, height: 160),
                PaneID("bottom"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertTrue(didResize)
        let heights = state.columns[0].resolvedPaneHeights(totalHeight: 706, spacing: state.layoutSizing.interPaneSpacing)
        XCTAssertEqual(heights[0], 390, accuracy: 0.001)
        XCTAssertEqual(heights[1], 310, accuracy: 0.001)
    }

    func test_shouldInvertVerticalKeyboardResizeDelta_returns_true_when_focused_pane_is_above_divider() {
        let state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [300, 300],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        XCTAssertTrue(state.shouldInvertVerticalKeyboardResizeDelta())
    }

    func test_shouldInvertVerticalKeyboardResizeDelta_returns_false_when_focused_pane_is_below_divider() {
        let state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [300, 300],
                    focusedPaneID: PaneID("bottom"),
                    lastFocusedPaneID: PaneID("bottom")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        XCTAssertFalse(state.shouldInvertVerticalKeyboardResizeDelta())
    }

    func test_shouldInvertVerticalKeyboardResizeDelta_uses_last_interacted_lower_divider_for_middle_pane() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "stack",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [200, 300, 400],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        state.markDividerInteraction(.pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("middle")))

        XCTAssertTrue(state.shouldInvertVerticalKeyboardResizeDelta())
    }

    func test_arrange_horizontally_normalizes_column_widths_without_resetting_vertical_heights() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "left",
                    paneIDs: ["top", "bottom"],
                    width: 320,
                    paneHeights: [200, 400],
                    focusedPaneID: PaneID("bottom"),
                    lastFocusedPaneID: PaneID("bottom")
                ),
                makeColumn("right", paneIDs: ["shell"], width: 540),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeHorizontally(
            .halfWidth,
            availableWidth: 1200,
            leadingVisibleInset: 0
        )

        XCTAssertTrue(didArrange)
        XCTAssertEqual(state.columns[0].width, 597, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 597, accuracy: 0.001)
        XCTAssertEqual(state.columns[0].paneHeights, [200, 400])
        XCTAssertEqual(state.focusedPaneID, PaneID("bottom"))
    }

    func test_arrange_vertically_repacks_in_reading_order_and_preserves_focus_and_width_order() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a", "b"], width: 320),
                makeColumn(
                    "right",
                    paneIDs: ["c", "d"],
                    width: 520,
                    focusedPaneID: PaneID("d"),
                    lastFocusedPaneID: PaneID("d")
                ),
            ],
            focusedColumnID: PaneColumnID("right")
        )

        let didArrange = state.arrangeVertically(.threePerColumn)

        XCTAssertTrue(didArrange)
        XCTAssertEqual(
            state.columns.map { $0.panes.map(\.id) },
            [
                [PaneID("a"), PaneID("b"), PaneID("c")],
                [PaneID("d")],
            ]
        )
        XCTAssertEqual(state.columns[0].width, 320, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 520, accuracy: 0.001)
        XCTAssertEqual(state.columns[0].paneHeights, [1, 1, 1])
        XCTAssertEqual(state.columns[1].paneHeights, [1])
        XCTAssertEqual(state.focusedColumn?.id, PaneColumnID("right"))
        XCTAssertEqual(state.focusedPaneID, PaneID("d"))
    }

    func test_arrange_vertically_reuses_last_existing_width_when_more_columns_are_needed() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a", "b"], width: 300),
                makeColumn("right", paneIDs: ["c", "d"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeVertically(.fullHeight)

        XCTAssertTrue(didArrange)
        XCTAssertEqual(state.columns[0].width, 300, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.columns[2].width, 500, accuracy: 0.001)
        XCTAssertEqual(state.columns[3].width, 500, accuracy: 0.001)
        XCTAssertEqual(
            state.columns.map { $0.panes.map(\.id) },
            [
                [PaneID("a")],
                [PaneID("b")],
                [PaneID("c")],
                [PaneID("d")],
            ]
        )
    }

    func test_arrange_vertically_redistributes_partial_final_column_evenly() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a", "b", "c"], width: 320, paneHeights: [300, 150, 450]),
                makeColumn("right", paneIDs: ["d", "e"], width: 480, paneHeights: [500, 100]),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeVertically(.threePerColumn)

        XCTAssertTrue(didArrange)
        XCTAssertEqual(state.columns[1].panes.map(\.id), [PaneID("d"), PaneID("e")])
        XCTAssertEqual(state.columns[1].paneHeights, [1, 1])
    }

    // MARK: - Boundary Detection

    func test_isFocusedPaneAtTop_singlePane_returnsTrue() {
        let state = PaneStripState(
            columns: [
                makeColumn("col", paneIDs: ["only"], focusedPaneID: PaneID("only"))
            ],
            focusedColumnID: PaneColumnID("col")
        )

        XCTAssertTrue(state.isFocusedPaneAtTopOfColumn)
        XCTAssertTrue(state.isFocusedPaneAtBottomOfColumn)
    }

    func test_isFocusedPaneAtTop_atMiddle_returnsFalse() {
        let state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "middle", "bottom"],
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("col")
        )

        XCTAssertFalse(state.isFocusedPaneAtTopOfColumn)
        XCTAssertFalse(state.isFocusedPaneAtBottomOfColumn)
    }

    func test_isFocusedPaneAtTop_atFirst_returnsTrue() {
        let state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "middle", "bottom"],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                )
            ],
            focusedColumnID: PaneColumnID("col")
        )

        XCTAssertTrue(state.isFocusedPaneAtTopOfColumn)
        XCTAssertFalse(state.isFocusedPaneAtBottomOfColumn)
    }

    func test_isFocusedPaneAtBottom_atLast_returnsTrue() {
        let state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "middle", "bottom"],
                    focusedPaneID: PaneID("bottom"),
                    lastFocusedPaneID: PaneID("bottom")
                )
            ],
            focusedColumnID: PaneColumnID("col")
        )

        XCTAssertFalse(state.isFocusedPaneAtTopOfColumn)
        XCTAssertTrue(state.isFocusedPaneAtBottomOfColumn)
    }

    // MARK: - Golden Ratio Width

    func test_arrangeGoldenWidth_focusWide_applies_golden_ratio_to_focused_and_neighbor() {
        let availableWidth: CGFloat = 1006
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 500),
                makeColumn("right", paneIDs: ["b"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeGoldenWidth(
            focusWide: true,
            availableWidth: availableWidth
        )

        XCTAssertTrue(didArrange)
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let expectedWide = 1000 * phi / (1 + phi)
        XCTAssertEqual(state.columns[0].width, expectedWide, accuracy: 0.01)
        XCTAssertEqual(state.columns[1].width, 1000 - expectedWide, accuracy: 0.01)
    }

    func test_arrangeGoldenWidth_focusNarrow_makes_focused_column_narrower() {
        let availableWidth: CGFloat = 1006
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 500),
                makeColumn("right", paneIDs: ["b"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeGoldenWidth(
            focusWide: false,
            availableWidth: availableWidth
        )

        XCTAssertTrue(didArrange)
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let expectedNarrow = 1000 * 1 / (1 + phi)
        XCTAssertEqual(state.columns[0].width, expectedNarrow, accuracy: 0.01)
        XCTAssertEqual(state.columns[1].width, 1000 - expectedNarrow, accuracy: 0.01)
    }

    func test_arrangeGoldenWidth_focused_last_column_pairs_with_previous() {
        let availableWidth: CGFloat = 606
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 400),
                makeColumn("middle", paneIDs: ["b"], width: 300),
                makeColumn("right", paneIDs: ["c"], width: 300),
            ],
            focusedColumnID: PaneColumnID("right")
        )

        let didArrange = state.arrangeGoldenWidth(
            focusWide: true,
            availableWidth: availableWidth
        )

        XCTAssertTrue(didArrange)
        XCTAssertEqual(state.columns[0].width, 400, accuracy: 0.01, "Uninvolved column should not change")
        let combined: CGFloat = 600
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let expectedWide = combined * phi / (1 + phi)
        XCTAssertEqual(state.columns[2].width, expectedWide, accuracy: 0.01)
        XCTAssertEqual(state.columns[1].width, combined - expectedWide, accuracy: 0.01)
    }

    func test_arrangeGoldenWidth_single_column_returns_false() {
        var state = PaneStripState(
            columns: [makeColumn("only", paneIDs: ["a"], width: 800)],
            focusedColumnID: PaneColumnID("only")
        )

        XCTAssertFalse(state.arrangeGoldenWidth(focusWide: true, availableWidth: 800))
    }

    func test_arrangeGoldenWidth_idempotent_second_call_returns_false() {
        let availableWidth: CGFloat = 1006
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 500),
                makeColumn("right", paneIDs: ["b"], width: 500),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        XCTAssertTrue(state.arrangeGoldenWidth(focusWide: true, availableWidth: availableWidth))
        XCTAssertFalse(state.arrangeGoldenWidth(focusWide: true, availableWidth: availableWidth))
    }

    func test_arrangeGoldenWidth_focusWide_uses_readable_width_when_sidebar_is_open_on_laptop() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 910),
                makeColumn("right", paneIDs: ["b"], width: 910),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let didArrange = state.arrangeGoldenWidth(
            focusWide: true,
            availableWidth: 1200,
            leadingVisibleInset: 290
        )

        XCTAssertTrue(didArrange)
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let pairUsableWidth: CGFloat = 1200 - 290 - 6
        let expectedWide = pairUsableWidth * phi / (1 + phi)
        XCTAssertEqual(state.columns[0].width, expectedWide, accuracy: 0.01)
        XCTAssertEqual(state.columns[1].width, pairUsableWidth - expectedWide, accuracy: 0.01)
        XCTAssertLessThanOrEqual(state.columns[0].width, pairUsableWidth, "Focused column should fit within the readable lane")
    }

    func test_arrangeGoldenWidth_focusWide_changes_when_sidebar_visibility_changes() {
        var hiddenSidebarState = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["a"], width: 910),
                makeColumn("right", paneIDs: ["b"], width: 910),
            ],
            focusedColumnID: PaneColumnID("left")
        )
        var openSidebarState = hiddenSidebarState

        XCTAssertTrue(
            hiddenSidebarState.arrangeGoldenWidth(
                focusWide: true,
                availableWidth: 1200,
                leadingVisibleInset: 0
            )
        )
        XCTAssertTrue(
            openSidebarState.arrangeGoldenWidth(
                focusWide: true,
                availableWidth: 1200,
                leadingVisibleInset: 290
            )
        )

        XCTAssertGreaterThan(hiddenSidebarState.columns[0].width, openSidebarState.columns[0].width)
        XCTAssertGreaterThan(hiddenSidebarState.columns[1].width, openSidebarState.columns[1].width)
    }

    // MARK: - Golden Ratio Height

    func test_arrangeGoldenHeight_focusTall_applies_golden_ratio_to_focused_and_neighbor() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [1, 1],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                ),
            ],
            focusedColumnID: PaneColumnID("col")
        )
        let availableSize = CGSize(width: 800, height: 600)

        let didArrange = state.arrangeGoldenHeight(focusTall: true, availableSize: availableSize)

        XCTAssertTrue(didArrange)
        let totalHeight = PaneLayoutSizing.balanced.paneHeight(for: 600)
        let spacing = PaneLayoutSizing.balanced.interPaneSpacing
        let resolvedHeights = state.columns[0].resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: spacing
        )
        let combinedHeight = resolvedHeights[0] + resolvedHeights[1]
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let expectedTall = combinedHeight * phi / (1 + phi)
        XCTAssertEqual(resolvedHeights[0], expectedTall, accuracy: 1.0)
    }

    func test_arrangeGoldenHeight_focusShort_makes_focused_pane_shorter() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [1, 1],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                ),
            ],
            focusedColumnID: PaneColumnID("col")
        )
        let availableSize = CGSize(width: 800, height: 600)

        let didArrange = state.arrangeGoldenHeight(focusTall: false, availableSize: availableSize)

        XCTAssertTrue(didArrange)
        let totalHeight = PaneLayoutSizing.balanced.paneHeight(for: 600)
        let spacing = PaneLayoutSizing.balanced.interPaneSpacing
        let resolvedHeights = state.columns[0].resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: spacing
        )
        let combinedHeight = resolvedHeights[0] + resolvedHeights[1]
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let expectedShort = combinedHeight * 1 / (1 + phi)
        XCTAssertEqual(resolvedHeights[0], expectedShort, accuracy: 1.0)
    }

    func test_arrangeGoldenHeight_focused_last_pane_pairs_with_previous() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "middle", "bottom"],
                    paneHeights: [1, 1, 1],
                    focusedPaneID: PaneID("bottom"),
                    lastFocusedPaneID: PaneID("bottom")
                ),
            ],
            focusedColumnID: PaneColumnID("col")
        )
        let availableSize = CGSize(width: 800, height: 900)

        let didArrange = state.arrangeGoldenHeight(focusTall: true, availableSize: availableSize)

        XCTAssertTrue(didArrange)
        let totalHeight = PaneLayoutSizing.balanced.paneHeight(for: 900)
        let spacing = PaneLayoutSizing.balanced.interPaneSpacing
        let resolvedHeights = state.columns[0].resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: spacing
        )
        // bottom (focused) should be larger than middle (neighbor)
        XCTAssertGreaterThan(resolvedHeights[2], resolvedHeights[1])
        // top (uninvolved) should stay at roughly 1/3 of the original
        let originalPerPaneHeight = (totalHeight - 2 * spacing) / 3
        XCTAssertEqual(resolvedHeights[0], originalPerPaneHeight, accuracy: 1.0)
    }

    func test_arrangeGoldenHeight_single_pane_returns_false() {
        var state = PaneStripState(
            columns: [makeColumn("col", paneIDs: ["only"])],
            focusedColumnID: PaneColumnID("col")
        )

        XCTAssertFalse(state.arrangeGoldenHeight(focusTall: true, availableSize: CGSize(width: 800, height: 600)))
    }

    func test_arrangeGoldenHeight_idempotent_second_call_returns_false() {
        var state = PaneStripState(
            columns: [
                makeColumn(
                    "col",
                    paneIDs: ["top", "bottom"],
                    paneHeights: [1, 1],
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                ),
            ],
            focusedColumnID: PaneColumnID("col")
        )
        let availableSize = CGSize(width: 800, height: 600)

        XCTAssertTrue(state.arrangeGoldenHeight(focusTall: true, availableSize: availableSize))
        XCTAssertFalse(state.arrangeGoldenHeight(focusTall: true, availableSize: availableSize))
    }

    func test_focused_horizontal_keyboard_resize_action_is_interior_for_middle_column() {
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        XCTAssertEqual(state.focusedHorizontalKeyboardResizeAction(for: -40), .interior)
        XCTAssertEqual(state.focusedHorizontalKeyboardResizeAction(for: 40), .interior)
    }

    func test_focused_horizontal_keyboard_resize_action_is_edge_for_last_column() {
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("right")
        )

        let resizeLeftAction = state.focusedHorizontalKeyboardResizeAction(for: -40)
        let resizeRightAction = state.focusedHorizontalKeyboardResizeAction(for: 40)

        if case .edge(let target) = resizeLeftAction {
            XCTAssertEqual(target.columnID, PaneColumnID("right"))
            XCTAssertEqual(target.edge, .left)
        } else {
            XCTFail("Expected .edge for resizeLeft on last column, got \(String(describing: resizeLeftAction))")
        }

        if case .edge(let target) = resizeRightAction {
            XCTAssertEqual(target.columnID, PaneColumnID("right"))
            XCTAssertEqual(target.edge, .left, "Last column has no right neighbor; preferredEdge=.right falls back to .left")
        } else {
            XCTFail("Expected .edge for resizeRight on last column, got \(String(describing: resizeRightAction))")
        }
    }

    func test_focused_horizontal_keyboard_resize_action_is_nil_for_single_column() {
        let state = PaneStripState(
            columns: [
                makeColumn("only", paneIDs: ["only"], width: 800),
            ],
            focusedColumnID: PaneColumnID("only")
        )

        XCTAssertNil(state.focusedHorizontalKeyboardResizeAction(for: -40))
    }

    func test_resize_left_edge_reports_zero_when_column_is_already_at_max_width() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 900),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let maxWidthBefore = state.columns[1].width

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("middle"),
                    edge: .left,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -100,
            availableSize: CGSize(width: 900, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(applied, 0, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, maxWidthBefore, accuracy: 0.001)
    }

    func test_resize_left_edge_reports_partial_applied_delta_when_hitting_max_width() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 740),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("middle"),
                    edge: .left,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -400,
            availableSize: CGSize(width: 900, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertGreaterThan(applied, 0)
        XCTAssertLessThan(applied, 400)
        XCTAssertEqual(state.columns[1].width, 740 + applied, accuracy: 0.001)
    }

    func test_resize_right_edge_returns_applied_width_delta_matching_input() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("middle"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("middle"))
                )
            ),
            delta: 60,
            availableSize: CGSize(width: 1400, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(applied, 60, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 480, accuracy: 0.001)
    }

    func test_resize_returns_applied_width_delta_for_left_edge_drag() {
        var state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let applied = state.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("middle"),
                    edge: .left,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -60,
            availableSize: CGSize(width: 1400, height: 700),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(applied, 60, accuracy: 0.001)
        XCTAssertEqual(state.columns[1].width, 480, accuracy: 0.001)
    }

    private func makeColumn(
        _ rawID: String,
        paneIDs: [String],
        width: CGFloat = 640,
        paneHeights: [CGFloat] = [],
        focusedPaneID: PaneID? = nil,
        lastFocusedPaneID: PaneID? = nil
    ) -> PaneColumnState {
        PaneColumnState(
            id: PaneColumnID(rawID),
            panes: paneIDs.map { PaneState(id: PaneID($0), title: $0) },
            width: width,
            paneHeights: paneHeights,
            focusedPaneID: focusedPaneID,
            lastFocusedPaneID: lastFocusedPaneID
        )
    }

}
