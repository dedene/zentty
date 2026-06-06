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

    /// How far above the first row the new-worklane top zone extends.
    /// Mirrors the 40pt extent of the below-last-row zone.
    private static let newWorklaneTopZoneExtent: CGFloat = 40

    static func target(
        cursorInStrip: CGPoint,
        worklaneFrames: [(WorklaneID, CGRect)],
        activeWorklaneID: WorklaneID?,
        sidebarBottomY: CGFloat,
        paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [],
        gapStealBand: CGFloat = 6,
        gapExitBand: CGFloat = 12,
        previousNewWorklaneIndex: Int? = nil
    ) -> SidebarPaneDropTarget {
        let sortedFrames = worklaneFrames.sorted { $0.1.minY > $1.1.minY }

        // 1. Gap zones above and between rows map to new-worklane insertion.
        //    The bare inter-row gap is too narrow to hit, so each zone steals
        //    a band from the adjacent row edges. The gap whose placeholder is
        //    already showing (previousNewWorklaneIndex) uses the wider exit
        //    band: hiding the placeholder keeps its layout slot briefly and
        //    then shifts rows under the cursor, so a symmetric band would
        //    flicker at the gap↔row boundary.
        if let firstFrame = sortedFrames.first?.1 {
            func band(forGapAt index: Int) -> CGFloat {
                previousNewWorklaneIndex == index ? gapExitBand : gapStealBand
            }

            // Top zone: above the first row.
            if cursorInStrip.y > firstFrame.maxY - band(forGapAt: 0),
               cursorInStrip.y <= firstFrame.maxY + newWorklaneTopZoneExtent {
                return .newWorklane(insertionIndex: 0)
            }

            // Inter-row gaps: between canonical rows i and i+1 → index i+1.
            for index in 0..<(sortedFrames.count - 1) {
                let rowAbove = sortedFrames[index].1
                let rowBelow = sortedFrames[index + 1].1
                let gapBand = band(forGapAt: index + 1)
                if cursorInStrip.y > rowBelow.maxY - gapBand,
                   cursorInStrip.y < rowAbove.minY + gapBand {
                    return .newWorklane(insertionIndex: index + 1)
                }
            }
        }

        // 2. If the cursor is inside a worklane row, only that row's pane
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

        // 3. New-worklane zone below the last row.
        let lastRowBottomY: CGFloat
        if let lastFrame = sortedFrames.last?.1 {
            lastRowBottomY = lastFrame.minY
        } else {
            lastRowBottomY = sidebarBottomY + 1000
        }

        let effectiveSidebarBottom = min(sidebarBottomY, lastRowBottomY - 40)
        if cursorInStrip.y < lastRowBottomY && cursorInStrip.y >= effectiveSidebarBottom {
            return .newWorklane(insertionIndex: sortedFrames.count)
        }

        return .none
    }
}
