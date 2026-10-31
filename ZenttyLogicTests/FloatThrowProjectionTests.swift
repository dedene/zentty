import XCTest
@testable import Zentty

final class FloatThrowProjectionTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private var center: CGPoint { CGPoint(x: canvas.midX, y: canvas.midY) }

    // MARK: - Constants

    func testSpecConstants() {
        XCTAssertEqual(FloatThrowProjection.decelerationRate, 0.998, accuracy: 0.00001)
        XCTAssertEqual(FloatThrowProjection.pipThreshold, 1100)
    }

    // MARK: - Projection

    func test_projection_units() {
        // displacement = (v / 1000) · d / (1 − d), d = 0.998
        let slow = FloatThrowProjection.projectedPoint(from: .zero, velocity: CGVector(dx: 100, dy: 0))
        XCTAssertEqual(slow.x, 49.9, accuracy: 0.1)
        XCTAssertEqual(slow.y, 0, accuracy: 0.0001)

        let fast = FloatThrowProjection.projectedPoint(from: .zero, velocity: CGVector(dx: 2000, dy: 0))
        XCTAssertEqual(fast.x, 998, accuracy: 0.5)
    }

    func testProjectionUnitSanity1000PtPerSecTravelsAbout500Pt() {
        // A 1000 pt/s fling must coast ~500 pt, not ~500,000.
        let projected = FloatThrowProjection.projectedPoint(
            from: CGPoint(x: 0, y: 0),
            velocity: CGVector(dx: 1000, dy: 0)
        )
        XCTAssertEqual(projected.x, 499, accuracy: 1)
        XCTAssertEqual(projected.y, 0, accuracy: 0.0001)
    }

    func testProjectionStartsFromGivenPoint() {
        let projected = FloatThrowProjection.projectedPoint(
            from: CGPoint(x: 10, y: 20),
            velocity: CGVector(dx: 0, dy: -100)
        )
        XCTAssertEqual(projected.x, 10, accuracy: 0.0001)
        XCTAssertEqual(projected.y, 20 - 49.9, accuracy: 0.1)
    }

    // MARK: - Nearest corner (y-up)

    func testNearestCornerQuadrants() {
        XCTAssertEqual(FloatThrowProjection.nearestCorner(to: CGPoint(x: 100, y: 100), in: canvas), .bottomLeft)
        XCTAssertEqual(FloatThrowProjection.nearestCorner(to: CGPoint(x: 900, y: 100), in: canvas), .bottomRight)
        XCTAssertEqual(FloatThrowProjection.nearestCorner(to: CGPoint(x: 100, y: 700), in: canvas), .topLeft)
        XCTAssertEqual(FloatThrowProjection.nearestCorner(to: CGPoint(x: 900, y: 700), in: canvas), .topRight)
    }

    func testNearestCornerRespectsCanvasOrigin() {
        let offset = CGRect(x: 200, y: 0, width: 800, height: 800)
        // x = 500 is left of offset.midX (600).
        XCTAssertEqual(FloatThrowProjection.nearestCorner(to: CGPoint(x: 500, y: 700), in: offset), .topLeft)
    }

    // MARK: - Throw corner

    func test_below_threshold_returns_nil() {
        XCTAssertNil(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 1099, dy: 0),
            position: center,
            in: canvas
        ))
    }

    func testAtThresholdThrows() {
        XCTAssertNotNil(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 1100, dy: 0),
            position: center,
            in: canvas
        ))
    }

    func testThresholdUsesSpeedMagnitude() {
        // Neither component reaches 1100 on its own, but the speed (≈1131) does.
        XCTAssertNotNil(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 800, dy: -800),
            position: center,
            in: canvas
        ))
    }

    func test_fast_throw_down_right_picks_bottomRight() {
        // y-up: "down" is negative dy. Start top-left so position alone would say topLeft.
        let corner = FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 1500, dy: -1500),
            position: CGPoint(x: 100, y: 700),
            in: canvas
        )
        XCTAssertEqual(corner, .bottomRight)
    }

    func testFastThrowUpLeftPicksTopLeft() {
        let corner = FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: -1500, dy: 1500),
            position: CGPoint(x: 900, y: 100),
            in: canvas
        )
        XCTAssertEqual(corner, .topLeft)
    }

    func testHorizontalThrowTakesVerticalSideFromPosition() {
        // Pure rightward throw from the lower half → bottomRight; from the upper half → topRight.
        XCTAssertEqual(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 2000, dy: 0),
            position: CGPoint(x: 100, y: 200),
            in: canvas
        ), .bottomRight)
        XCTAssertEqual(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 2000, dy: 0),
            position: CGPoint(x: 100, y: 600),
            in: canvas
        ), .topRight)
    }

    func testVerticalThrowTakesHorizontalSideFromPosition() {
        // Mostly upward throw with a weak sideways component (< 0.35 · 1100 = 385):
        // the horizontal side comes from the position.
        XCTAssertEqual(FloatThrowProjection.throwCorner(
            velocity: CGVector(dx: 300, dy: 2000),
            position: CGPoint(x: 100, y: 400),
            in: canvas
        ), .topLeft)
    }
}
