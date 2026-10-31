import CoreGraphics
import Foundation

/// Float pieces of the pane lifecycle that live outside the float operations
/// proper: closing a float, focus repair after the strip empties, and
/// duplicating a focused float.
extension WorklaneStore {

    /// The canvas the store assumes for float geometry it derives itself
    /// (e.g. the duplicate offset). Width is the strip viewport; height is the
    /// pane viewport once known. Frames are stored normalized, so only the
    /// 28pt offset depends on this being exact.
    var floatCanvasEstimate: CGRect {
        let width = max(1, layoutContext.viewportWidth)
        let height = paneViewportHeight.isFinite && paneViewportHeight < 100_000
            ? max(1, paneViewportHeight)
            : width * 0.625
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// Removes float `id` from `worklane` (the strip is untouched): drops its
    /// auxiliary state and servers, keeps PiP/pill orders dense and moves
    /// focus away when it was focused. Returns the removed float.
    @discardableResult
    func detachFloat(_ id: PaneID, from worklane: inout WorklaneState) -> FloatingPaneState? {
        guard let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return nil
        }
        let removed = worklane.floatingPanes.remove(at: index)
        Self.compactFloatOrders(in: &worklane)
        if worklane.focusedFloatID == id {
            moveFocusAway(from: id, in: &worklane)
        }
        clearPaneState(for: id, in: &worklane)
        serverRegistry.clear(worklaneID: worklane.id, paneID: id)
        return removed
    }

    /// When nothing owns focus (empty strip, no focused float), hands it to
    /// the front-most `.floating` float while floats are shown.
    static func focusFrontFloatIfUnfocused(in worklane: inout WorklaneState) {
        guard worklane.focusedPaneID == nil, !worklane.floatsHidden else {
            return
        }
        let front = worklane.floatingPanes
            .filter { $0.mode.isFloating }
            .max { $0.stackOrder < $1.stackOrder }
        worklane.focusedFloatID = front?.pane.id
    }

    /// Opens a copy of float `sourceID` (same cwd and command) as a new float,
    /// offset down-right from it, focused.
    func duplicateFloat(_ sourceID: PaneID) {
        guard var worklane = activeWorklane,
              let source = worklane.floatingPane(id: sourceID),
              let info = duplicateSourceInfo(for: sourceID, in: worklane) else {
            return
        }
        let original = worklane
        let pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: worklane.paneStripState.columns.count,
            workingDirectory: info.workingDirectory,
            sourceShellContext: info.shellContext,
            command: info.command
        )
        let canvas = floatCanvasEstimate
        let frame = FloatLayout.splitOffsetFrame(from: source.floatFrame.resolved(in: canvas), canvas: canvas)
        worklane.floatingPanes.append(
            FloatingPaneState(
                pane: pane,
                mode: .floating,
                floatFrame: NormalizedRect(rect: frame, in: canvas),
                stackOrder: Self.nextStackOrder(in: worklane),
                origin: nil
            )
        )
        worklane.floatsHidden = false
        worklane.focusedFloatID = pane.id
        commitFloatChange(from: original, to: worklane)
    }
}
