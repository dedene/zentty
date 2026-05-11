import CoreGraphics

/// Hit testing for pane transfer/duplicate drops onto the sidebar.
///
/// Whole-row hover still excludes the active worklane, but pane insertion
/// boundaries can target it to reorder panes through the sidebar.
enum SidebarPaneDropTarget: Equatable {
    /// Drop onto a worklane, appending as a new column at the end (current behavior).
    case existingWorklane(WorklaneID)
    /// Drop onto a worklane at a specific flat pane insertion boundary.
    /// `paneIndex` is 0...paneCount (0 = before first pane, count = after last pane).
    case existingWorklaneAtPaneIndex(WorklaneID, paneIndex: Int)
    /// Create a new worklane at a specific position in the sidebar list.
    /// `insertionIndex` is 0...worklaneCount.
    case newWorklane(insertionIndex: Int)
    case none
}

/// A single pane insertion boundary within a worklane row, positioned at the
/// midpoint of the gap between two pane rows (or at the top/bottom for the
/// first/last positions).
struct PaneInsertionBoundary: Equatable {
    let y: CGFloat
}

struct SidebarPaneInsertionLineTarget: Equatable {
    let worklaneID: WorklaneID
    let y: CGFloat
}

enum SidebarPaneDropHitTesting {

    /// Returns the Y coordinate of an insertion boundary, or `nil` if the target
    /// does not need a line. New-worklane targets return nil because the dashed
    /// placeholder is sufficient visual feedback.
    static func insertionLineY(
        for target: SidebarPaneDropTarget,
        paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])]
    ) -> CGFloat? {
        insertionLineTarget(for: target, paneBoundaries: paneBoundaries)?.y
    }

    /// Returns the insertion boundary target, or `nil` if the target does not
    /// need a line. The worklane ID lets the presenter constrain the line to
    /// the visual row instead of drawing across the whole sidebar document.
    static func insertionLineTarget(
        for target: SidebarPaneDropTarget,
        paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])]
    ) -> SidebarPaneInsertionLineTarget? {
        switch target {
        case .existingWorklane:
            return nil
        case .existingWorklaneAtPaneIndex(let worklaneID, let paneIndex):
            guard let boundaries = paneBoundaries.first(where: { $0.0 == worklaneID })?.1,
                  paneIndex < boundaries.count else { return nil }
            return SidebarPaneInsertionLineTarget(worklaneID: worklaneID, y: boundaries[paneIndex].y)
        case .newWorklane:
            return nil
        case .none:
            return nil
        }
    }

    static func target(
        cursorInStrip: CGPoint,
        worklaneFrames: [(WorklaneID, CGRect)],
        activeWorklaneID: WorklaneID?,
        sidebarBottomY: CGFloat,
        paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = []
    ) -> SidebarPaneDropTarget {
        // 1. If the cursor is inside a worklane row, only that row's pane
        //    boundaries participate. This prevents stale or nearby boundaries
        //    from adjacent rows from leaking into the hover target.
        if let (worklaneID, frame) = worklaneFrames.first(where: { entry in
            entry.1.contains(cursorInStrip)
        }) {
            if let boundaries = paneBoundaries.first(where: { $0.0 == worklaneID })?.1,
               boundaries.isEmpty == false {
                var bestPaneIndex = 0
                var bestDist = CGFloat.infinity
                for (index, boundary) in boundaries.enumerated()
                where frame.minY <= boundary.y && boundary.y <= frame.maxY {
                    let dist = abs(cursorInStrip.y - boundary.y)
                    if dist < bestDist {
                        bestDist = dist
                        bestPaneIndex = index
                    }
                }
                if bestDist.isFinite {
                    return .existingWorklaneAtPaneIndex(worklaneID, paneIndex: bestPaneIndex)
                }
            }

            guard worklaneID != activeWorklaneID else { return .none }
            return .existingWorklane(worklaneID)
        }

        // 2. Check the stable new-worklane zone below the list. We intentionally
        // avoid top and inter-row gaps: those are too small and visually noisy
        // during pane drags.
        let sorted = worklaneFrames.sorted { $0.1.minY > $1.1.minY }

        // New-worklane zone below last row
        let lastRowBottomY: CGFloat
        if let lastFrame = sorted.last?.1 {
            lastRowBottomY = lastFrame.minY
        } else {
            lastRowBottomY = sidebarBottomY + 1000
        }

        let effectiveSidebarBottom = min(sidebarBottomY, lastRowBottomY - 40)
        if cursorInStrip.y < lastRowBottomY && cursorInStrip.y >= effectiveSidebarBottom {
            return .newWorklane(insertionIndex: sorted.count)
        }

        return .none
    }
}
