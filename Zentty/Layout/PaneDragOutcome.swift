// MARK: - Pane Drag Outcome

/// The resolved command produced by releasing a pane drag.
///
/// A `PaneDragOutcome` is a pure value describing *what* layout mutation a drop
/// should perform. It carries no view or animation state — the drag coordinator
/// owns the settle animation, and the host (`RootViewController`) maps the
/// outcome onto the matching `WorklaneStore` mutation.
///
/// `isDuplicate` mirrors whether Option was held at release: `true` selects the
/// duplicate variant of each mutation, `false` the move variant.
enum PaneDragOutcome: Equatable, Sendable {
    /// Reorder the pane to a new column at `columnIndex`.
    case reorder(paneID: PaneID, columnIndex: Int, isDuplicate: Bool)
    /// Reorder the pane within a column at `paneIndex`.
    case reorderInColumn(paneID: PaneID, columnID: PaneColumnID, paneIndex: Int, isDuplicate: Bool)
    /// Split-drop the pane onto `targetPaneID` along `axis` (leading/trailing or above/below).
    case splitDrop(paneID: PaneID, targetPaneID: PaneID, axis: PaneSplitPreview.Axis, leading: Bool, isDuplicate: Bool)
    /// Move/duplicate the pane into an existing worklane. `paneIndex == nil` appends to the
    /// worklane (whole-row drop); a value inserts at that flat pane boundary.
    case crossWorklane(paneID: PaneID, worklaneID: WorklaneID, paneIndex: Int?, isDuplicate: Bool)
    /// Move/duplicate the pane into a brand-new worklane. `insertionIndex == nil` appends the
    /// new worklane at the end of the list; a value inserts at that sidebar position.
    case newWorklane(paneID: PaneID, insertionIndex: Int?, isDuplicate: Bool)
}
