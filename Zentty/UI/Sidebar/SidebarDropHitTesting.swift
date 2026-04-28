import CoreGraphics

enum SidebarDropHitTarget: Equatable {
    case row(WorklaneID)
    case newWorklane
    case none
}

enum SidebarDropHitTesting {
    static func target(
        cursorInStrip: CGPoint,
        worklaneFrames: [(WorklaneID, CGRect)],
        activeWorklaneID: WorklaneID?,
        sidebarBottomY: CGFloat
    ) -> SidebarDropHitTarget {
        for (worklaneID, frame) in worklaneFrames {
            guard worklaneID != activeWorklaneID else { continue }
            if frame.contains(cursorInStrip) {
                return .row(worklaneID)
            }
        }

        let lastRowBottomY: CGFloat
        if let lastFrame = worklaneFrames.last?.1 {
            lastRowBottomY = lastFrame.minY
        } else {
            lastRowBottomY = sidebarBottomY + 1000
        }

        let effectiveSidebarBottom = min(sidebarBottomY, lastRowBottomY - 40)
        if cursorInStrip.y < lastRowBottomY && cursorInStrip.y >= effectiveSidebarBottom {
            return .newWorklane
        }

        return .none
    }
}
