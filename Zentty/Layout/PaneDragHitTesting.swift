import CoreGraphics

struct ReorderGapHit: Equatable {
    let reducedIndex: Int
}

struct SplitZoneHit: Equatable {
    let targetPaneID: PaneID
    let targetColumnID: PaneColumnID
    let axis: PaneSplitPreview.Axis
    /// true = above (vertical) or leading/left (horizontal)
    let leading: Bool
}

struct StackReorderGapHit: Equatable {
    let columnID: PaneColumnID
    let paneIndex: Int
}

enum SidebarHitResult: Equatable {
    case worklane(WorklaneID)
    case newWorklane
    case none
}

enum PaneDragHitTest {

    /// Resolve a reorder gap hit using gap zones around column boundaries.
    /// Returns `nil` when the cursor is in a column interior (no gap change).
    /// Uses hysteresis: once a gap is active, a wider retention band keeps it
    /// active to prevent flickering.
    static func reorderGapHit(
        cursorX: CGFloat,
        visibleColumnFrames: [CGRect],
        zoomScale: CGFloat,
        previousReducedIndex: Int?
    ) -> ReorderGapHit? {
        guard !visibleColumnFrames.isEmpty else { return nil }

        // Screen-space sizes, converted to content space via zoomScale
        let activation: CGFloat = 16 / max(zoomScale, 0.01)
        let retention: CGFloat = 24 / max(zoomScale, 0.01)

        let candidates = gapCandidates(
            from: visibleColumnFrames,
            activation: activation,
            retention: retention
        )

        // Hysteresis: keep the current gap if cursor is still in its retention band
        if let prev = previousReducedIndex,
           candidates.indices.contains(prev),
           candidates[prev].retentionBand.contains(cursorX) {
            return ReorderGapHit(reducedIndex: prev)
        }

        // Check activation bands
        let hits = candidates.filter { $0.activationBand.contains(cursorX) }
        guard let best = hits.min(by: { abs($0.centerX - cursorX) < abs($1.centerX - cursorX) }) else {
            return nil
        }

        return ReorderGapHit(reducedIndex: best.index)
    }

    // MARK: - Helpers

    private struct GapCandidate {
        let index: Int
        let centerX: CGFloat
        let activationBand: ClosedRange<CGFloat>
        let retentionBand: ClosedRange<CGFloat>
    }

    private static func gapCandidates(
        from frames: [CGRect],
        activation: CGFloat,
        retention: CGFloat
    ) -> [GapCandidate] {
        var result: [GapCandidate] = []

        // Gap 0: before first column
        let first = frames[0]
        result.append(GapCandidate(
            index: 0,
            centerX: first.minX,
            activationBand: (-.greatestFiniteMagnitude)...(first.minX + activation),
            retentionBand: (-.greatestFiniteMagnitude)...(first.minX + retention)
        ))

        // Gaps between columns
        for i in 1..<frames.count {
            let left = frames[i - 1]
            let right = frames[i]
            let center = (left.maxX + right.minX) / 2

            result.append(GapCandidate(
                index: i,
                centerX: center,
                activationBand: (left.maxX - activation)...(right.minX + activation),
                retentionBand: (left.maxX - retention)...(right.minX + retention)
            ))
        }

        // Gap N: after last column
        let last = frames[frames.count - 1]
        result.append(GapCandidate(
            index: frames.count,
            centerX: last.maxX,
            activationBand: (last.maxX - activation)...(.greatestFiniteMagnitude),
            retentionBand: (last.maxX - retention)...(.greatestFiniteMagnitude)
        ))

        return result
    }

    // MARK: - Split Zone Detection

    static func stackReorderGapHit(
        cursorInContent: CGPoint,
        visibleColumns: [ColumnPresentation],
        zoomScale: CGFloat,
        previousHit: StackReorderGapHit?
    ) -> StackReorderGapHit? {
        guard !visibleColumns.isEmpty else { return nil }

        let activation: CGFloat = 16 / max(zoomScale, 0.01)
        let retention: CGFloat = 24 / max(zoomScale, 0.01)

        let candidates = stackGapCandidates(
            from: visibleColumns,
            activation: activation,
            retention: retention
        )

        if let previousHit,
           let candidate = candidates.first(where: {
               $0.hit == previousHit
               && $0.horizontalBand.contains(cursorInContent.x)
               && $0.retentionBand.contains(cursorInContent.y)
           }) {
            return candidate.hit
        }

        let hits = candidates.filter {
            $0.horizontalBand.contains(cursorInContent.x)
            && $0.activationBand.contains(cursorInContent.y)
        }
        guard let best = hits.min(by: {
            abs($0.centerY - cursorInContent.y) < abs($1.centerY - cursorInContent.y)
        }) else {
            return nil
        }

        return best.hit
    }

