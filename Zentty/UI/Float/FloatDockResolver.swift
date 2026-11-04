import CoreGraphics
import Foundation

/// The strip hits a float dock drag holds on to between cursor updates
/// (hysteresis), in float-layer coordinates.
struct FloatDockHits: Equatable, Sendable {
    var gap: ReorderGapHit?
    var stack: StackReorderGapHit?
    var split: SplitZoneHit?

    static let none = FloatDockHits()
}

/// What the dock preview draws for a target, in float-layer coordinates.
enum FloatDockPreviewGeometry: Equatable, Sendable {
    /// A vertical insertion line between (or beside) columns.
    case columnLine(CGRect)
    /// A horizontal insertion line inside a column stack.
    case stackLine(CGRect)
    /// The half of a pane the float would take.
    case splitHalf(CGRect)
    /// The whole canvas: the strip is empty, the float becomes its first column.
    case emptyStrip(CGRect)

    var frame: CGRect {
        switch self {
        case .columnLine(let frame), .stackLine(let frame), .splitHalf(let frame), .emptyStrip(let frame):
            frame
        }
    }
}

/// Pure dock targeting for a float dragged with ⌥. It runs the tile drag's
/// hit-test chain at zoom 1 against the full strip (a float has no slot to
/// remove, like the ⌥ duplicate path): column gap with hysteresis (dropped
/// when a prospective split owns that edge), then a stack gap, then a split
/// once the dwell has passed. The resolution never duplicates and never
/// targets the sidebar, and a pointer outside the canvas targets nothing.
enum FloatDockResolver {
    static let splitDwellDuration: TimeInterval = 0.25
    /// Insertion line thickness (the tile drag's 6pt at zoom 1).
    static let lineThickness: CGFloat = 6
    /// Inset of the empty-strip preview from the canvas edges.
    static let emptyStripInset: CGFloat = 8

    struct Input: Equatable {
        var cursor: CGPoint
        /// The eligible canvas (the float layer's bounds). A drag keeps
        /// reporting the pointer past it; there it docks nowhere.
        var canvas: CGRect
        var columns: [ColumnPresentation]
        var draggedPaneID: PaneID
        var previous: FloatDockHits
        var splitDwellSatisfied: Bool
        var minimumPaneHeight: CGFloat

        init(
            cursor: CGPoint,
            canvas: CGRect,
            columns: [ColumnPresentation],
            draggedPaneID: PaneID,
            previous: FloatDockHits = .none,
            splitDwellSatisfied: Bool = false,
            minimumPaneHeight: CGFloat = PaneStripState.minimumVerticalPaneHeight
        ) {
            self.cursor = cursor
            self.canvas = canvas
            self.columns = columns
            self.draggedPaneID = draggedPaneID
            self.previous = previous
            self.splitDwellSatisfied = splitDwellSatisfied
            self.minimumPaneHeight = minimumPaneHeight
        }
    }

    struct Result: Equatable {
        var hits: FloatDockHits
        var target: FloatDockTarget?
        /// A split zone under the cursor that still waits for the dwell.
        var pendingSplit: SplitZoneHit?
        /// What `PaneDropResolver` decided (nil for the empty strip).
        var resolution: PaneDropResolution?
    }

    static func resolve(_ input: Input) -> Result {
        guard input.canvas.contains(input.cursor) else {
            return Result(hits: .none, target: nil, pendingSplit: nil, resolution: nil)
        }
        guard !input.columns.isEmpty else {
            return Result(hits: .none, target: .columnGap(index: 0), pendingSplit: nil, resolution: nil)
        }

        let splitCandidate = splitZoneHit(input)
        var gap = PaneDragHitTest.reorderGapHit(
            cursorX: input.cursor.x,
            visibleColumnFrames: input.columns.map(\.frame),
            zoomScale: 1,
            previousReducedIndex: input.previous.gap?.reducedIndex
        )
        if let activeGap = gap, let splitCandidate,
           PaneDragHitTest.shouldSuppressColumnReorderGap(
               gapReducedIndex: activeGap.reducedIndex,
               splitHit: splitCandidate,
               columnIDsInOrder: input.columns.map(\.columnID)
           ) {
            gap = nil
        }

        var hits = FloatDockHits.none
        var pendingSplit: SplitZoneHit?
        if let gap {
            hits.gap = gap
        } else if let stack = PaneDragHitTest.stackReorderGapHit(
            cursorInContent: input.cursor,
            visibleColumns: input.columns,
            zoomScale: 1,
            previousHit: input.previous.stack
        ) {
            hits.stack = stack
        } else if let splitCandidate {
            if input.splitDwellSatisfied {
                hits.split = splitCandidate
            } else {
                pendingSplit = splitCandidate
            }
        }

        let resolution = PaneDropResolver.resolve(PaneDropResolver.Input(
            draggedPaneID: input.draggedPaneID,
            dropTarget: .none,
            stackGapHit: hits.stack,
            splitHit: hits.split,
            // A float has no strip slot: the gap index is already a full-strip
            // column index (the ⌥ path of the tile drag).
            insertionColumnIndex: hits.gap?.reducedIndex,
            isDuplicate: false
        ))
        let target: FloatDockTarget?
        switch resolution {
        case .commit(let outcome):
            target = Self.target(for: outcome)
        case .cancel:
            target = nil
        }
        return Result(hits: hits, target: target, pendingSplit: pendingSplit, resolution: resolution)
    }

