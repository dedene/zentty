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
    /// Split vertically onto a target pane (above or below).
    case verticalSplit(targetPaneID: PaneID, above: Bool)
    /// Split horizontally onto a target pane (leading or trailing).
    case horizontalSplit(targetPaneID: PaneID, leading: Bool)
    /// Drop onto a sidebar worklane row.
    case sidebarWorklane(WorklaneID)
    /// Drop onto empty sidebar space to create a new worklane.
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
