import AppKit

/// Where a float owns the cursor over a piece of tile chrome (drag bar,
/// legend link, divider): the float's outset, resize zones included. The
/// float's cursor rects are the only ones there, so the chrome leaves these
/// rects out of its own cursor rects and doesn't `set()` its cursor while
/// the pointer is inside one. Same rects the strip terminals leave out
/// (`PaneStripView.setFloatCursorExclusionRects`).
@MainActor
struct FloatCursorExclusion {
    /// The rects in the owning view's coordinates. Resolved on demand, so
    /// they follow the chrome as it moves.
    var rectsProvider: (() -> [CGRect])?

    var rects: [CGRect] {
        rectsProvider?() ?? []
    }

    /// `rect` minus the exclusion rects, for `addCursorRect`.
    func cursorRects(covering rect: CGRect) -> [CGRect] {
        FloatResizeCursorZones.subtract(rects, from: rect).filter { !$0.isEmpty }
    }

    /// Whether a float owns the pointer at `windowPoint`.
    func excludes(windowPoint: CGPoint, in view: NSView) -> Bool {
        let point = view.convert(windowPoint, from: nil)
        return rects.contains { $0.contains(point) }
    }

    /// Whether a float owns the pointer where it is now.
    func excludesCurrentPointer(in view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return excludes(windowPoint: window.mouseLocationOutsideOfEventStream, in: view)
    }
}
