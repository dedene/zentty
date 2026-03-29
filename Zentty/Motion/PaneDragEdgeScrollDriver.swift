import CoreGraphics

/// Computes proximity-based edge scroll velocity for drag-and-drop.
/// Speed ramps linearly from 0 at `edgeZone` distance to `maxSpeed` at the viewport edge.
enum PaneDragEdgeScrollDriver {

    static let edgeZone: CGFloat = 60
    static let maxSpeed: CGFloat = 400

    /// Returns scroll velocity in points per second.
    /// Negative = scroll left, positive = scroll right, 0 = not in edge zone.
    static func velocity(
        cursorX: CGFloat,
        viewportWidth: CGFloat,
        edgeZone: CGFloat = PaneDragEdgeScrollDriver.edgeZone,
        maxSpeed: CGFloat = PaneDragEdgeScrollDriver.maxSpeed
    ) -> CGFloat {
        guard viewportWidth > edgeZone * 2 else { return 0 }

        if cursorX < edgeZone {
            let proximity = max(0, min(1, 1 - cursorX / edgeZone))
            return -maxSpeed * proximity
        }

        let rightEdgeStart = viewportWidth - edgeZone
        if cursorX > rightEdgeStart {
            let proximity = max(0, min(1, (cursorX - rightEdgeStart) / edgeZone))
            return maxSpeed * proximity
        }

        return 0
    }
}
