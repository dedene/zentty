import XCTest
@testable import Zentty

final class FloatLayerCenteringTests: XCTestCase {
    func testCenteredFrameWithinCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 600, height: 400)
        let frame = FloatLayerCentering.centeredFrame(forFloatSize: size, in: canvas)
        XCTAssertEqual(frame, CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    func testFloatLargerThanCanvasIsScaledToFit() {
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 1000, height: 700)
        let frame = FloatLayerCentering.centeredFrame(forFloatSize: size, in: canvas)
        // Width-bound: scale = 800/1000 = 0.8 → 800 × 560
        XCTAssertEqual(frame, CGRect(x: 0, y: 20, width: 800, height: 560))
    }

    func testCanvasOriginIsRespected() {
        let canvas = CGRect(x: 100, y: 50, width: 800, height: 600)
        let size = CGSize(width: 400, height: 300)
        let frame = FloatLayerCentering.centeredFrame(forFloatSize: size, in: canvas)
        XCTAssertEqual(frame, CGRect(x: 300, y: 200, width: 400, height: 300))
    }

    func testEffectiveCanvasRectInsetsLeadingEdge() {
        let rect = FloatLayerCentering.effectiveCanvasRect(
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
            leadingInset: 240
        )
        XCTAssertEqual(rect, CGRect(x: 240, y: 0, width: 760, height: 800))
    }

    func testEffectiveCanvasRectClampsNegativeAndOversizedInset() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            FloatLayerCentering.effectiveCanvasRect(bounds: bounds, leadingInset: -50),
            bounds
        )
        XCTAssertEqual(
            FloatLayerCentering.effectiveCanvasRect(bounds: bounds, leadingInset: 5000),
            CGRect(x: 1000, y: 0, width: 0, height: 800)
        )
    }
}
