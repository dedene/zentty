import XCTest
@testable import Zentty

final class FloatDragVelocityEstimatorTests: XCTestCase {
    func testNoSamplesIsZeroVelocity() {
        let estimator = FloatDragVelocityEstimator()
        XCTAssertEqual(estimator.velocity, .zero)
    }

    func testSingleSampleIsZeroVelocity() {
        var estimator = FloatDragVelocityEstimator()
        estimator.record(FloatDragSample(timestamp: 0, point: .zero))
        XCTAssertEqual(estimator.velocity, .zero)
    }

    func testHorizontalVelocityMagnitudeAndDirection() {
        var estimator = FloatDragVelocityEstimator()
        estimator.record(FloatDragSample(timestamp: 0, point: CGPoint(x: 0, y: 0)))
        estimator.record(FloatDragSample(timestamp: 0.1, point: CGPoint(x: 10, y: 0)))
        // 10 pt over 0.1 s = 100 pt/s, purely +x.
        XCTAssertEqual(estimator.velocity.dx, 100, accuracy: 0.0001)
        XCTAssertEqual(estimator.velocity.dy, 0, accuracy: 0.0001)
    }

    func testDiagonalVelocityDirection() {
        var estimator = FloatDragVelocityEstimator()
        estimator.record(FloatDragSample(timestamp: 0, point: CGPoint(x: 100, y: 100)))
        estimator.record(FloatDragSample(timestamp: 0.2, point: CGPoint(x: 60, y: 140)))
        // Moving -x, +y over 0.2 s: (-40/0.2, 40/0.2) = (-200, 200).
        XCTAssertEqual(estimator.velocity.dx, -200, accuracy: 0.0001)
        XCTAssertEqual(estimator.velocity.dy, 200, accuracy: 0.0001)
    }

    func testRetainsOnlyLastFiveSamples() {
        var estimator = FloatDragVelocityEstimator()
        for i in 0...9 {
            estimator.record(FloatDragSample(timestamp: Double(i), point: CGPoint(x: i, y: 0)))
        }
        XCTAssertEqual(estimator.samples.count, FloatDragVelocityEstimator.windowSize)
        // Window is samples t=5..9 → (9-5)/(9-5) = 1 pt/s.
        XCTAssertEqual(estimator.samples.first?.timestamp, 5)
        XCTAssertEqual(estimator.velocity.dx, 1, accuracy: 0.0001)
    }
}

final class FloatDragSessionTests: XCTestCase {
    private func session() -> FloatDragSession {
        FloatDragSession(
            startMouse: CGPoint(x: 500, y: 400),
            startFrame: CGRect(x: 300, y: 250, width: 400, height: 300),
            timestamp: 0
        )
    }

    func testTranslationTracksPointerDelta() {
        var session = session()
        session.move(to: CGPoint(x: 520, y: 410), timestamp: 0.1)
        XCTAssertEqual(session.translation.dx, 20)
        XCTAssertEqual(session.translation.dy, 10)
    }

    func testCurrentFrameAppliesTranslationToStartFrame() {
        var session = session()
        session.move(to: CGPoint(x: 520, y: 410), timestamp: 0.1)
        XCTAssertEqual(session.currentFrame, CGRect(x: 320, y: 260, width: 400, height: 300))
    }

    func testCurrentCenterFollowsFrame() {
        var session = session()
        session.move(to: CGPoint(x: 600, y: 500), timestamp: 0.1)
        // Frame origin (400, 350), size 400×300 → center (600, 500).
        XCTAssertEqual(session.currentCenter, CGPoint(x: 600, y: 500))
    }

    func testTinyMovementCountsAsClick() {
        var session = session()
        session.move(to: CGPoint(x: 501, y: 401), timestamp: 0.1) // hypot ≈ 1.41 < 3
        XCTAssertTrue(session.isClick)
    }

    func testMeaningfulMovementIsNotClick() {
        var session = session()
        session.move(to: CGPoint(x: 500, y: 410), timestamp: 0.1) // 10 pt
        XCTAssertFalse(session.isClick)
    }

    func testVelocityReportedAtDragEnd() {
        var session = session()
        session.move(to: CGPoint(x: 500, y: 400), timestamp: 0) // reset baseline direction
        session.move(to: CGPoint(x: 550, y: 400), timestamp: 0.1)
        // From first sample (500,400)@0 to last (550,400)@0.1 → 500 pt/s +x.
        XCTAssertEqual(session.velocity.dx, 500, accuracy: 0.0001)
    }
}