    private struct StackGapCandidate {
        let hit: StackReorderGapHit
        let centerY: CGFloat
        let horizontalBand: ClosedRange<CGFloat>
        let activationBand: ClosedRange<CGFloat>
        let retentionBand: ClosedRange<CGFloat>
    }

    private static func stackGapCandidates(
        from columns: [ColumnPresentation],
        activation: CGFloat,
        retention: CGFloat
    ) -> [StackGapCandidate] {
        var result: [StackGapCandidate] = []

        for column in columns where !column.panes.isEmpty {
            let horizontalBand = (column.frame.minX - activation)...(column.frame.maxX + activation)
            let paneFrames = column.panes.map(\.frame)
            let firstFrame = paneFrames[0]
            let topGapCenterY = (column.frame.maxY + firstFrame.maxY) / 2
            result.append(
                StackGapCandidate(
                    hit: StackReorderGapHit(columnID: column.columnID, paneIndex: 0),
                    centerY: topGapCenterY,
                    horizontalBand: horizontalBand,
                    activationBand: (topGapCenterY - activation)...(topGapCenterY + activation),
                    retentionBand: (topGapCenterY - retention)...(topGapCenterY + retention)
                )
            )

            for index in 1..<paneFrames.count {
                let upperFrame = paneFrames[index - 1]
                let lowerFrame = paneFrames[index]
                let centerY = (upperFrame.minY + lowerFrame.maxY) / 2
                result.append(
                    StackGapCandidate(
                        hit: StackReorderGapHit(columnID: column.columnID, paneIndex: index),
                        centerY: centerY,
                        horizontalBand: horizontalBand,
                        activationBand: (centerY - activation)...(centerY + activation),
                        retentionBand: (centerY - retention)...(centerY + retention)
                    )
                )
            }

            let lastFrame = paneFrames[paneFrames.count - 1]
            let bottomGapCenterY = (column.frame.minY + lastFrame.minY) / 2
            result.append(
                StackGapCandidate(
                    hit: StackReorderGapHit(columnID: column.columnID, paneIndex: paneFrames.count),
                    centerY: bottomGapCenterY,
                    horizontalBand: horizontalBand,
                    activationBand: (bottomGapCenterY - activation)...(bottomGapCenterY + activation),
                    retentionBand: (bottomGapCenterY - retention)...(bottomGapCenterY + retention)
                )
            )
        }

        return result
    }

    /// Detect whether the cursor is in a split activation zone on any eligible pane.
    /// Returns nil when cursor is in a pane's center dead zone, outside all panes,
    /// or over a source-column pane.
    static func splitZoneHit(
        cursorInContent: CGPoint,
        paneFramesByID: [PaneID: CGRect],
        columnForPane: [PaneID: PaneColumnID],
        paneCountByColumn: [PaneColumnID: Int],
        sourceColumnID: PaneColumnID,
        minimumPaneHeight: CGFloat
    ) -> SplitZoneHit? {
        // Find the pane whose frame contains the cursor, excluding source column panes
        var hitPaneID: PaneID?
        var hitFrame: CGRect = .zero

        for (paneID, frame) in paneFramesByID {
            guard columnForPane[paneID] != sourceColumnID else { continue }
            guard frame.contains(cursorInContent) else { continue }
            hitPaneID = paneID
            hitFrame = frame
            break
        }

        guard let targetPaneID = hitPaneID,
              let targetColumnID = columnForPane[targetPaneID],
              hitFrame.width > 0, hitFrame.height > 0 else {
            return nil
        }

        // Normalize cursor position within pane (0..1)
        let nx = (cursorInContent.x - hitFrame.minX) / hitFrame.width
        let ny = (cursorInContent.y - hitFrame.minY) / hitFrame.height

        // Edge zone threshold — outer 28% on each side
        let edgeThreshold: CGFloat = 0.28
        let minEdgeDist = min(nx, 1 - nx, ny, 1 - ny)
        guard minEdgeDist <= edgeThreshold else {
            return nil  // Center dead zone
        }

        // Nearest edge determines axis
        let dLeft = nx
        let dRight = 1 - nx
        let dBottom = ny           // bottom-left coords: low Y = bottom
        let dTop = 1 - ny         // high Y = top

        let candidates: [(distance: CGFloat, axis: PaneSplitPreview.Axis, leading: Bool)] = [
            (dLeft, .horizontal, true),
            (dRight, .horizontal, false),
            (dBottom, .vertical, false),
            (dTop, .vertical, true),
        ].sorted { $0.distance < $1.distance }

        for candidate in candidates where candidate.distance <= edgeThreshold {
            switch candidate.axis {
            case .horizontal:
                guard paneCountByColumn[targetColumnID] == 1 else { continue }
            case .vertical:
                guard hitFrame.height / 2 >= minimumPaneHeight else { continue }
            }

            return SplitZoneHit(
                targetPaneID: targetPaneID,
                targetColumnID: targetColumnID,
                axis: candidate.axis,
                leading: candidate.leading
            )
        }

        return nil
    }

