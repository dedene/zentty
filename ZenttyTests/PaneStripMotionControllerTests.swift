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
        XCTAssertEqual(insetPresentation.targetOffset, -282, accuracy: 0.001)
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
        XCTAssertEqual(firstPane.frame.minX, 8, accuracy: 0.001)
    }

    @MainActor
    func test_leading_visible_inset_reduces_first_focused_pane_width_by_sidebar_gutter() throws {
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

        XCTAssertEqual(insetFirstPane.frame.width, baselineFirstPane.frame.width - sidebarInset, accuracy: 0.001)
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
