import Foundation

/// Panes a close prompt asks the terminal about: an overlay's command runs
/// as the session itself, so shell integration may never report it running
/// (`WorklaneState.closePromptAsksTerminal`). That holds for temporary
/// overlays and for overlays the user docked or re-floated since.
extension WorklaneStore {
    /// Every such pane that closing `paneID` ends: `paneID` itself (an
    /// overlay, or a docked overlay now in the strip), its pane overlays at
    /// any depth (an overlay can own overlays; reconciliation closes each
    /// once its owner is gone), and every overlay of its worklane when it is
    /// the worklane's last persistent pane. Worklane overlays otherwise
    /// re-anchor and survive.
    func terminalCheckedPaneIDs(closingWithPane paneID: PaneID) -> [PaneID] {
        guard let worklaneIndex = worklaneIndex(containingPane: paneID) else {
            return []
        }
        let worklane = worklanes[worklaneIndex]
        let ordered = FloatingPaneState.bySequence(worklane.floatingPanes).map(\.pane.id)
        var closing: Set<PaneID> = [paneID]
        if worklane.isLastPersistentPane(paneID) {
            closing.formUnion(ordered.filter { !worklane.isPersistent($0) })
        } else {
            var grew = true
            while grew {
                grew = false
                for id in ordered where !closing.contains(id) {
                    guard let anchor = worklane.overlayAnchor(of: id),
                          anchor.placement == .pane,
                          let owner = anchor.owner,
                          closing.contains(owner) else {
                        continue
                    }
                    closing.insert(id)
                    grew = true
                }
            }
        }
        let tiles = worklane.paneStripState.panes.map(\.id)
        return (tiles + ordered).filter { closing.contains($0) && worklane.closePromptAsksTerminal($0) }
    }

    /// Every such pane of `worklaneID`, tiles first, then floats in creation
    /// order.
    func terminalCheckedPaneIDs(closingWithWorklane worklaneID: WorklaneID) -> [PaneID] {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }
        let tiles = worklane.paneStripState.panes.map(\.id)
        let floats = FloatingPaneState.bySequence(worklane.floatingPanes).map(\.pane.id)
        return (tiles + floats).filter(worklane.closePromptAsksTerminal)
    }
}
