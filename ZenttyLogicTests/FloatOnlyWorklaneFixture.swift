import CoreGraphics
@testable import Zentty

@MainActor
extension WorklaneStore {
    /// Test fixture for float-only worklanes. The sole tile can't float any
    /// more (`WorklaneState.isSoleTile`); the app still reaches this state
    /// when the last tile closes while floats are open, or with `float new`
    /// in an empty worklane. Does what `floatPane` does, minus that guard:
    /// centred at the default size, focused, notified like a float op.
    func floatSoleTileForTesting(_ id: PaneID, canvas: CGRect) {
        guard let worklaneIndex = worklaneIndex(containingPane: id) else { return }
        let original = worklanes[worklaneIndex]
        var worklane = original
        guard let removal = worklane.paneStripState.removePane(
            id: id,
            singleColumnWidth: layoutContext.singlePaneWidth
        ) else { return }
        let frame = FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
        worklane.floatingPanes.append(
            FloatingPaneState(
                pane: removal.pane,
                mode: .floating,
                floatFrame: NormalizedRect(rect: frame, in: canvas),
                stackOrder: Self.nextStackOrder(in: worklane),
                origin: FloatOrigin(columnIndex: removal.columnIndex),
                sequence: Self.nextFloatSequence(in: worklane)
            )
        )
        worklane.floatsHidden = false
        worklane.focusedFloatID = id
        commitFloat(worklane, from: original, at: worklaneIndex)
    }
}
