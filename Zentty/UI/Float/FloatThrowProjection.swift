import CoreGraphics

/// Throw-to-PiP math: where a released float would coast to, and which canvas
/// corner a fast enough throw lands in. Coordinates are y-up; velocities are in
/// pt/s (as reported by ``FloatDragVelocityEstimator``).
enum FloatThrowProjection {
    /// Per-millisecond deceleration of the coast (scroll-view "normal" rate).
    static let decelerationRate: CGFloat = 0.998
    /// Minimum release speed (pt/s) for a throw to turn a float into a PiP.
    static let pipThreshold: CGFloat = 1100
    /// A velocity component counts as a direction only above this fraction of
    /// ``pipThreshold``; weaker components take their side from the position.
    static let directionalComponentFraction: CGFloat = 0.35

    /// Coast landing point: `p + (v / 1000) · d / (1 − d)`. The `/ 1000`
    /// converts pt/s to the per-millisecond rate `d` is expressed in, so
    /// 100 pt/s coasts ≈49.9pt and 2000 pt/s ≈998pt.
    static func projectedPoint(from point: CGPoint, velocity: CGVector) -> CGPoint {
        let factor = decelerationRate / (1 - decelerationRate) / 1000
        return CGPoint(
            x: point.x + velocity.dx * factor,
            y: point.y + velocity.dy * factor
        )
    }

    /// Quadrant of `canvas` that `point` falls in.
    static func nearestCorner(to point: CGPoint, in canvas: CGRect) -> FloatCorner {
        corner(isLeft: point.x < canvas.midX, isBottom: point.y < canvas.midY)
    }

    /// The corner a throw lands in, or `nil` when the release speed is below
    /// ``pipThreshold``. Each axis takes its side from the velocity sign when
    /// that component is strong enough, otherwise from `position`.
    static func throwCorner(velocity: CGVector, position: CGPoint, in canvas: CGRect) -> FloatCorner? {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed >= pipThreshold else { return nil }

        let directional = directionalComponentFraction * pipThreshold
        let isLeft = abs(velocity.dx) > directional
            ? velocity.dx < 0
            : position.x < canvas.midX
        let isBottom = abs(velocity.dy) > directional
            ? velocity.dy < 0
            : position.y < canvas.midY
        return corner(isLeft: isLeft, isBottom: isBottom)
    }

    private static func corner(isLeft: Bool, isBottom: Bool) -> FloatCorner {
        switch (isLeft, isBottom) {
        case (true, true): return .bottomLeft
        case (false, true): return .bottomRight
        case (true, false): return .topLeft
        case (false, false): return .topRight
        }
    }
}
