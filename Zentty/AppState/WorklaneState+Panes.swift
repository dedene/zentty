import Foundation

/// Live-pane accessors that see both the strip and floats. Use these for any
/// "does this pane exist / which pane is focused" question; keep
/// `paneStripState` for strip-only geometry and navigation.
extension WorklaneState {
    /// Strip panes in strip order, then floats by `stackOrder` (back to front).
    var allPanes: [PaneState] {
        paneStripState.panes + floatsByStackOrder.map(\.pane)
    }

    func pane(id: PaneID) -> PaneState? {
        if let pane = paneStripState.panes.first(where: { $0.id == id }) {
            return pane
        }
        return floatingPane(id: id)?.pane
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

    private var floatsByStackOrder: [FloatingPaneState] {
        floatingPanes.enumerated()
            .sorted { lhs, rhs in
                lhs.element.stackOrder == rhs.element.stackOrder
                    ? lhs.offset < rhs.offset
                    : lhs.element.stackOrder < rhs.element.stackOrder
            }
            .map(\.element)
    }
}
