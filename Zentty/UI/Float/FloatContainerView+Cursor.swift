import AppKit

/// A live resize pins its cursor: the window's cursor rects are off until
/// the press ends, so neither leaving the zone nor crossing a terminal can
/// swap it mid-drag.
struct FloatResizeCursorHold {
    let handle: FloatResizeHandle
    let cursor: NSCursor
    weak var window: NSWindow?
    /// Cursor rects were on when the hold began (only then turn them back on).
    let reenablesCursorRects: Bool
}

/// Resize cursors for a float's corners and left/right/bottom edges. The
/// zones are cursor rects on this view. Cursor rects that overlap have no
/// defined winner, so nothing else claims these rects: the hosted terminal
/// and the terminals underneath leave them out of their I-beam rects
/// (`setFloatCursorExclusionRects`, set by the float layer), and a float
/// leaves out what floats and PiPs drawn above it cover
/// (`cursorOcclusionRects`). The move band (top edge) keeps the arrow.
extension FloatContainerView {
    override func resetCursorRects() {
        super.resetCursorRects()
        for zone in visibleResizeCursorZones {
            addCursorRect(zone.rect, cursor: FloatResizeCursor.cursor(for: zone.handle))
        }
    }

    /// Every resize zone, covered or not (bounds coordinates): where the
    /// hosted terminal must not show its own cursor.
    var resizeCursorZoneRects: [CGRect] {
        FloatResizeCursorZones.zones(
            bounds: bounds,
            band: FloatGesture.band,
            cornerZone: FloatGesture.cornerZone
        ).map(\.rect)
    }

    /// The zones that show a cursor now: none while hidden or leaving, and
    /// none under a float or PiP drawn above. (The legend buttons sit on the
    /// top border, `PaneBorderActionsLayout.trailingInset` in: clear of the
    /// corner zones.)
    var visibleResizeCursorZones: [FloatResizeCursorZone] {
        guard !isHiddenOrHasHiddenAncestor, !isDeparting, hostedContainer != nil else { return [] }
        return FloatResizeCursorZones.zones(
            bounds: bounds,
            band: FloatGesture.band,
            cornerZone: FloatGesture.cornerZone,
            excluding: cursorOcclusionRects
        )
    }

    func invalidateResizeCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            endResizeCursorHold()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Live resize

    /// From the press on: the drag keeps `handle`'s cursor wherever the
    /// pointer goes.
    func beginResizeCursorHold(_ handle: FloatResizeHandle) {
        endResizeCursorHold()
        let cursor = FloatResizeCursor.cursor(for: handle)
        let reenables = window?.areCursorRectsEnabled ?? false
        if reenables {
            window?.disableCursorRects()
        }
        resizeCursorHold = FloatResizeCursorHold(
            handle: handle,
            cursor: cursor,
            window: window,
            reenablesCursorRects: reenables
        )
        cursor.set()
    }

    /// Re-asserts the held cursor (a tracking area that fires during drags
    /// may have set its own).
    func refreshResizeCursorHold() {
        resizeCursorHold?.cursor.set()
    }

    /// Hands the cursor back to the cursor rects: the zone under the pointer
    /// if it is one of this float's, else the arrow until a rect claims it.
    func endResizeCursorHold() {
        guard let hold = resizeCursorHold else { return }
        resizeCursorHold = nil
        guard let window = hold.window else { return }
        if hold.reenablesCursorRects {
            window.enableCursorRects()
        }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let handle = window === self.window
            ? FloatResizeCursorZones.handle(at: pointer, in: visibleResizeCursorZones)
            : nil
        (handle.map(FloatResizeCursor.cursor(for:)) ?? NSCursor.arrow).set()
        window.resetCursorRects()
    }

    var resizeCursorHoldForTesting: FloatResizeCursorHold? {
        resizeCursorHold
    }
}
