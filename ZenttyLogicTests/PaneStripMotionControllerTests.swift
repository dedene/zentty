import XCTest
@testable import Zentty

final class PaneStripMotionControllerTests: XCTestCase {
    private let sidebarInset: CGFloat = 290

    @MainActor
    func test_focus_change_produces_new_target_offset() {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 980, height: 680)

        let leftFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("editor")),
            in: size
        )
        let rightFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("shell")),
            in: size
        )

        XCTAssertLessThan(leftFocused.targetOffset, rightFocused.targetOffset)
    }

    @MainActor
    func test_focused_pane_receives_stronger_emphasis_than_neighbors() throws {
        let controller = PaneStripMotionController()
        let presentation = controller.presentation(
            for: makeState(focusedPaneID: PaneID("editor")),
            in: CGSize(width: 980, height: 680)
        )

        let focused = try XCTUnwrap(presentation.panes.first(where: \.isFocused))
        let neighbor = try XCTUnwrap(presentation.panes.first(where: { !$0.isFocused }))

        XCTAssertGreaterThan(focused.emphasis, neighbor.emphasis)
    }

    @MainActor
    func test_focus_change_does_not_change_pane_widths() {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 980, height: 680)

        let editorFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("editor")),
            in: size
        )
        let testsFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("tests")),
            in: size
        )

        XCTAssertEqual(
            editorFocused.panes.map { $0.frame.width },
            testsFocused.panes.map { $0.frame.width }
        )
    }

    @MainActor
    func test_offset_clamps_at_strip_edges() {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 980, height: 680)

        let firstFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("logs")),
            in: size
        )
        let lastFocused = controller.presentation(
            for: makeState(focusedPaneID: PaneID("shell")),
            in: size
        )

        XCTAssertEqual(firstFocused.targetOffset, 0, accuracy: 0.001)
        XCTAssertEqual(
            lastFocused.targetOffset,
            max(0, lastFocused.contentWidth - size.width),
            accuracy: 0.001
        )
    }

    @MainActor
    func test_leading_visible_inset_pushes_first_focused_pane_clear_of_sidebar() {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 1200, height: 680)
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let baselinePresentation = controller.presentation(
            for: state,
            in: size
        )
        let insetPresentation = controller.presentation(
            for: state,
            in: size,
            leadingVisibleInset: sidebarInset
        )

        XCTAssertLessThan(insetPresentation.targetOffset, baselinePresentation.targetOffset)
        XCTAssertEqual(
            insetPresentation.targetOffset,
            state.layoutSizing.horizontalInset - sidebarInset,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_leading_visible_inset_pushes_first_focused_pane_clear_of_sidebar_with_three_columns() {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 1200, height: 680)
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("tests"), title: "tests"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let presentation = controller.presentation(
            for: state,
            in: size,
            leadingVisibleInset: sidebarInset
        )

        XCTAssertEqual(
            presentation.targetOffset,
            state.layoutSizing.horizontalInset - sidebarInset,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_leading_visible_inset_does_not_shift_layout_frames_right() throws {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680),
            leadingVisibleInset: sidebarInset
        )

        let firstPane = try XCTUnwrap(presentation.panes.first)

        XCTAssertEqual(firstPane.frame.minX, state.layoutSizing.horizontalInset, accuracy: 0.001)
    }

    @MainActor
    func test_leading_visible_inset_does_not_change_first_focused_pane_width() throws {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )

        let baselinePresentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680)
        )
        let insetPresentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680),
            leadingVisibleInset: sidebarInset
        )

        let baselineFirstPane = try XCTUnwrap(baselinePresentation.panes.first)
        let insetFirstPane = try XCTUnwrap(insetPresentation.panes.first)

        XCTAssertEqual(insetFirstPane.frame.width, baselineFirstPane.frame.width, accuracy: 0.001)
    }

    @MainActor
    func test_nearest_settle_ignores_leading_visible_inset() throws {
        let controller = PaneStripMotionController()
        let size = CGSize(width: 980, height: 680)
        let presentation = controller.presentation(
            for: PaneStripState(
                panes: [
                    PaneState(id: PaneID("logs"), title: "logs"),
                    PaneState(id: PaneID("editor"), title: "editor"),
                    PaneState(id: PaneID("tests"), title: "tests"),
                ],
                focusedPaneID: PaneID("editor")
            ),
            in: size
        )

        let proposedOffset = presentation.targetOffset + 140
        let baselinePaneID = controller.nearestSettlePaneID(
            in: presentation,
            proposedOffset: proposedOffset,
            viewportWidth: size.width
        )
        let insetPaneID = controller.nearestSettlePaneID(
            in: presentation,
            proposedOffset: proposedOffset,
            viewportWidth: size.width,
            leadingVisibleInset: 290
        )

        XCTAssertEqual(try XCTUnwrap(insetPaneID), try XCTUnwrap(baselinePaneID))
    }

    @MainActor
    func test_small_drag_settles_back_to_current_focus() throws {
        let controller = PaneStripMotionController()
        let state = makeState(focusedPaneID: PaneID("editor"))
        let size = CGSize(width: 980, height: 680)
        let presentation = controller.presentation(for: state, in: size)

        let settledPaneID = controller.nearestSettlePaneID(
            in: presentation,
            proposedOffset: presentation.targetOffset + 20,
            viewportWidth: size.width
        )

        XCTAssertEqual(try XCTUnwrap(settledPaneID), PaneID("editor"))
    }

    @MainActor
    func test_large_drag_settles_to_next_pane() throws {
        let controller = PaneStripMotionController()
        let state = makeState(focusedPaneID: PaneID("editor"))
        let size = CGSize(width: 980, height: 680)
        let presentation = controller.presentation(for: state, in: size)

        let currentFocusedPane = try XCTUnwrap(presentation.panes.first(where: { $0.paneID == PaneID("editor") }))
        let nextPane = try XCTUnwrap(presentation.panes.first(where: { $0.paneID == PaneID("tests") }))
        let midpointOffset = (currentFocusedPane.frame.midX + nextPane.frame.midX) / 2 - (size.width / 2)

        let settledPaneID = controller.nearestSettlePaneID(
            in: presentation,
            proposedOffset: midpointOffset + 40,
            viewportWidth: size.width
        )

        XCTAssertEqual(try XCTUnwrap(settledPaneID), PaneID("tests"))
    }

    @MainActor
    func test_presentation_snaps_frames_to_retina_pixel_grid() {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("logs"), title: "logs", width: 333.3),
                PaneState(id: PaneID("editor"), title: "editor", width: 287.7),
                PaneState(id: PaneID("tests"), title: "tests", width: 301.1),
            ],
            focusedPaneID: PaneID("editor")
        )

        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1111, height: 679.3),
            leadingVisibleInset: 290.25,
            backingScaleFactor: 2
        )

        for pane in presentation.panes {
            assertRetinaAligned(pane.frame.minX)
            assertRetinaAligned(pane.frame.maxX)
            assertRetinaAligned(pane.frame.minY)
            assertRetinaAligned(pane.frame.maxY)
        }
    }

    @MainActor
    func test_presentation_snaps_target_offset_to_retina_pixel_grid() {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 444.4),
                PaneState(id: PaneID("editor"), title: "editor", width: 355.55),
            ],
            focusedPaneID: PaneID("shell")
        )

        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680),
            leadingVisibleInset: 290.25,
            backingScaleFactor: 2
        )

        assertRetinaAligned(presentation.targetOffset)
    }

    @MainActor
    func test_stacked_column_renders_first_pane_above_later_panes() throws {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("top"), title: "top"),
                        PaneState(id: PaneID("middle"), title: "middle"),
                        PaneState(id: PaneID("bottom"), title: "bottom"),
                    ],
                    width: 640,
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680)
        )

        let topPane = try XCTUnwrap(presentation.panes.first(where: { $0.paneID == PaneID("top") }))
        let middlePane = try XCTUnwrap(presentation.panes.first(where: { $0.paneID == PaneID("middle") }))
        let bottomPane = try XCTUnwrap(presentation.panes.first(where: { $0.paneID == PaneID("bottom") }))

        XCTAssertGreaterThan(topPane.frame.minY, middlePane.frame.minY)
        XCTAssertGreaterThan(middlePane.frame.minY, bottomPane.frame.minY)
    }

    @MainActor
    func test_presentation_includes_horizontal_and_vertical_dividers() {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [
                        PaneState(id: PaneID("top"), title: "top"),
                        PaneState(id: PaneID("bottom"), title: "bottom"),
                    ],
                    width: 420,
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("editor"), title: "editor")],
                    width: 420,
                    focusedPaneID: PaneID("editor"),
                    lastFocusedPaneID: PaneID("editor")
                ),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1200, height: 680)
        )

        XCTAssertTrue(presentation.dividers.contains(where: { $0.divider == .column(afterColumnID: PaneColumnID("left")) }))
        XCTAssertTrue(presentation.dividers.contains(where: {
            $0.divider == .pane(columnID: PaneColumnID("left"), afterPaneID: PaneID("top"))
        }))
    }

    @MainActor
    func test_focused_pane_with_clamped_width_remains_fully_visible() throws {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [PaneState(id: PaneID("left"), title: "left")],
                    width: 320,
                    focusedPaneID: PaneID("left"),
                    lastFocusedPaneID: PaneID("left")
                ),
                PaneColumnState(
                    id: PaneColumnID("middle"),
                    panes: [PaneState(id: PaneID("middle"), title: "middle")],
                    width: 900,
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("right"), title: "right")],
                    width: 320,
                    focusedPaneID: PaneID("right"),
                    lastFocusedPaneID: PaneID("right")
                ),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        let viewportWidth: CGFloat = 900
        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: viewportWidth, height: 680)
        )
        let focusedPane = try XCTUnwrap(presentation.focusedPane)
        let visibleFrame = focusedPane.frame.offsetBy(dx: -presentation.targetOffset, dy: 0)

        XCTAssertGreaterThanOrEqual(visibleFrame.minX, 0)
        XCTAssertLessThanOrEqual(visibleFrame.maxX, viewportWidth)
    }

    @MainActor
    func test_content_width_matches_viewport_when_columns_fill_width_floor_exactly() {
        let controller = PaneStripMotionController()
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [PaneState(id: PaneID("left"), title: "left")],
                    width: 394,
                    focusedPaneID: PaneID("left"),
                    lastFocusedPaneID: PaneID("left")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("right"), title: "right")],
                    width: 600,
                    focusedPaneID: PaneID("right"),
                    lastFocusedPaneID: PaneID("right")
                ),
            ],
            focusedColumnID: PaneColumnID("left")
        )

        let presentation = controller.presentation(
            for: state,
            in: CGSize(width: 1000, height: 680)
        )

        XCTAssertEqual(presentation.contentWidth, 1000, accuracy: 0.001)
    }

    @MainActor
    func test_shrinking_focused_pane_reveals_more_of_neighbor_without_creating_blank_space() {
        let controller = PaneStripMotionController()
        let viewportSize = CGSize(width: 1000, height: 680)
        let minimums: [PaneID: PaneMinimumSize] = [
            PaneID("left"): PaneMinimumSize(width: 320, height: 160),
            PaneID("right"): PaneMinimumSize(width: 320, height: 160),
        ]
        let initialState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [PaneState(id: PaneID("left"), title: "left")],
                    width: 900,
                    focusedPaneID: PaneID("left"),
                    lastFocusedPaneID: PaneID("left")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("right"), title: "right")],
                    width: 500,
                    focusedPaneID: PaneID("right"),
                    lastFocusedPaneID: PaneID("right")
                ),
            ],
            focusedColumnID: PaneColumnID("left")
        )
        var resizedState = initialState
        _ = resizedState.resize(
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("left"),
                    edge: .right,
                    divider: .column(afterColumnID: PaneColumnID("left"))
                )
            ),
            delta: -300,
            availableSize: viewportSize,
            minimumSizeByPaneID: minimums
        )

        let initialPresentation = controller.presentation(for: initialState, in: viewportSize)
        let resizedPresentation = controller.presentation(for: resizedState, in: viewportSize)
        let initialRightPane = initialPresentation.columns[1].panes[0].frame.offsetBy(
            dx: -initialPresentation.targetOffset,
            dy: 0
        )
        let resizedRightPane = resizedPresentation.columns[1].panes[0].frame.offsetBy(
            dx: -resizedPresentation.targetOffset,
            dy: 0
        )

        XCTAssertLessThan(resizedRightPane.minX, initialRightPane.minX)
        XCTAssertGreaterThanOrEqual(resizedPresentation.contentWidth, viewportSize.width)
    }

    private func assertRetinaAligned(_ value: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value * 2, (value * 2).rounded(), accuracy: 0.0001, file: file, line: line)
    }

    private func makeState(focusedPaneID: PaneID) -> PaneStripState {
        PaneStripState(
            panes: [
                PaneState(id: PaneID("logs"), title: "logs"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("tests"), title: "tests"),
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: focusedPaneID
        )
    }
}