    // MARK: - Sidebar Row Detection

    /// Detect which sidebar worklane row the cursor is over.
    /// Excludes the active worklane from targeting.
    /// Returns `.newWorklane` when cursor is below the last row.
    static func sidebarRowHit(
        cursorInStrip: CGPoint,
        worklaneFrames: [(WorklaneID, CGRect)],
        activeWorklaneID: WorklaneID?,
        sidebarBottomY: CGFloat
    ) -> SidebarHitResult {
        // Check each worklane row (excluding active worklane)
        for (worklaneID, frame) in worklaneFrames {
            guard worklaneID != activeWorklaneID else { continue }
            if frame.contains(cursorInStrip) {
                return .worklane(worklaneID)
            }
        }

        // Check if cursor is below last row → new worklane zone.
        // In non-flipped coords (bottom-left origin): lower Y = lower on screen.
        // Sidebar rows are laid out top-to-bottom, so the last row has the lowest Y.
        // "Below last row" means Y values less than the last row's bottom edge.
        let lastRowBottomY: CGFloat
        if let lastFrame = worklaneFrames.last?.1 {
            lastRowBottomY = lastFrame.minY
        } else {
            // No rows at all — entire sidebar is the new-worklane zone
            lastRowBottomY = sidebarBottomY + 1000
        }

        // Ensure a minimum drop zone height (40pt) even if sidebar bottom is flush
        let effectiveSidebarBottom = min(sidebarBottomY, lastRowBottomY - 40)

        if cursorInStrip.y < lastRowBottomY && cursorInStrip.y >= effectiveSidebarBottom {
            return .newWorklane
        }

        return .none
    }

    /// Compute edge scroll velocity based on cursor proximity to the VISIBLE viewport edges.
    /// `visibleMinX` accounts for the sidebar overlay (the visible left edge).
    /// Edge scroll velocity with quadratic ease-in ramp.
    /// Gentle start near the zone boundary, accelerates as cursor approaches the edge.
    static func edgeScrollVelocity(
        cursorX: CGFloat,
        viewportWidth: CGFloat,
        visibleMinX: CGFloat = 0,
        edgeZone: CGFloat = 60,
        maxSpeed: CGFloat = 800
    ) -> CGFloat {
        // Left edge: zone starts at the visible left boundary (after sidebar)
        let leftEdge = visibleMinX
        if cursorX < leftEdge + edgeZone {
            let linear = 1 - max(0, (cursorX - leftEdge) / edgeZone)
            let proximity = min(1, linear)
            let eased = proximity * proximity  // quadratic ease-in
            return -maxSpeed * eased
        }

        // Right edge
        let rightEdgeStart = viewportWidth - edgeZone
        if cursorX > rightEdgeStart {
            let linear = (cursorX - rightEdgeStart) / edgeZone
            let proximity = min(1, linear)
            let eased = proximity * proximity  // quadratic ease-in
            return maxSpeed * eased
        }

        return 0
    }
}
