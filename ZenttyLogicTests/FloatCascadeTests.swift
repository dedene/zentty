import CoreGraphics
import XCTest
@testable import Zentty

/// New floats cascade 28pt down-right off floats already sitting at their
/// origin, wrapping to the top-left corner at the canvas edge.
@MainActor
final class FloatCascadeTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_cascade")
    private let start = CGRect(x: 240, y: 160, width: 720, height: 480)

    // MARK: - FloatLayout.cascadedFrame

    func test_free_origin_is_kept() {
        let frame = FloatLayout.cascadedFrame(start, avoiding: [], canvas: canvas)
        XCTAssertEqual(frame, start)
    }

    func test_occupied_origin_steps_down_right() {
        let frame = FloatLayout.cascadedFrame(start, avoiding: [start], canvas: canvas)
        XCTAssertEqual(frame, start.offsetBy(dx: 28, dy: -28), "y-up: down is a smaller y")
    }

    func test_steps_past_every_occupied_origin_in_turn() {
        let occupied = [start, start.offsetBy(dx: 28, dy: -28)]
        let frame = FloatLayout.cascadedFrame(start, avoiding: occupied, canvas: canvas)
        XCTAssertEqual(frame, start.offsetBy(dx: 56, dy: -56))
    }

    func test_only_the_origin_counts_not_the_size() {
        let other = CGRect(origin: start.origin, size: CGSize(width: 300, height: 200))
        XCTAssertEqual(FloatLayout.cascadedFrame(start, avoiding: [other], canvas: canvas).origin.x, start.minX + 28)
        let overlapping = start.offsetBy(dx: 10, dy: 0)
        XCTAssertEqual(FloatLayout.cascadedFrame(start, avoiding: [overlapping], canvas: canvas), start)
    }

    func test_sub_point_differences_count_as_the_same_origin() {
        let nearly = start.offsetBy(dx: 0.3, dy: -0.2)
        XCTAssertEqual(FloatLayout.cascadedFrame(start, avoiding: [nearly], canvas: canvas).minX, start.minX + 28)
    }

    func test_wraps_to_the_top_left_when_the_next_step_leaves_the_canvas() {
        // 470 + 28 + 720 = 1218 > 1200: the step would leave on the right.
        let nearEdge = CGRect(x: 470, y: 160, width: 720, height: 480)
        let frame = FloatLayout.cascadedFrame(nearEdge, avoiding: [nearEdge], canvas: canvas)
        XCTAssertEqual(frame, CGRect(x: 0, y: 320, width: 720, height: 480))
    }

    func test_wraps_at_the_bottom_edge_too() {
        let nearBottom = CGRect(x: 100, y: 10, width: 400, height: 300)
        let frame = FloatLayout.cascadedFrame(nearBottom, avoiding: [nearBottom], canvas: canvas)
        XCTAssertEqual(frame, CGRect(x: 0, y: 500, width: 400, height: 300))
    }

    func test_cascade_continues_from_the_wrapped_corner() {
        let nearEdge = CGRect(x: 470, y: 160, width: 720, height: 480)
        let corner = CGRect(x: 0, y: 320, width: 720, height: 480)
        let frame = FloatLayout.cascadedFrame(nearEdge, avoiding: [nearEdge, corner], canvas: canvas)
        XCTAssertEqual(frame, corner.offsetBy(dx: 28, dy: -28))
    }

    func test_gives_up_when_every_slot_is_taken() {
        // As big as the canvas: every step wraps back to the same corner.
        let full = canvas
        let frame = FloatLayout.cascadedFrame(full, avoiding: [full], canvas: canvas)
        XCTAssertEqual(frame.size, full.size, "terminates with a frame of the same size")
    }

    func test_empty_canvas_keeps_the_frame() {
        XCTAssertEqual(FloatLayout.cascadedFrame(start, avoiding: [start], canvas: .zero), start)
    }

    // MARK: - Store

    func test_new_floats_from_focus_cascade_instead_of_stacking() throws {
        let store = makeStore()

        let first = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))
        let second = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))
        let third = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))

        let origins = [first, second, third].compactMap { frame(store, $0)?.origin }
        XCTAssertEqual(origins.count, 3)
        XCTAssertEqual(origins[0].x, 240, accuracy: 0.001)
        XCTAssertEqual(origins[0].y, 160, accuracy: 0.001)
        XCTAssertEqual(origins[1].x, 268, accuracy: 0.001)
        XCTAssertEqual(origins[1].y, 132, accuracy: 0.001)
        XCTAssertEqual(origins[2].x, 296, accuracy: 0.001)
        XCTAssertEqual(origins[2].y, 104, accuracy: 0.001)
    }

    func test_new_float_request_cascades_too() throws {
        let store = makeStore()
        let request = TerminalSessionRequest(workingDirectory: "/tmp")

        let first = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))
        let second = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))

        XCTAssertEqual(frame(store, first)?.minX ?? 0, 240, accuracy: 0.001)
        XCTAssertEqual(frame(store, second)?.minX ?? 0, 268, accuracy: 0.001)
    }

    func test_pips_and_pills_do_not_push_a_new_float() throws {
        let store = makeStore()
        let request = TerminalSessionRequest(workingDirectory: "/tmp")
        let pip = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))
        store.pipPane(pip)
        let pill = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))
        store.minimizePane(pill)

        let id = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))

        XCTAssertEqual(frame(store, id)?.minX ?? 0, 240, accuracy: 0.001, "only visible floats are avoided")
    }

    func test_an_explicit_initial_frame_is_not_cascaded() throws {
        let store = makeStore()
        let request = TerminalSessionRequest(workingDirectory: "/tmp")
        _ = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))

        let id = try XCTUnwrap(store.newFloat(request: request, canvas: canvas, initialFrame: start))

        XCTAssertEqual(frame(store, id)?.minX ?? 0, 240, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private func makeStore() -> WorklaneStore {
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                columns: [
                    PaneColumnState(
                        id: PaneColumnID("col_a"),
                        panes: [PaneState(id: PaneID("a"), title: "a")],
                        width: 400,
                        focusedPaneID: PaneID("a"),
                        lastFocusedPaneID: PaneID("a")
                    ),
                ],
                focusedColumnID: PaneColumnID("col_a")
            ),
            nextPaneNumber: 2
        )
        return WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)
    }

    private func frame(_ store: WorklaneStore, _ id: PaneID) -> CGRect? {
        store.worklanes[0].floatingPane(id: id)?.floatFrame.resolved(in: canvas)
    }
}
