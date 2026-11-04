import XCTest
@testable import Zentty

@MainActor
final class FloatMotionTests: XCTestCase {
    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    func test_lifted_frame_grows_12pt_wide_about_centre() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 300)

        let lifted = FloatMotion.liftedFrame(frame)

        XCTAssertEqual(lifted.width, 612, accuracy: 0.001)
        XCTAssertEqual(lifted.height, 306, accuracy: 0.001, "uniform scale 1 + 12/width")
        XCTAssertEqual(lifted.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(lifted.midY, frame.midY, accuracy: 0.001)
    }

    func test_reduce_motion_override() {
        FloatMotion.reduceMotionOverride = true
        XCTAssertTrue(FloatMotion.reduceMotion)
        XCTAssertEqual(FloatMotion.reflowMotion.duration, FloatMotion.reducedDuration)

        FloatMotion.reduceMotionOverride = false
        XCTAssertFalse(FloatMotion.reduceMotion)
        XCTAssertEqual(FloatMotion.reflowMotion.duration, 0.36)
    }

    func test_settle_transform_maps_model_onto_visible_frame() {
        let model = CGRect(x: 100, y: 50, width: 400, height: 200)
        let visible = FloatMotion.liftedFrame(model.offsetBy(dx: 30, dy: -10))

        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
            let transform = FloatLayerView.transform(mapping: model, to: visible, anchorPoint: anchor)
            let affine = CATransform3DGetAffineTransform(transform)
            let anchorInSuper = CGPoint(x: model.minX + anchor.x * model.width, y: model.minY + anchor.y * model.height)
            func world(_ local: CGPoint) -> CGPoint {
                let relative = CGPoint(x: local.x - anchor.x * model.width, y: local.y - anchor.y * model.height)
                let mapped = relative.applying(affine)
                return CGPoint(x: anchorInSuper.x + mapped.x, y: anchorInSuper.y + mapped.y)
            }
            let bottomLeft = world(.zero)
            let topRight = world(CGPoint(x: model.width, y: model.height))
            XCTAssertEqual(bottomLeft.x, visible.minX, accuracy: 0.001)
            XCTAssertEqual(bottomLeft.y, visible.minY, accuracy: 0.001)
            XCTAssertEqual(topRight.x, visible.maxX, accuracy: 0.001)
            XCTAssertEqual(topRight.y, visible.maxY, accuracy: 0.001)
        }
    }
}