    /// The dock target for a drop outcome. Sidebar outcomes have none (docking
    /// stays in the current worklane in v1).
    static func target(for outcome: PaneDragOutcome) -> FloatDockTarget? {
        switch outcome {
        case .reorder(_, let columnIndex, _):
            .columnGap(index: columnIndex)
        case .reorderInColumn(_, let columnID, let paneIndex, _):
            .stackGap(columnID: columnID, paneIndex: paneIndex)
        case .splitDrop(_, let targetPaneID, let axis, let leading, _):
            .split(target: targetPaneID, axis: axis, leading: leading)
        case .crossWorklane, .newWorklane:
            nil
        }
    }

    /// Where the preview for `target` sits, or nil when the target refers to
    /// a column or pane that is not in `columns`.
    static func previewGeometry(
        for target: FloatDockTarget,
        columns: [ColumnPresentation],
        canvas: CGRect
    ) -> FloatDockPreviewGeometry? {
        switch target {
        case .columnGap(let index):
            guard !columns.isEmpty else {
                return .emptyStrip(canvas.insetBy(dx: emptyStripInset, dy: emptyStripInset))
            }
            guard (0...columns.count).contains(index) else { return nil }
            let reference = columns[min(index, columns.count - 1)].frame
            let centerX: CGFloat
            if index == 0 {
                centerX = columns[0].frame.minX
            } else if index == columns.count {
                centerX = columns[columns.count - 1].frame.maxX
            } else {
                centerX = (columns[index - 1].frame.maxX + columns[index].frame.minX) / 2
            }
            var minX = centerX - lineThickness / 2
            if canvas.width >= lineThickness {
                minX = min(max(minX, canvas.minX), canvas.maxX - lineThickness)
            }
            return .columnLine(CGRect(x: minX, y: reference.minY, width: lineThickness, height: reference.height))

        case .stackGap(let columnID, let paneIndex):
            guard let column = columns.first(where: { $0.columnID == columnID }),
                  !column.panes.isEmpty,
                  (0...column.panes.count).contains(paneIndex) else {
                return nil
            }
            let centerY: CGFloat
            switch paneIndex {
            case 0:
                centerY = (column.frame.maxY + column.panes[0].frame.maxY) / 2
            case column.panes.count:
                centerY = (column.frame.minY + column.panes[column.panes.count - 1].frame.minY) / 2
            default:
                centerY = (column.panes[paneIndex - 1].frame.minY + column.panes[paneIndex].frame.maxY) / 2
            }
            return .stackLine(CGRect(
                x: column.frame.minX,
                y: centerY - lineThickness / 2,
                width: column.frame.width,
                height: lineThickness
            ))

        case .split(let paneID, let axis, let leading):
            guard let frame = columns.lazy.flatMap(\.panes).first(where: { $0.paneID == paneID })?.frame else {
                return nil
            }
            // y-up: "leading" on the vertical axis is the upper half.
            switch axis {
            case .vertical:
                let half = frame.height / 2
                return .splitHalf(CGRect(
                    x: frame.minX,
                    y: leading ? frame.midY : frame.minY,
                    width: frame.width,
                    height: half
                ))
            case .horizontal:
                let half = frame.width / 2
                return .splitHalf(CGRect(
                    x: leading ? frame.minX : frame.midX,
                    y: frame.minY,
                    width: half,
                    height: frame.height
                ))
            }

        case .origin:
            return nil
        }
    }

    private static func splitZoneHit(_ input: Input) -> SplitZoneHit? {
        var paneFramesByID: [PaneID: CGRect] = [:]
        var columnForPane: [PaneID: PaneColumnID] = [:]
        var paneCountByColumn: [PaneColumnID: Int] = [:]
        for column in input.columns {
            paneCountByColumn[column.columnID] = column.panes.count
            for pane in column.panes {
                paneFramesByID[pane.paneID] = pane.frame
                columnForPane[pane.paneID] = column.columnID
            }
        }
        return PaneDragHitTest.splitZoneHit(
            cursorInContent: input.cursor,
            paneFramesByID: paneFramesByID,
            columnForPane: columnForPane,
            paneCountByColumn: paneCountByColumn,
            excludedPaneID: input.draggedPaneID,
            minimumPaneHeight: input.minimumPaneHeight
        )
    }
}
