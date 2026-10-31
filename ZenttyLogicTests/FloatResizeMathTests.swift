import XCTest
@testable import Zentty

/// Edge-anchored 1× resize: the edge opposite the dragged handle stays fixed.
/// Coordinates are y-up (non-flipped layer space).
final class FloatResizeMathTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let minSize = FloatResizeMath.minimumFloatSize
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func resize(_ handle: FloatResizeHandle, _ delta: CGVector) -> CGRect {
        FloatResizeMath.resizeAnchored(
            handle: handle,
            delta: delta,
            frame: frame,
            minSize: minSize,
            canvas: canvas
        )
    }

    func testMinimumFloatSizeMatchesSpec() {
        XCTAssertEqual(FloatResizeMath.minimumFloatSize, CGSize(width: 300, height: 170))
    }

    func test_right_edge_keeps_left_edge_fixed() {
        let result = resize(.right, CGVector(dx: 10, dy: 0))
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 410, height: 300))
        XCTAssertEqual(result.minX, frame.minX)
    }

    func testLeftEdgeKeepsRightEdgeFixed() {
        // Left edge outward = negative dx.
        let result = resize(.left, CGVector(dx: -10, dy: 0))
        XCTAssertEqual(result, CGRect(x: 90, y: 100, width: 410, height: 300))
        XCTAssertEqual(result.maxX, frame.maxX)
    }

    func testTopEdgeKeepsBottomEdgeFixed() {
        // y-up: dragging the top edge up (+dy) grows height, minY stays put.
        let result = resize(.top, CGVector(dx: 0, dy: 10))
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 400, height: 310))
    }

    func testBottomEdgeKeepsTopEdgeFixed() {
        // Bottom edge outward = negative dy; maxY stays put.
        let result = resize(.bottom, CGVector(dx: 0, dy: -10))
        XCTAssertEqual(result, CGRect(x: 100, y: 90, width: 400, height: 310))
        XCTAssertEqual(result.maxY, frame.maxY)
    }

    func testEdgeIgnoresPerpendicularAxis() {
        XCTAssertEqual(
            resize(.right, CGVector(dx: 5, dy: 999)),
            CGRect(x: 100, y: 100, width: 405, height: 300)
        )
    }

    func testCornerMovesBothAxesAndPinsOppositeCorner() {
        // Bottom-right handle: top-left corner (minX, maxY) stays pinned.
        let result = resize(.bottomRight, CGVector(dx: 20, dy: -30))
        XCTAssertEqual(result, CGRect(x: 100, y: 70, width: 420, height: 330))
        XCTAssertEqual(result.minX, frame.minX)
        XCTAssertEqual(result.maxY, frame.maxY)
    }

    func testTopRightCornerPinsBottomLeft() {
        let result = resize(.topRight, CGVector(dx: 10, dy: 10))
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 410, height: 310))
    }

    func test_clamps_to_min_300x170() {
        // Shrink hard from the bottom-right: top-left stays pinned.
        let result = resize(.bottomRight, CGVector(dx: -1000, dy: 1000))
        XCTAssertEqual(result.size, CGSize(width: 300, height: 170))
        XCTAssertEqual(result.minX, frame.minX)
        XCTAssertEqual(result.maxY, frame.maxY)
    }

    func testLeftEdgeShrinkClampsToMinAndKeepsRightEdge() {
        let result = resize(.left, CGVector(dx: 1000, dy: 0))
        XCTAssertEqual(result.width, 300)
        XCTAssertEqual(result.maxX, frame.maxX)
    }

    func test_clamps_to_canvas() {
        let right = resize(.right, CGVector(dx: 5000, dy: 0))
        XCTAssertEqual(right, CGRect(x: 100, y: 100, width: 900, height: 300))

        let left = resize(.left, CGVector(dx: -5000, dy: 0))
        XCTAssertEqual(left, CGRect(x: 0, y: 100, width: 500, height: 300))

        let top = resize(.top, CGVector(dx: 0, dy: 5000))
        XCTAssertEqual(top, CGRect(x: 100, y: 100, width: 400, height: 700))

        let bottom = resize(.bottom, CGVector(dx: 0, dy: -5000))
        XCTAssertEqual(bottom, CGRect(x: 100, y: 0, width: 400, height: 400))
    }

    func testFrameAlreadyPastCanvasDoesNotJumpWhenShrinking() {
        // A float partly off-canvas (allowed while ≥90pt stays reachable) must shrink
        // smoothly from where it is, not snap to the canvas edge.
        let offCanvas = CGRect(x: 800, y: 100, width: 400, height: 300)
        let result = FloatResizeMath.resizeAnchored(
            handle: .right,
            delta: CGVector(dx: -10, dy: 0),
            frame: offCanvas,
            minSize: minSize,
            canvas: canvas
        )
        XCTAssertEqual(result, CGRect(x: 800, y: 100, width: 390, height: 300))
    }

    func testFrameAlreadyPastCanvasCannotGrowFurther() {
        let offCanvas = CGRect(x: 800, y: 100, width: 400, height: 300)
        let result = FloatResizeMath.resizeAnchored(
            handle: .right,
            delta: CGVector(dx: 50, dy: 0),
            frame: offCanvas,
            minSize: minSize,
            canvas: canvas
        )
        XCTAssertEqual(result, offCanvas)
    }

    func testHandleSigns() {
        XCTAssertEqual(FloatResizeHandle.right.widthSign, 1)
        XCTAssertEqual(FloatResizeHandle.left.widthSign, -1)
        XCTAssertEqual(FloatResizeHandle.top.widthSign, 0)
        XCTAssertEqual(FloatResizeHandle.top.heightSign, 1)
        XCTAssertEqual(FloatResizeHandle.bottom.heightSign, -1)
        XCTAssertEqual(FloatResizeHandle.left.heightSign, 0)
        XCTAssertTrue(FloatResizeHandle.topLeft.isCorner)
        XCTAssertFalse(FloatResizeHandle.left.isCorner)
    }
}
