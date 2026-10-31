import CoreGraphics
import Foundation

/// Pure, logic-testable derivation of the PiP snap spring.
///
/// Translates a SwiftUI-style (`response`, `dampingRatio`) spring into the
/// `mass`/`stiffness`/`damping` triple `CASpringAnimation` expects, and
/// normalizes the gesture's release velocity into the "distance per second /
/// total distance" unit `CASpringAnimation.initialVelocity` wants. The view
/// layer builds the `CASpringAnimation` from these numbers and nothing else, so
/// the math is verifiable without a running layer.
struct FloatSnapSpring: Equatable, Sendable {
    /// Under-damped: a small, visible overshoot before settling.
    static let dampingRatio: CGFloat = 0.78
    /// Perceptual period of the spring, in seconds.
    static let response: CGFloat = 0.42
    /// Unit mass keeps stiffness/damping in intuitive ranges.
    static let defaultMass: CGFloat = 1

    var mass: CGFloat
    var stiffness: CGFloat
    var damping: CGFloat
    var initialVelocity: CGFloat

    /// Spring for a `from → to` move, seeded with the gesture's release velocity.
    static func parameters(
        from: CGPoint,
        to: CGPoint,
        gestureVelocity: CGVector
    ) -> FloatSnapSpring {
        let omega = 2 * CGFloat.pi / response
        let stiffness = omega * omega * defaultMass
        let damping = 2 * dampingRatio * omega * defaultMass
        return FloatSnapSpring(
            mass: defaultMass,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: normalizedInitialVelocity(
                from: from,
                to: to,
                gestureVelocity: gestureVelocity
            )
        )
    }

    /// Component of the gesture velocity along the travel direction, normalized
    /// by the total travel distance. Zero when there is no distance to cover.
    ///
    /// `CASpringAnimation.initialVelocity` is scalar and interprets `1` as
    /// "cover the whole animation distance in one second", so a raw pt/s vector
    /// must be projected onto the travel line and divided by that distance.
    static func normalizedInitialVelocity(
        from: CGPoint,
        to: CGPoint,
        gestureVelocity: CGVector
    ) -> CGFloat {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return 0 }
        let along = (gestureVelocity.dx * dx + gestureVelocity.dy * dy) / distance
        return along / distance
    }
}
