import CoreGraphics

enum SidebarWorklaneReorderModel {
    static func previewOrder(
        currentOrder: [WorklaneID],
        draggedID: WorklaneID,
        insertionIndex: Int
    ) -> [WorklaneID]? {
        guard currentOrder.contains(draggedID) else {
            return nil
        }

        var order = currentOrder.filter { $0 != draggedID }
        guard insertionIndex >= 0, insertionIndex <= order.count else {
            return nil
        }

        order.insert(draggedID, at: insertionIndex)
        return order
    }

    static func insertionIndex(
        cursorY: CGFloat,
        rowFrames: [(WorklaneID, CGRect)],
        draggedID: WorklaneID?
    ) -> Int {
        let frames = rowFrames
            .filter { worklaneID, _ in worklaneID != draggedID }
            .sorted { lhs, rhs in lhs.1.minY < rhs.1.minY }

        for (index, frame) in frames.map(\.1).enumerated() {
            if cursorY < frame.midY {
                return index
            }
        }

        return frames.count
    }

    static func autoScrollVelocity(
        cursorY: CGFloat,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat,
        edgeZone: CGFloat = 30,
        maxSpeed: CGFloat = 240
    ) -> CGFloat {
        guard edgeZone > 0, maxSpeed > 0, visibleMaxY > visibleMinY else {
            return 0
        }

        let topDistance = cursorY - visibleMinY
        if topDistance < edgeZone {
            let progress = max(0, min(1, (edgeZone - topDistance) / edgeZone))
            return -maxSpeed * progress
        }

        let bottomDistance = visibleMaxY - cursorY
        if bottomDistance < edgeZone {
            let progress = max(0, min(1, (edgeZone - bottomDistance) / edgeZone))
            return maxSpeed * progress
        }

        return 0
    }
}
