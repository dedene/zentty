import CoreGraphics
import XCTest
@testable import Zentty

final class FloatLayerLayoutTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func float(
        _ id: String,
        mode: FloatingPaneMode = .floating,
        frame: NormalizedRect = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
        stackOrder: Int = 0
    ) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: PaneID(id), title: id),
            mode: mode,
            floatFrame: frame,
            stackOrder: stackOrder,
            origin: nil
        )
    }

    func test_floating_float_resolves_its_normalized_frame() {
        let placements = FloatLayerLayout.placements(floats: [float("a")], floatsHidden: false, canvas: canvas)

        XCTAssertEqual(placements, [
            FloatLayerPlacement(
                paneID: PaneID("a"),
                kind: .floating,
                frame: CGRect(x: 100, y: 120, width: 500, height: 300)
            ),
        ])
    }

    func test_minimized_float_is_not_mounted() {
        let placements = FloatLayerLayout.placements(
            floats: [float("a"), float("b", mode: .minimized(order: 0))],
            floatsHidden: false,
            canvas: canvas
        )

        XCTAssertEqual(placements.map(\.paneID), [PaneID("a")])
    }

    func test_hidden_floats_mount_nothing() {
        let placements = FloatLayerLayout.placements(
            floats: [float("a"), float("b", mode: .pip(corner: .bottomRight, order: 0))],
            floatsHidden: true,
            canvas: canvas
        )

        XCTAssertTrue(placements.isEmpty)
    }

    func test_placements_follow_stack_order_back_to_front() {
        let placements = FloatLayerLayout.placements(
            floats: [float("front", stackOrder: 5), float("back", stackOrder: 1), float("middle", stackOrder: 3)],
            floatsHidden: false,
            canvas: canvas
        )

        XCTAssertEqual(placements.map(\.paneID), [PaneID("back"), PaneID("middle"), PaneID("front")])
    }

    func test_float_frame_is_kept_inside_the_canvas() {
        let offCanvas = float("a", frame: NormalizedRect(x: 0.8, y: -0.2, width: 0.5, height: 0.5))

        let frame = FloatLayerLayout.floatFrame(for: offCanvas, canvas: canvas)

        XCTAssertTrue(canvas.contains(frame), "\(frame) should be inside \(canvas)")
        XCTAssertEqual(frame.size, CGSize(width: 500, height: 300))
    }

    func test_pip_keeps_its_float_size_as_content_and_sits_in_its_corner() throws {
        let placements = FloatLayerLayout.placements(
            floats: [float("a", mode: .pip(corner: .bottomRight, order: 0))],
            floatsHidden: false,
            canvas: canvas
        )

        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.kind, .pip(contentSize: CGSize(width: 500, height: 300)))
        XCTAssertEqual(placement.frame.width, FloatLayout.pipSmallWidth)
        XCTAssertEqual(placement.frame.height, FloatLayout.pipSmallWidth * 0.6, accuracy: 0.001)
        XCTAssertEqual(placement.frame.maxX, canvas.maxX - FloatLayout.pipMargin, accuracy: 0.001)
        XCTAssertEqual(placement.frame.minY, canvas.minY + FloatLayout.pipMargin, accuracy: 0.001)
    }

    func test_second_pip_in_a_corner_stacks_above_the_first_by_its_height() throws {
        let tall = NormalizedRect(x: 0, y: 0, width: 0.3, height: 0.4)
        let placements = FloatLayerLayout.placements(
            floats: [
                float("outer", mode: .pip(corner: .bottomLeft, order: 1)),
                float("inner", mode: .pip(corner: .bottomLeft, order: 0), frame: tall),
            ],
            floatsHidden: false,
            canvas: canvas
        )

        let inner = try XCTUnwrap(placements.first { $0.paneID == PaneID("inner") })
        let outer = try XCTUnwrap(placements.first { $0.paneID == PaneID("outer") })
        XCTAssertEqual(inner.frame.minY, FloatLayout.pipMargin, accuracy: 0.001)
        XCTAssertEqual(outer.frame.minY, inner.frame.maxY + FloatLayout.pipGap, accuracy: 0.001)
        XCTAssertEqual(outer.frame.minX, FloatLayout.pipMargin, accuracy: 0.001)
    }

    func test_top_corner_pips_stack_downward() throws {
        let placements = FloatLayerLayout.placements(
            floats: [
                float("first", mode: .pip(corner: .topRight, order: 0)),
                float("second", mode: .pip(corner: .topRight, order: 1)),
            ],
            floatsHidden: false,
            canvas: canvas
        )

        let first = try XCTUnwrap(placements.first { $0.paneID == PaneID("first") })
        let second = try XCTUnwrap(placements.first { $0.paneID == PaneID("second") })
        XCTAssertEqual(first.frame.maxY, canvas.maxY - FloatLayout.pipMargin, accuracy: 0.001)
        XCTAssertEqual(second.frame.maxY, first.frame.minY - FloatLayout.pipGap, accuracy: 0.001)
    }

    func test_empty_canvas_mounts_nothing() {
        let placements = FloatLayerLayout.placements(floats: [float("a")], floatsHidden: false, canvas: .zero)

        XCTAssertTrue(placements.isEmpty)
    }
}
