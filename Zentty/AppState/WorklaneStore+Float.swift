import CoreGraphics
import Foundation

/// Where a docked float lands in the strip. Mirrors the pane drop targets
/// (`PaneDragOutcome`), restricted to the active worklane.
enum FloatDockTarget: Equatable, Sendable {
    /// A new column at `index` (gap between columns).
    case columnGap(index: Int)
    /// Into an existing column's stack at `paneIndex`.
    case stackGap(columnID: PaneColumnID, paneIndex: Int)
    /// Split onto `target`: `.vertical` stacks above/below, `.horizontal`
    /// places it left/right. `leading` means above or left.
    case split(target: PaneID, axis: PaneSplitPreview.Axis, leading: Bool)
    /// Back to the column index it was lifted from (after the focused column
    /// when that index no longer exists).
    case origin
}

/// Float operations on the active worklane. Every op keeps the invariants: a
/// PaneID is in the strip xor in `floatingPanes`, PiP/minimized orders are
/// dense, at most `FloatLayout.maxPipsPerCorner` PiPs per corner, and focus
/// never sits on a PiP, a minimized float or a hidden float.
extension WorklaneStore {

    // MARK: - Tile ⇄ float

    /// Lifts a tile out of the strip. `tileFrame` (canvas coordinates) lifts it
    /// in place; nil centres it at the default size. Focus moves to the float.
    func floatPane(_ id: PaneID, canvas: CGRect, tileFrame: CGRect?) {
        guard var worklane = activeWorklane, !worklane.isFloating(id) else {
            return
        }
        let original = worklane
        let previousColumnCount = worklane.paneStripState.columns.count
        guard let removal = worklane.paneStripState.removePane(
            id: id,
            singleColumnWidth: layoutContext.singlePaneWidth
        ) else {
            return
        }
        applyColumnWidthNormalization(
            &worklane,
            previousColumnCount: previousColumnCount,
            singleColumnWidth: layoutContext.singlePaneWidth
        )

        let frame = tileFrame.map { FloatLayout.liftedFrame(tileFrame: $0, canvas: canvas) }
            ?? FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
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
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    /// Puts a float back into the strip. A temporary pane becomes persistent.
    /// An unusable target (column gone, too little height) leaves it floating
    /// and returns false.
    @discardableResult
    func dockPane(_ id: PaneID, target: FloatDockTarget) -> Bool {
        guard var worklane = activeWorklane,
              let floatIndex = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return false
        }
        let original = worklane
        let float = worklane.floatingPanes[floatIndex]
        let previousColumnCount = worklane.paneStripState.columns.count
        var pane = float.pane
        pane.width = previousColumnCount == 0
            ? layoutContext.singlePaneWidth
            : layoutContext.newPaneWidth(existingPaneCount: previousColumnCount)

        guard insert(pane, into: &worklane.paneStripState, target: target, origin: float.origin) else {
            return false
        }
        worklane.floatingPanes.remove(at: floatIndex)
        Self.compactFloatOrders(in: &worklane)
        worklane.focusedFloatID = nil
        if case .temporary = worklane.auxiliaryStateByPaneID[id]?.lifetime {
            worklane.auxiliaryStateByPaneID[id]?.lifetime = .persistent
        }
        Self.clearAutoPopped(id, in: &worklane)
        applyColumnWidthNormalization(
            &worklane,
            previousColumnCount: previousColumnCount,
            singleColumnWidth: layoutContext.singlePaneWidth
        )
        commitFloatChange(from: original, to: worklane)
        return true
    }

    /// Opens a new pane directly as a float (never in the strip). Returns nil
    /// when there is no active worklane.
    @discardableResult
    func newFloat(
        request: TerminalSessionRequest,
        canvas: CGRect,
        lifetime: PaneLifetime = .persistent,
        initialFrame: CGRect? = nil
    ) -> PaneID? {
        guard var worklane = activeWorklane else {
            return nil
        }
        let original = worklane
        var pane = makePane(in: &worklane, existingPaneCount: worklane.paneStripState.columns.count)
        applySessionRequestOverride(request, to: &pane)
        worklane.auxiliaryStateByPaneID[pane.id]?.lifetime = lifetime

        let frame: CGRect
        if let initialFrame {
            let size = CGSize(
                width: max(initialFrame.width, FloatLayout.minimumFloatSize.width),
                height: max(initialFrame.height, FloatLayout.minimumFloatSize.height)
            )
            frame = FloatLayout.clamped(CGRect(origin: initialFrame.origin, size: size), in: canvas)
        } else {
            frame = FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
        }
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
        commitFloatChange(from: original, to: worklane)
        return pane.id
    }

