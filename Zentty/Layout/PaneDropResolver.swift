// MARK: - Pane Drop Resolution

/// The decision produced by resolving a pane drop: either commit a concrete
/// outcome, or cancel the drag and spring the pane back.
enum PaneDropResolution: Equatable {
    case commit(PaneDragOutcome)
    case cancel
}

/// Pure decision function for a pane drop.
///
/// `PaneDropResolver` replicates the exact precedence `PaneDragCoordinator.endDrag`
/// applies over the two parallel state representations that survive a drag:
///
/// 1. `dropTarget` — `activeState.currentDropTarget`, which carries the sidebar
///    targets (worklane row, worklane pane boundary, new-worklane slots).
/// 2. The canvas hit fields — `stackGapHit` / `splitHit` / `insertionColumnIndex` —
///    which the coordinator tracks separately for in-canvas drops.
///
/// The two representations are intentionally *not* unified: sidebar targets win
/// outright, and only when no sidebar target is present do the canvas fields
/// decide, in the order stack-gap → split → column-insertion → cancel.
enum PaneDropResolver {
    struct Input {
        let draggedPaneID: PaneID
        let dropTarget: PaneDropTarget
        let stackGapHit: StackReorderGapHit?
        let splitHit: SplitZoneHit?
        let insertionColumnIndex: Int?
        /// Whether Option was held at release (== `isOptionHeld`).
        let isDuplicate: Bool
    }

    static func resolve(_ input: Input) -> PaneDropResolution {
        let paneID = input.draggedPaneID
        let isDuplicate = input.isDuplicate

        // Sidebar drops take priority over any canvas hit.
        switch input.dropTarget {
        case .sidebarWorklane(let worklaneID):
            return .commit(.crossWorklane(
                paneID: paneID, worklaneID: worklaneID, paneIndex: nil, isDuplicate: isDuplicate
            ))
        case .sidebarWorklanePane(let worklaneID, let paneIndex):
            return .commit(.crossWorklane(
                paneID: paneID, worklaneID: worklaneID, paneIndex: paneIndex, isDuplicate: isDuplicate
            ))
        case .newWorklane:
            return .commit(.newWorklane(
                paneID: paneID, insertionIndex: nil, isDuplicate: isDuplicate
            ))
        case .newWorklaneAtIndex(let index):
            return .commit(.newWorklane(
                paneID: paneID, insertionIndex: index, isDuplicate: isDuplicate
            ))
        case .reorderGap, .reorderInColumn, .verticalSplit, .horizontalSplit, .none:
            break  // No sidebar target — fall through to canvas hits.
        }

        if let stackGapHit = input.stackGapHit {
            return .commit(.reorderInColumn(
                paneID: paneID,
                columnID: stackGapHit.columnID,
                paneIndex: stackGapHit.paneIndex,
                isDuplicate: isDuplicate
            ))
        }
        if let splitHit = input.splitHit {
            return .commit(.splitDrop(
                paneID: paneID,
                targetPaneID: splitHit.targetPaneID,
                axis: splitHit.axis,
                leading: splitHit.leading,
                isDuplicate: isDuplicate
            ))
        }
        if let columnIndex = input.insertionColumnIndex {
            return .commit(.reorder(
                paneID: paneID, columnIndex: columnIndex, isDuplicate: isDuplicate
            ))
        }
        return .cancel
    }
}
