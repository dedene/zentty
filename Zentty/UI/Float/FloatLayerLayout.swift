import CoreGraphics

/// Where one float is drawn in the float layer.
struct FloatLayerPlacement: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A live float at `frame` (layer coordinates).
        case floating
        /// A PiP: drawn at `frame`, but its content keeps `contentSize` and is
        /// scaled down (bounds scaling), so the terminal grid does not change.
        case pip(contentSize: CGSize)
    }

    let paneID: PaneID
    let kind: Kind
    let frame: CGRect

    /// Size the float's content is laid out at (the float frame, or the
    /// unscaled float size for a PiP).
    var contentSize: CGSize {
        switch kind {
        case .floating:
            frame.size
        case .pip(let contentSize):
            contentSize
        }
    }
}

/// Pure placement for the float layer: which floats are mounted, in which
/// z-order, and at which frame. Coordinates are y-up, like `FloatLayout`.
enum FloatLayerLayout {
    /// Mounted floats back to front (`stackOrder`, stored order on ties).
    /// Minimized floats and everything while `floatsHidden` are left out.
    static func placements(
        floats: [FloatingPaneState],
        floatsHidden: Bool,
        canvas: CGRect,
        pipWidth: CGFloat = FloatLayout.pipSmallWidth,
        bottomInset: CGFloat = 0
    ) -> [FloatLayerPlacement] {
        guard !floatsHidden, canvas.width > 0, canvas.height > 0 else {
            return []
        }

        let pipFrames = pipFrames(
            floats: floats,
            canvas: canvas,
            pipWidth: pipWidth,
            bottomInset: bottomInset
        )

        return FloatingPaneState.byStackOrder(floats)
            .compactMap { float -> FloatLayerPlacement? in
                switch float.mode {
                case .floating:
                    return FloatLayerPlacement(
                        paneID: float.pane.id,
                        kind: .floating,
                        frame: floatFrame(for: float, canvas: canvas)
                    )
                case .pip:
                    guard let pip = pipFrames[float.pane.id] else {
                        return nil
                    }
                    return FloatLayerPlacement(
                        paneID: float.pane.id,
                        kind: .pip(contentSize: pip.contentSize),
                        frame: pip.frame
                    )
                case .minimized:
                    return nil
                }
            }
    }

    /// The float's stored frame resolved against `canvas`, kept inside it and
    /// snapped to whole points.
    static func floatFrame(for float: FloatingPaneState, canvas: CGRect) -> CGRect {
        let resolved = FloatLayout.clamped(float.floatFrame.resolved(in: canvas), in: canvas)
        return CGRect(
            x: resolved.minX.rounded(),
            y: resolved.minY.rounded(),
            width: max(1, resolved.width.rounded()),
            height: max(1, resolved.height.rounded())
        )
    }

    /// PiP frames per corner. PiPs stack away from the corner in `order`; each
    /// one is as tall as its own float's aspect ratio asks.
    private static func pipFrames(
        floats: [FloatingPaneState],
        canvas: CGRect,
        pipWidth: CGFloat,
        bottomInset: CGFloat
    ) -> [PaneID: (frame: CGRect, contentSize: CGSize)] {
        var result: [PaneID: (frame: CGRect, contentSize: CGSize)] = [:]
        for corner in FloatCorner.allCases {
            var offset: CGFloat = 0
            for pip in FloatLayout.pips(in: floats, corner: corner) {
                let contentSize = floatFrame(for: pip, canvas: canvas).size
                let size = FloatLayout.pipSize(floatSize: contentSize, width: pipWidth)
                let base = FloatLayout.pipFrame(
                    corner: corner,
                    indexInCorner: 0,
                    size: size,
                    canvas: canvas,
                    bottomInset: bottomInset
                )
                let frame: CGRect
                switch corner {
                case .bottomLeft, .bottomRight:
                    frame = base.offsetBy(dx: 0, dy: offset)
                case .topLeft, .topRight:
                    frame = base.offsetBy(dx: 0, dy: -offset)
                }
                result[pip.pane.id] = (frame, contentSize)
                offset += size.height + FloatLayout.pipGap
            }
        }
        return result
    }
}
