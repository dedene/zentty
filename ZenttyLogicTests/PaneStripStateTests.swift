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

        let didResize = state.resize(
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

        XCTAssertTrue(didResize)
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

        let didResize = state.resize(
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

        XCTAssertTrue(didResize)
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

        let didResize = state.resize(
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

        XCTAssertTrue(didResize)
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

        let didResize = state.resize(
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

        XCTAssertTrue(didResize)
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

        let didResize = state.resize(
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

        XCTAssertFalse(didResize)
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

        let didResize = state.resize(
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

        XCTAssertTrue(didResize)
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
