import CoreGraphics

/// Computes proximity-based vertical edge scroll velocity for sidebar during drag.
/// Speed ramps with cubic ease-in from zone boundary to viewport edge.
enum PaneDragSidebarEdgeScrollDriver {

    static let edgeZone: CGFloat = 60
    static let maxSpeed: CGFloat = 600

    /// Returns scroll velocity in points per second.
    /// Negative = scroll up, positive = scroll down, 0 = not in edge zone.
    static func velocity(
        cursorY: CGFloat,
        sidebarMinY: CGFloat,
        sidebarMaxY: CGFloat,
        edgeZone: CGFloat = PaneDragSidebarEdgeScrollDriver.edgeZone,
        maxSpeed: CGFloat = PaneDragSidebarEdgeScrollDriver.maxSpeed
    ) -> CGFloat {
        let height = sidebarMaxY - sidebarMinY
        guard height > edgeZone * 2 else { return 0 }

        // Bottom edge (low Y in bottom-left coords) — scroll down (negative)
        let bottomZoneEnd = sidebarMinY + edgeZone
        if cursorY < bottomZoneEnd {
            let proximity = max(0, min(1, 1 - (cursorY - sidebarMinY) / edgeZone))
            let eased = proximity * proximity * proximity
            return -maxSpeed * eased
        }

        // Top edge (high Y in bottom-left coords) — scroll up (positive)
        let topZoneStart = sidebarMaxY - edgeZone
        if cursorY > topZoneStart {
            let proximity = max(0, min(1, (cursorY - topZoneStart) / edgeZone))
            let eased = proximity * proximity * proximity
            return maxSpeed * eased
        }

        return 0
    }
}
