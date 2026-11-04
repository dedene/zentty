import CoreGraphics

/// What a point in a float's local (non-flipped, y-up) border space does when
/// pressed: move the float, resize it via a specific handle, or fall through to
/// the terminal.
///
/// Precedence: the four corner zones resize, then the nearest edge decides.
/// The top edge band is the move handle (it carries the cwd legend); the other
/// three edges resize. Interior points and points outside `bounds` pass through.
/// Callers that want the band centred on the border line pass `bounds` already
/// outset by half the band.
enum FloatFrameRegion: Equatable, Sendable {
    case move
    case resize(FloatResizeHandle)
    case passthrough

    static func region(
        at point: CGPoint,
        bounds: CGRect,
        band: CGFloat,
        cornerZone: CGFloat
    ) -> FloatFrameRegion {
        guard let handle = resizeHandle(
            at: point, bounds: bounds, band: band, cornerZone: cornerZone
        ) else {
            return .passthrough
        }
        if handle == .top {
            return .move
        }
        return .resize(handle)
    }

    /// Classifies a point in the perimeter band into one of the eight handles,
    /// or `nil` when the point is in the interior or outside `bounds`. Corner
    /// zones take precedence over edges; otherwise the closest edge wins.
    static func resizeHandle(
        at point: CGPoint,
        bounds: CGRect,
        band: CGFloat,
        cornerZone: CGFloat
    ) -> FloatResizeHandle? {
        guard bounds.contains(point) else { return nil }
        let interior = bounds.insetBy(dx: band, dy: band)
        // `insetBy` yields a null rect when the frame is too small to have an
        // interior; treat that as "all band".
        if !interior.isNull && interior.contains(point) { return nil }

        let dLeft = point.x - bounds.minX
        let dRight = bounds.maxX - point.x
        let dBottom = point.y - bounds.minY // y-up
        let dTop = bounds.maxY - point.y

        let nearLeft = dLeft <= cornerZone
        let nearRight = dRight <= cornerZone
        let nearBottom = dBottom <= cornerZone
        let nearTop = dTop <= cornerZone

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (_, true, true, _): return .bottomRight
        case (true, _, _, true): return .topLeft
        case (_, true, _, true): return .topRight
        default: break
        }

        let minDistance = min(dLeft, dRight, dBottom, dTop)
        if minDistance == dLeft { return .left }
        if minDistance == dRight { return .right }
        if minDistance == dBottom { return .bottom }
        return .top
    }
}
