import CoreGraphics
import XCTest
@testable import Zentty

final class FloatLayoutTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)

    // MARK: - PiP size

    func test_pipSize_follows_float_aspect() {
        let size = FloatLayout.pipSize(floatSize: CGSize(width: 800, height: 500), width: 232)
        XCTAssertEqual(size.width, 232)
        XCTAssertEqual(size.height, 145, accuracy: 0.001)
    }

    func test_pipSize_clamps_wide_float_to_minimum_ratio() {
        let size = FloatLayout.pipSize(floatSize: CGSize(width: 1000, height: 200), width: 232)
        XCTAssertEqual(size.height, 232 * 0.45, accuracy: 0.001)
    }

    func test_pipSize_clamps_tall_float_to_maximum_ratio() {
        let size = FloatLayout.pipSize(floatSize: CGSize(width: 300, height: 600), width: 300)
        XCTAssertEqual(size.height, 300 * 0.9, accuracy: 0.001)
    }

    func test_pipSize_degenerate_float_uses_minimum_ratio() {
        let size = FloatLayout.pipSize(floatSize: .zero, width: 232)
        XCTAssertEqual(size.height, 232 * 0.45, accuracy: 0.001)
    }

    // MARK: - PiP frames

    func test_pipFrame_bottomRight_first_uses_margin() {
        let size = CGSize(width: 232, height: 145)
        let frame = FloatLayout.pipFrame(corner: .bottomRight, indexInCorner: 0, size: size, canvas: canvas, bottomInset: 0)
        XCTAssertEqual(frame, CGRect(x: 1200 - 14 - 232, y: 14, width: 232, height: 145))
    }

    func test_pipFrame_second_in_corner_stacks_with_gap() {
        let size = CGSize(width: 232, height: 145)
        let frame = FloatLayout.pipFrame(corner: .bottomLeft, indexInCorner: 1, size: size, canvas: canvas, bottomInset: 0)
        XCTAssertEqual(frame, CGRect(x: 14, y: 14 + 145 + 10, width: 232, height: 145))
    }

    func test_pipFrame_top_corners_stack_downward() {
        let size = CGSize(width: 232, height: 145)
        let first = FloatLayout.pipFrame(corner: .topLeft, indexInCorner: 0, size: size, canvas: canvas, bottomInset: 0)
        let second = FloatLayout.pipFrame(corner: .topRight, indexInCorner: 1, size: size, canvas: canvas, bottomInset: 0)
        XCTAssertEqual(first, CGRect(x: 14, y: 800 - 14 - 145, width: 232, height: 145))
        XCTAssertEqual(second, CGRect(x: 1200 - 14 - 232, y: 800 - 14 - 145 - 155, width: 232, height: 145))
    }

    func test_pipFrame_bottomInset_lifts_only_bottom_corners() {
        let size = CGSize(width: 232, height: 145)
        let bottom = FloatLayout.pipFrame(corner: .bottomRight, indexInCorner: 0, size: size, canvas: canvas, bottomInset: 46)
        let top = FloatLayout.pipFrame(corner: .topRight, indexInCorner: 0, size: size, canvas: canvas, bottomInset: 46)
        XCTAssertEqual(bottom.minY, 14 + 46)
        XCTAssertEqual(top.minY, 800 - 14 - 145)
    }

    func test_pipFrame_respects_canvas_origin() {
        let offsetCanvas = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let size = CGSize(width: 232, height: 145)
        let frame = FloatLayout.pipFrame(corner: .bottomLeft, indexInCorner: 0, size: size, canvas: offsetCanvas, bottomInset: 0)
        XCTAssertEqual(frame.origin, CGPoint(x: 114, y: 64))
    }

    // MARK: - Eviction

    private func pip(_ id: String, _ corner: FloatCorner, order: Int) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: PaneID(id), title: id),
            mode: .pip(corner: corner, order: order),
            floatFrame: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5),
            stackOrder: 0,
            origin: nil
        )
    }

    func test_evictionCandidate_nil_below_cap() {
        let floats = [pip("a", .bottomRight, order: 0), pip("b", .topLeft, order: 0)]
        XCTAssertNil(FloatLayout.evictionCandidate(in: floats, corner: .bottomRight, incoming: PaneID("c")))
    }

    func test_evictionCandidate_returns_oldest_at_cap() {
        let floats = [pip("newer", .bottomRight, order: 1), pip("older", .bottomRight, order: 0)]
        XCTAssertEqual(
            FloatLayout.evictionCandidate(in: floats, corner: .bottomRight, incoming: PaneID("c")),
            PaneID("older")
        )
    }

    func test_evictionCandidate_ignores_incoming_already_in_corner() {
        let floats = [pip("a", .bottomRight, order: 0), pip("b", .bottomRight, order: 1)]
        XCTAssertNil(FloatLayout.evictionCandidate(in: floats, corner: .bottomRight, incoming: PaneID("b")))
    }

    // MARK: - Float frames

    func test_liftedFrame_insets_tile_slot_by_22() {
        let tile = CGRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertEqual(
            FloatLayout.liftedFrame(tileFrame: tile, canvas: canvas),
            CGRect(x: 122, y: 122, width: 556, height: 456)
        )
    }

    func test_liftedFrame_grows_small_tile_to_minimum_around_centre() {
        let tile = CGRect(x: 400, y: 300, width: 200, height: 150)
        let frame = FloatLayout.liftedFrame(tileFrame: tile, canvas: canvas)
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 170))
        XCTAssertEqual(frame.midX, tile.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, tile.midY, accuracy: 0.001)
    }

    func test_liftedFrame_clamps_offscreen_tile_into_canvas() {
        let tile = CGRect(x: 1000, y: 100, width: 600, height: 500)
        let frame = FloatLayout.liftedFrame(tileFrame: tile, canvas: canvas)
        XCTAssertEqual(frame.maxX, canvas.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.width, 556, accuracy: 0.001)
    }

    func test_splitOffsetFrame_moves_down_right_by_28() {
        let frame = CGRect(x: 100, y: 300, width: 400, height: 300)
        XCTAssertEqual(
            FloatLayout.splitOffsetFrame(from: frame, canvas: canvas),
            CGRect(x: 128, y: 272, width: 400, height: 300)
        )
    }

    func test_splitOffsetFrame_clamps_at_canvas_edge() {
        let frame = CGRect(x: 790, y: 10, width: 400, height: 300)
        let shifted = FloatLayout.splitOffsetFrame(from: frame, canvas: canvas)
        XCTAssertEqual(shifted, CGRect(x: 800, y: 0, width: 400, height: 300))
    }

    func test_centeredFrame_centres_default_size() {
        let frame = FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
        XCTAssertEqual(frame, CGRect(x: 240, y: 160, width: 720, height: 480))
    }
}
