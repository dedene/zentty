import CoreGraphics
import Foundation

/// Float pieces of the pane lifecycle that live outside the float operations
/// proper: closing a float, focus repair after the strip empties, and
/// duplicating a focused float.
extension WorklaneStore {

    /// Index of the worklane holding `paneID` as a tile or a float.
    /// Non-allocating; safe on the metadata/terminal-event hot paths.
    func worklaneIndex(containingPane paneID: PaneID) -> Int? {
        worklanes.firstIndex { $0.containsPane(id: paneID) }
    }

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

    /// Float/dock toggle for the focused pane of the active worklane: a
    /// focused tile lifts in place (`tileFrame` in `canvas` coordinates, nil
    /// centres it); a focused float docks back to its origin column. An empty
    /// canvas (layout not done yet) falls back to `floatCanvasEstimate`.
    func toggleFloat(canvas: CGRect, tileFrame: (PaneID) -> CGRect?) {
        guard let paneID = activeWorklane?.focusedPaneID else {
            return
        }
        toggleFloat(paneID, canvas: canvas, tileFrame: tileFrame)
    }

    /// Float/dock toggle for any pane of the active worklane (a tile's float
    /// button need not be on the focused pane).
    func toggleFloat(_ paneID: PaneID, canvas: CGRect, tileFrame: (PaneID) -> CGRect?) {
        guard let worklane = activeWorklane, worklane.containsPane(id: paneID) else {
            return
        }
        if worklane.isFloating(paneID) {
            dockPane(paneID, target: .origin)
            return
        }
        let usableCanvas = canvas.width > 0 && canvas.height > 0
        floatPane(
            paneID,
            canvas: usableCanvas ? canvas : floatCanvasEstimate,
            tileFrame: usableCanvas ? tileFrame(paneID) : nil
        )
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
        guard let worklane = activeWorklane,
              let info = duplicateSourceInfo(for: sourceID, in: worklane) else {
            return
        }
        openFloat(
            besideFloat: sourceID,
            in: worklane.id,
            workingDirectory: info.workingDirectory,
            sourceShellContext: info.shellContext,
            command: info.command
        )
    }

    /// Opens a new focused `.floating` pane offset down-right from float
    /// `sourceID` in worklane `worklaneID` (active or not). `configure` runs
    /// on the new pane before it is stored. Returns nil when the source is
    /// not a float in that worklane.
    @discardableResult
    func openFloat(
        besideFloat sourceID: PaneID,
        in worklaneID: WorklaneID,
        workingDirectory: String?,
        sourceShellContext: PaneShellContext?,
        command: String?,
        configure: (inout PaneState) -> Void = { _ in }
    ) -> PaneID? {
        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == worklaneID }),
              let source = worklanes[worklaneIndex].floatingPane(id: sourceID) else {
            return nil
        }
        let original = worklanes[worklaneIndex]
        var worklane = original
        var pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: worklane.paneStripState.columns.count,
            workingDirectory: workingDirectory,
            sourceShellContext: sourceShellContext,
            command: command
        )
        configure(&pane)
        let canvas = floatCanvasEstimate
        let frame = FloatLayout.splitOffsetFrame(from: source.floatFrame.resolved(in: canvas), canvas: canvas)
        worklane.floatingPanes.append(
            FloatingPaneState(
                pane: pane,
                mode: .floating,
                floatFrame: NormalizedRect(rect: frame, in: canvas),
                stackOrder: Self.nextStackOrder(in: worklane),
                origin: nil,
                sequence: Self.nextFloatSequence(in: worklane)
            )
        )
        worklane.floatsHidden = false
        worklane.focusedFloatID = pane.id
        commitFloat(worklane, from: original, at: worklaneIndex)
        return pane.id
    }

    /// Opens a replacement for float `oldID` (tmux `respawn-pane -k`): a new
    /// pane running `sessionRequest` in the old float's place — same mode,
    /// frame, z-order, origin and creation order — that takes focus when the
    /// old float had it. The caller closes the old float right after, which
    /// leaves PiP and pill orders dense again. Returns nil when `oldID` is not
    /// a float in worklane `worklaneID`.
    @discardableResult
    func openReplacementFloat(
        for oldID: PaneID,
        in worklaneID: WorklaneID,
        sessionRequest: TerminalSessionRequest
    ) -> PaneID? {
        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == worklaneID }),
              let oldIndex = worklanes[worklaneIndex].floatingPanes.firstIndex(where: { $0.pane.id == oldID }) else {
            return nil
        }
        let original = worklanes[worklaneIndex]
        var worklane = original
        let old = worklane.floatingPanes[oldIndex]
        var pane = makePane(in: &worklane, existingPaneCount: worklane.paneStripState.columns.count)
        applySessionRequestOverride(sessionRequest, to: &pane)
        pane.width = old.pane.width
        if let lifetime = worklane.auxiliaryStateByPaneID[oldID]?.lifetime {
            worklane.auxiliaryStateByPaneID[pane.id]?.lifetime = lifetime
        }
        var replacement = old
        replacement.pane = pane
        worklane.floatingPanes.insert(replacement, at: oldIndex + 1)
        if worklane.focusedFloatID == oldID {
            worklane.focusedFloatID = pane.id
        }
        commitFloat(worklane, from: original, at: worklaneIndex)
        return pane.id
    }

    /// Writes `worklane` back: through `commitFloatChange` when it is the
    /// active worklane, else in place with a `.floats` notification.
    private func commitFloat(_ worklane: WorklaneState, from original: WorklaneState, at worklaneIndex: Int) {
        if worklane.id == activeWorklaneID {
            commitFloatChange(from: original, to: worklane)
        } else {
            worklanes[worklaneIndex] = worklane
            notify(.floats(worklane.id))
        }
    }
}
