import CoreGraphics

// MARK: - Drag Phase State Machine

enum PaneDragPhase: Equatable, Sendable {
    case idle
    case pending(PaneDragPendingState)
    case active(PaneDragActiveState)
}

struct PaneDragPendingState: Equatable, Sendable {
    let origin: CGPoint
    let paneID: PaneID
    let timestamp: CFTimeInterval
}

// MARK: - Active Drag State

struct PaneDragActiveState: Equatable, Sendable {
    let draggedPaneID: PaneID
    let sourceColumnID: PaneColumnID
    let sourceColumnIndex: Int
    let sourcePaneIndex: Int
    let sourceFlatPaneIndex: Int
    let originalPaneState: PaneState
    let originalColumnWidth: CGFloat
    /// Offset from cursor to the pane snapshot's origin, captured at drag start.
    /// The floating pane is positioned at `cursor + grabOffset`.
    let grabOffset: CGSize
    var cursorPosition: CGPoint
    var currentDropTarget: PaneDropTarget
    var splitPreview: PaneSplitPreview?
}

// MARK: - Drop Targets

enum PaneDropTarget: Equatable, Sendable {
    /// Insert as a new column at the given index.
    case reorderGap(columnIndex: Int)
    /// Insert within an existing column at the given pane index.
    case reorderInColumn(columnID: PaneColumnID, paneIndex: Int)
    /// Split vertically onto a target pane (above or below).
    case verticalSplit(targetPaneID: PaneID, above: Bool)
    /// Split horizontally onto a target pane (leading or trailing).
    case horizontalSplit(targetPaneID: PaneID, leading: Bool)
    /// Drop onto a sidebar worklane row (whole-row append, current behavior).
    case sidebarWorklane(WorklaneID)
    /// Drop onto a sidebar worklane at a specific pane insertion boundary.
    case sidebarWorklanePane(WorklaneID, paneIndex: Int)
    /// Create a new worklane at a specific position in the sidebar list.
    case newWorklaneAtIndex(Int)
    /// Drop onto empty sidebar space to create a new worklane (deprecated alias for newWorklaneAtIndex(count)).
    case newWorklane
    /// No valid drop target.
    case none
}

// MARK: - Split Preview

struct PaneSplitPreview: Equatable, Sendable {
    let targetPaneID: PaneID
    let targetColumnID: PaneColumnID
    let axis: Axis
    /// Cursor position along the split axis (0..1).
    let fraction: CGFloat

    enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }
}

// MARK: - No-op Drop Detection

extension PaneDragActiveState {
    /// True when releasing the drag at `target` would not change layout.
    /// Used to suppress haptic feedback when the cursor returns to the dragged pane's own slot.
    ///
    /// - Parameters:
    ///   - isDuplicate: True when the user is holding Option (duplicate-drag). Duplicate drops
    ///     always create a new pane, so they are never no-ops.
    ///   - currentSidebarWorklaneID: The worklane currently displayed in the canvas. The dragged
    ///     pane already lives in that worklane, so a move-drop onto its sidebar row is a no-op.
    ///
    /// `paneIndex` is interpreted in reduced-space (source pane removed): `PaneStripState.movePane`
    /// returns early when `insertionIndex == sourcePaneIndex`, which is the only same-column no-op.
    func isNoOpDrop(
        _ target: PaneDropTarget,
        isDuplicate: Bool = false,
        currentSidebarWorklaneID: WorklaneID? = nil
    ) -> Bool {
        if isDuplicate { return false }
        switch target {
        case .reorderInColumn(let columnID, let paneIndex):
            return columnID == sourceColumnID && paneIndex == sourcePaneIndex
        case .sidebarWorklane(let worklaneID):
            return worklaneID == currentSidebarWorklaneID
        case .sidebarWorklanePane(let worklaneID, let paneIndex):
            guard worklaneID == currentSidebarWorklaneID else { return false }
            return paneIndex == sourceFlatPaneIndex || paneIndex == sourceFlatPaneIndex + 1
        case .reorderGap, .verticalSplit, .horizontalSplit, .newWorklane, .newWorklaneAtIndex, .none:
            return false
        }
    }
}

// MARK: - Haptic Event Classification

/// Which haptic (if any) should fire for a drop-target transition during a pane drag.
enum DragReorderHapticEvent: Equatable, Sendable {
    /// No haptic — silent transition (no change, no-op slot, or `.none` target).
    case silent
    /// Positional reorder — `.alignment`.
    case alignment
    /// Structural change (split, new-worklane creation) — `.levelChange`.
    case structural
}

enum DragReorderHapticClassifier {
    /// Pure mapping from a drop-target transition to the haptic that should fire.
    /// - Parameters:
    ///   - previous: The drop target before the cursor moved.
    ///   - next: The drop target the cursor just resolved to.
    ///   - activeState: The drag's active state — supplies the source position for no-op detection.
    ///   - isDuplicate: True when Option is held; duplicate drags never produce no-ops.
    ///   - currentSidebarWorklaneID: The worklane currently displayed (so sidebar drops onto it are no-ops).
    static func event(
        from previous: PaneDropTarget,
        to next: PaneDropTarget,
        activeState: PaneDragActiveState,
        isDuplicate: Bool = false,
        currentSidebarWorklaneID: WorklaneID? = nil
    ) -> DragReorderHapticEvent {
        guard previous != next else { return .silent }
        guard !activeState.isNoOpDrop(
            next,
            isDuplicate: isDuplicate,
            currentSidebarWorklaneID: currentSidebarWorklaneID
        ) else {
            return .silent
        }
        switch next {
        case .none:
            return .silent
        case .reorderGap, .reorderInColumn, .sidebarWorklane, .sidebarWorklanePane:
            return .alignment
        case .verticalSplit, .horizontalSplit, .newWorklane, .newWorklaneAtIndex:
            return .structural
        }
    }
}
