import Foundation

/// Live-pane accessors that see both the strip and floats. Use these for any
/// "does this pane exist / which pane is focused" question; keep
/// `paneStripState` for strip-only geometry and navigation.
extension WorklaneState {
    /// Strip panes in strip order, then floats in creation order
    /// (`sequence`). Stable across raises, so it is safe for numbering.
    var allPanes: [PaneState] {
        paneStripState.panes + FloatingPaneState.bySequence(floatingPanes).map(\.pane)
    }

    func pane(id: PaneID) -> PaneState? {
        if let pane = paneStripState.panes.first(where: { $0.id == id }) {
            return pane
        }
        return floatingPane(id: id)?.pane
    }

    /// Non-allocating membership check over strip columns and floats. Prefer
    /// this over `allPanes.contains` / `pane(id:) != nil` on hot paths
    /// (metadata, terminal events, agent status routing).
    func containsPane(id: PaneID) -> Bool {
        for column in paneStripState.columns where column.panes.contains(where: { $0.id == id }) {
            return true
        }
        return floatingPanes.contains { $0.pane.id == id }
    }

    func floatingPane(id: PaneID) -> FloatingPaneState? {
        floatingPanes.first { $0.pane.id == id }
    }

    /// True for every float mode (floating, PiP, minimized).
    func isFloating(_ id: PaneID) -> Bool {
        floatingPanes.contains { $0.pane.id == id }
    }

    /// Mutates the pane wherever it lives. Returns false when no pane matches.
    @discardableResult
    mutating func updatePane(id: PaneID, _ body: (inout PaneState) -> Void) -> Bool {
        if let floatIndex = floatingPanes.firstIndex(where: { $0.pane.id == id }) {
            body(&floatingPanes[floatIndex].pane)
            return true
        }
        for columnIndex in paneStripState.columns.indices {
            if let paneIndex = paneStripState.columns[columnIndex].panes.firstIndex(where: { $0.id == id }) {
                body(&paneStripState.columns[columnIndex].panes[paneIndex])
                return true
            }
        }
        return false
    }

    /// The pane that should own keyboard focus: the focused float while it is
    /// `.floating` and floats are shown, otherwise the strip's focused pane.
    var focusedPaneID: PaneID? {
        if !floatsHidden,
           let focusedFloatID,
           let float = floatingPane(id: focusedFloatID),
           float.mode.isFloating {
            return focusedFloatID
        }
        return paneStripState.focusedPaneID
    }

    /// Float-aware counterpart of `paneStripState.focusedPane`.
    var focusedPane: PaneState? {
        focusedPaneID.flatMap { pane(id: $0) }
    }

    /// True when a `.floating` float, not the strip, owns keyboard focus.
    /// Strip-relative commands (focus moves, reorder, resize) check this.
    var floatOwnsFocus: Bool {
        guard let focusedFloatID else {
            return false
        }
        return focusedPaneID == focusedFloatID
    }

    /// Panes session restore saves: every live pane except temporary
    /// (overlay-style) floats, which end with their command.
    var persistentPanes: [PaneState] {
        allPanes.filter { isPersistent($0.id) }
    }

    func isPersistent(_ id: PaneID) -> Bool {
        if case .temporary = auxiliaryStateByPaneID[id]?.lifetime {
            return false
        }
        return true
    }

    var hasLivePanes: Bool {
        hasTiledPanes || !floatingPanes.isEmpty
    }

    var hasTiledPanes: Bool {
        !paneStripState.panes.isEmpty
    }

    /// Floats drawn over the canvas (`.floating` + `.pip`); 0 while hidden.
    var visibleFloatCount: Int {
        guard !floatsHidden else { return 0 }
        return floatingPanes.filter { float in
            switch float.mode {
            case .floating, .pip:
                true
            case .minimized:
                false
            }
        }.count
    }

    /// Floats back to front (`stackOrder`). For z-order only; number and
    /// list panes with `allPanes`.
    var floatsByStackOrder: [FloatingPaneState] {
        FloatingPaneState.byStackOrder(floatingPanes)
    }
}