    // MARK: - Put away

    /// Shrinks a float (or pill) into a PiP. `corner` nil keeps its current
    /// corner, else bottom-right. A full corner sends its oldest PiP to the
    /// pill bar. PiPs never hold focus.
    func pipPane(_ id: PaneID, corner: FloatCorner? = nil) {
        guard var worklane = activeWorklane,
              let float = worklane.floatingPane(id: id) else {
            return
        }
        let original = worklane
        let currentCorner = Self.pipCorner(of: float.mode)
        let targetCorner = corner ?? currentCorner ?? .bottomRight
        if currentCorner != targetCorner {
            placePip(id, corner: targetCorner, in: &worklane)
        }
        worklane.floatsHidden = false
        if worklane.focusedFloatID == id {
            moveFocusAway(from: id, in: &worklane)
        }
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    /// Moves a PiP to another corner (evicting that corner's oldest when full).
    func movePip(_ id: PaneID, to corner: FloatCorner) {
        guard var worklane = activeWorklane,
              let float = worklane.floatingPane(id: id),
              let currentCorner = Self.pipCorner(of: float.mode),
              currentCorner != corner else {
            return
        }
        let original = worklane
        placePip(id, corner: corner, in: &worklane)
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    /// Puts a float or PiP away as a pill (newest rightmost). A focused float
    /// hands focus to the previous eligible pane.
    func minimizePane(_ id: PaneID) {
        guard var worklane = activeWorklane,
              let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        if case .minimized = worklane.floatingPanes[index].mode {
            return
        }
        let original = worklane
        worklane.floatingPanes[index].mode = .minimized(order: Self.nextMinimizedOrder(in: worklane))
        Self.compactFloatOrders(in: &worklane)
        if worklane.focusedFloatID == id {
            moveFocusAway(from: id, in: &worklane)
        }
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    /// Brings a PiP or pill back as a float at its last frame, raised and
    /// focused. On a float that is already floating it just focuses it.
    func restoreFloat(_ id: PaneID) {
        guard var worklane = activeWorklane,
              let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        let original = worklane
        worklane.floatingPanes[index].mode = .floating
        Self.compactFloatOrders(in: &worklane)
        Self.raise(id, in: &worklane)
        worklane.floatsHidden = false
        worklane.focusedFloatID = id
        clearReadyStatusIfNeeded(for: id, in: &worklane)
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    // MARK: - Geometry, z-order, visibility, focus

    func moveFloat(_ id: PaneID, frame: NormalizedRect) {
        guard var worklane = activeWorklane,
              let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        let original = worklane
        worklane.floatingPanes[index].floatFrame = frame
        Self.clearAutoPopped(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    func raiseFloat(_ id: PaneID) {
        guard var worklane = activeWorklane, worklane.isFloating(id) else {
            return
        }
        let original = worklane
        Self.raise(id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    /// Hides or shows every float and PiP of the active worklane (pills stay).
    /// Hiding drops float focus back to the strip; showing hands focus to the
    /// front float when nothing else holds it (empty strip).
    func setFloatsHidden(_ hidden: Bool) {
        guard var worklane = activeWorklane, worklane.floatsHidden != hidden else {
            return
        }
        let original = worklane
        worklane.floatsHidden = hidden
        if hidden {
            worklane.focusedFloatID = nil
        } else {
            Self.focusFrontFloatIfUnfocused(in: &worklane)
        }
        commitFloatChange(from: original, to: worklane)
    }

    /// Gives keyboard focus to a float: raises it and un-hides floats. A PiP
    /// or pill is restored first.
    func focusFloat(_ id: PaneID) {
        guard var worklane = activeWorklane,
              let float = worklane.floatingPane(id: id) else {
            return
        }
        guard float.mode.isFloating else {
            restoreFloat(id)
            return
        }
        let original = worklane
        worklane.focusedFloatID = id
        worklane.floatsHidden = false
        Self.raise(id, in: &worklane)
        clearReadyStatusIfNeeded(for: id, in: &worklane)
        commitFloatChange(from: original, to: worklane)
    }

    // MARK: - Internals

    /// Writes the worklane back, records focus history and notifies `.floats`
    /// (+ `.paneStructure` when the strip changed, + `.focusChanged` when the
    /// focused pane changed). No-op when nothing changed.
    func commitFloatChange(from original: WorklaneState, to worklane: WorklaneState) {
        guard original != worklane else {
            return
        }
        let previousPaneRef = currentPaneReference
        activeWorklane = worklane
        let currentRef = currentPaneReference
        if previousPaneRef != currentRef,
           let previousPaneRef,
           Self.isEligibleFocusTarget(previousPaneRef.paneID, in: worklane) {
            recordFocusTransition(from: previousPaneRef)
        }
        if original.paneStripState != worklane.paneStripState || previousPaneRef != currentRef {
            refreshLastFocusedLocalWorkingDirectory()
        }
        batchUpdate {
            if original.paneStripState != worklane.paneStripState {
                notify(.paneStructure(worklane.id))
            }
            notify(.floats(worklane.id))
            if previousPaneRef != currentRef {
                notify(.focusChanged(worklane.id))
            }
        }
    }

    /// Focus fallback when the focused float is put away or closed: the most
    /// recent eligible pane in history (pending entry first), else the strip
    /// focus, else (empty strip) the front-most visible float, else no
    /// terminal focus.
    func moveFocusAway(from id: PaneID, in worklane: inout WorklaneState) {
        worklane.focusedFloatID = nil
        let candidates = [focusHistoryController.pendingReference].compactMap { $0 }
            + focusHistoryController.history.backStack.reversed()
        for reference in candidates where reference.worklaneID == worklane.id && reference.paneID != id {
            guard Self.isEligibleFocusTarget(reference.paneID, in: worklane) else {
                continue
            }
            if worklane.isFloating(reference.paneID) {
                worklane.focusedFloatID = reference.paneID
                Self.raise(reference.paneID, in: &worklane)
            } else {
                worklane.paneStripState.focusPane(id: reference.paneID)
            }
            return
        }
        Self.focusFrontFloatIfUnfocused(in: &worklane)
    }

    /// Sets `id` to `.pip` in `corner`, evicting that corner's oldest PiP to
    /// the pill bar when it is full. The newcomer stacks furthest out.
    private func placePip(_ id: PaneID, corner: FloatCorner, in worklane: inout WorklaneState) {
        if let evictedID = FloatLayout.evictionCandidate(in: worklane.floatingPanes, corner: corner, incoming: id),
           let evictedIndex = worklane.floatingPanes.firstIndex(where: { $0.pane.id == evictedID }) {
            worklane.floatingPanes[evictedIndex].mode = .minimized(order: Self.nextMinimizedOrder(in: worklane))
        }
        let occupants = FloatLayout.pips(in: worklane.floatingPanes, corner: corner, excluding: id)
        let order = (occupants.compactMap { Self.pipOrder(of: $0.mode) }.max() ?? -1) + 1
        if let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) {
            worklane.floatingPanes[index].mode = .pip(corner: corner, order: order)
        }
        Self.compactFloatOrders(in: &worklane)
    }

    private func insert(
        _ pane: PaneState,
        into strip: inout PaneStripState,
        target: FloatDockTarget,
        origin: FloatOrigin?
    ) -> Bool {
        switch target {
        case .columnGap(let index):
            strip.insertPaneAsColumn(pane, atColumnIndex: index, width: pane.width)
            return true

        case .stackGap(let columnID, let paneIndex):
            guard let anchorID = strip.columns.first(where: { $0.id == columnID })?.panes.first?.id else {
                return false
            }
            return strip.insertPaneIntoColumn(
                pane,
                columnID: columnID,
                targetPaneID: anchorID,
                atPaneIndex: paneIndex,
                availableHeight: paneViewportHeight
            )

        case .split(let targetID, let axis, let leading):
            guard let columnIndex = strip.columns.firstIndex(where: { column in
                column.panes.contains(where: { $0.id == targetID })
            }) else {
                return false
            }
            let column = strip.columns[columnIndex]
            switch axis {
            case .vertical:
                let targetIndex = column.panes.firstIndex(where: { $0.id == targetID }) ?? 0
                return strip.insertPaneIntoColumn(
                    pane,
                    columnID: column.id,
                    targetPaneID: targetID,
                    atPaneIndex: leading ? targetIndex : targetIndex + 1,
                    availableHeight: paneViewportHeight
                )
            case .horizontal:
                guard column.panes.count == 1 else {
                    return false
                }
                let splitWidth = max(1, column.width / 2)
                strip.columns[columnIndex].width = splitWidth
                strip.insertPaneAdjacentToColumn(
                    pane,
                    containingPaneID: targetID,
                    leading: leading,
                    width: splitWidth
                )
                return true
            }

        case .origin:
            if strip.columns.isEmpty {
                strip.insertPaneAsColumn(pane, atColumnIndex: 0, width: pane.width)
            } else if let columnIndex = origin?.columnIndex, columnIndex <= strip.columns.count {
                strip.insertPaneAsColumn(pane, atColumnIndex: columnIndex, width: pane.width)
            } else {
                strip.insertPaneHorizontally(pane, placement: .afterFocused)
            }
            return true
        }
    }

    // MARK: - Pure helpers

    /// A pane focus may land on: a tile, or a `.floating` float while floats
    /// are shown. Never a PiP, a pill or a hidden float.
    static func isEligibleFocusTarget(_ id: PaneID, in worklane: WorklaneState) -> Bool {
        if let float = worklane.floatingPane(id: id) {
            return float.mode.isFloating && !worklane.floatsHidden
        }
        return worklane.paneStripState.columns.contains { column in
            column.panes.contains { $0.id == id }
        }
    }

    static func nextStackOrder(in worklane: WorklaneState) -> Int {
        (worklane.floatingPanes.map(\.stackOrder).max() ?? -1) + 1
    }

    /// Creation order for a new float: after every live float.
    static func nextFloatSequence(in worklane: WorklaneState) -> Int {
        (worklane.floatingPanes.map(\.sequence).max() ?? -1) + 1
    }

    private static func nextMinimizedOrder(in worklane: WorklaneState) -> Int {
        (worklane.floatingPanes.compactMap { minimizedOrder(of: $0.mode) }.max() ?? -1) + 1
    }

    static func raise(_ id: PaneID, in worklane: inout WorklaneState) {
        guard let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        let others = worklane.floatingPanes.enumerated()
            .filter { $0.offset != index }
            .map(\.element.stackOrder)
        if let top = others.max(), worklane.floatingPanes[index].stackOrder <= top {
            worklane.floatingPanes[index].stackOrder = top + 1
        }
    }

    /// Renumbers PiP orders per corner and pill orders to 0..<n, keeping
    /// their relative order.
    static func compactFloatOrders(in worklane: inout WorklaneState) {
        for corner in FloatCorner.allCases {
            let ids = FloatLayout.pips(in: worklane.floatingPanes, corner: corner).map(\.pane.id)
            for (order, id) in ids.enumerated() {
                if let index = worklane.floatingPanes.firstIndex(where: { $0.pane.id == id }) {
                    worklane.floatingPanes[index].mode = .pip(corner: corner, order: order)
                }
            }
        }
        let minimizedIndices = worklane.floatingPanes.indices
            .compactMap { index -> (index: Int, order: Int)? in
                minimizedOrder(of: worklane.floatingPanes[index].mode).map { (index, $0) }
            }
            .sorted { $0.order == $1.order ? $0.index < $1.index : $0.order < $1.order }
        for (order, entry) in minimizedIndices.enumerated() {
            worklane.floatingPanes[entry.index].mode = .minimized(order: order)
        }
    }

    private static func clearAutoPopped(_ id: PaneID, in worklane: inout WorklaneState) {
        if worklane.auxiliaryStateByPaneID[id]?.autoPopped == true {
            worklane.auxiliaryStateByPaneID[id]?.autoPopped = false
        }
    }

    private static func pipCorner(of mode: FloatingPaneMode) -> FloatCorner? {
        if case .pip(let corner, _) = mode { return corner }
        return nil
    }

    private static func pipOrder(of mode: FloatingPaneMode) -> Int? {
        if case .pip(_, let order) = mode { return order }
        return nil
    }

    private static func minimizedOrder(of mode: FloatingPaneMode) -> Int? {
        if case .minimized(let order) = mode { return order }
        return nil
    }
}
