import XCTest
@testable import Zentty

final class FloatSnapSpringTests: XCTestCase {
    // MARK: - Spec constants

    func testSpecConstants() {
        XCTAssertEqual(FloatSnapSpring.response, 0.42, accuracy: 0.0001)
        XCTAssertEqual(FloatSnapSpring.dampingRatio, 0.78, accuracy: 0.0001)
    }

    // MARK: - response/dampingRatio → mass/stiffness/damping

    func testStiffnessAndDampingFromResponseAndDampingRatio() {
        let spring = FloatSnapSpring.parameters(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            gestureVelocity: .zero
        )
        let omega = 2 * CGFloat.pi / FloatSnapSpring.response
        XCTAssertEqual(spring.mass, 1, accuracy: 0.0001)
        // stiffness = ω²·m
        XCTAssertEqual(spring.stiffness, omega * omega, accuracy: 0.001)
        // damping = 2·ζ·ω·m
        XCTAssertEqual(spring.damping, 2 * FloatSnapSpring.dampingRatio * omega, accuracy: 0.001)
    }

    func testSpringIsUnderDamped() {
        // A damping ratio < 1 means an under-damped spring (visible overshoot).
        let spring = FloatSnapSpring.parameters(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            gestureVelocity: .zero
        )
        // Reconstruct ζ = damping / (2·√(stiffness·mass)).
        let ratio = spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot())
        XCTAssertEqual(ratio, FloatSnapSpring.dampingRatio, accuracy: 0.001)
        XCTAssertLessThan(ratio, 1)
    }

    // MARK: - Normalized initial velocity

    func testInitialVelocityNormalizesAlongTravelDirection() {
        // 50 pt/s along +x over a 100 pt move → 0.5 (half the distance per second).
        let v = FloatSnapSpring.normalizedInitialVelocity(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            gestureVelocity: CGVector(dx: 50, dy: 0)
        )
        XCTAssertEqual(v, 0.5, accuracy: 0.0001)
    }

    func testInitialVelocityIgnoresPerpendicularComponent() {
        // Velocity purely perpendicular to the travel line contributes nothing.
        let v = FloatSnapSpring.normalizedInitialVelocity(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            gestureVelocity: CGVector(dx: 0, dy: 50)
        )
        XCTAssertEqual(v, 0, accuracy: 0.0001)
    }

    func testInitialVelocityDiagonalProjectsOntoTravelLine() {
        // Gesture parallel to the diagonal travel: |v| == distance → 1.0.
        let v = FloatSnapSpring.normalizedInitialVelocity(
            from: .zero,
            to: CGPoint(x: 100, y: 100),
            gestureVelocity: CGVector(dx: 100, dy: 100)
        )
        XCTAssertEqual(v, 1, accuracy: 0.0001)
    }

    func testInitialVelocityNegativeWhenGestureOpposesTravel() {
        let v = FloatSnapSpring.normalizedInitialVelocity(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            gestureVelocity: CGVector(dx: -80, dy: 0)
        )
        XCTAssertEqual(v, -0.8, accuracy: 0.0001)
    }

    func testInitialVelocityZeroWhenNoTravelDistance() {
        // No distance to cover (from == to) must not divide by zero.
        let v = FloatSnapSpring.normalizedInitialVelocity(
            from: CGPoint(x: 42, y: 42),
            to: CGPoint(x: 42, y: 42),
            gestureVelocity: CGVector(dx: 500, dy: 500)
        )
        XCTAssertEqual(v, 0, accuracy: 0.0001)
    }
}
