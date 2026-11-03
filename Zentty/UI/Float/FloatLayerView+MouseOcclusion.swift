import AppKit

/// Terminal tracking areas are geometric: a terminal reports pointer motion
/// (and so mouse-tracking escape sequences) wherever its rect is, even under
/// a view drawn over it. The layer tells each terminal it hosts where to
/// ignore the pointer, and the canvas re-tells the strip whenever a float or
/// PiP moves, not only on renders.
///
/// Cursors follow the same stacking: a float's resize zones are cursor
/// rects on its host, and nothing else may put a cursor rect over them (see
/// `FloatContainerView+Cursor`).
extension FloatLayerView {
    /// A PiP owns every event over it, so its scaled terminal ignores the
    /// pointer everywhere. A float ignores it under every float or PiP drawn
    /// above it (stack order, and a dragged PiP's raised layer). Leaving
    /// copies (+Transitions) are hit-transparent: they cover nothing, and
    /// their own terminal is muted when they leave.
    func updateFloatMouseOcclusion() {
        // Back to front, as drawn: layer zPosition first, then subview order.
        // `owned` is what takes presses: a float's whole outset (band and
        // resize zones), a PiP's frame.
        let drawn = subviews.enumerated().compactMap { index, view -> DrawnFloatEntry? in
            if let float = view as? FloatContainerView, floatHosts[float.paneID] === float {
                return DrawnFloatEntry(
                    rank: (float.layer?.zPosition ?? 0, index),
                    frame: float.paneFrame,
                    owned: Self.ownedFrame(ofFloatAt: float.paneFrame),
                    paneID: float.paneID
                )
            }
            if let pip = view as? PipContainerView, pipHosts[pip.paneID] === pip {
                return DrawnFloatEntry(
                    rank: (pip.layer?.zPosition ?? 0, index),
                    frame: pip.frame,
                    owned: pip.frame,
                    paneID: pip.paneID
                )
            }
            return nil
        }.sorted { $0.rank < $1.rank }

        for (position, entry) in drawn.enumerated() {
            guard let container = containers[entry.paneID] else { continue }
            if pipHosts[entry.paneID] != nil {
                container.setFloatMouseOcclusionRects([container.bounds])
                continue
            }
            let above = drawn[(position + 1)...]
            let covering = above.compactMap { above -> CGRect? in
                let rect = container.convert(above.frame, from: self).intersection(container.bounds)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            container.setFloatMouseOcclusionRects(covering)
            guard let host = floatHosts[entry.paneID] else { continue }
            host.cursorOcclusionRects = above.map { host.convert($0.owned, from: self) }
            // The terminal inside shows no cursor in its own resize zones nor
            // in what floats above own (their zones reach past their pane).
            container.setFloatCursorExclusionRects(
                host.resizeCursorZoneRects.map { container.convert($0, from: host) }
                    + above.map { container.convert($0.owned, from: self) }
            )
        }
        onOccludingFramesChanged?()
    }

    /// A leaving copy keeps drawing with the pane's terminal inside: mute it
    /// so it reports no pointer motion while it fades.
    func muteMouseTracking(ofDeparting view: NSView) {
        let container = (view as? FloatContainerView)?.hostedContainer
            ?? (view as? PipContainerView)?.hostedContainer
        guard let container else { return }
        container.setFloatMouseOcclusionRects([container.bounds])
    }

    /// What mounted floats own for presses (their outset: the move band and
    /// resize zones) in `view`'s coordinates: the strip's terminals show no
    /// cursor of their own there.
    func cursorOwningFrames(in view: NSView) -> [CGRect] {
        floatHosts.values.map { view.convert(Self.ownedFrame(ofFloatAt: $0.paneFrame), from: self) }
    }

    private static func ownedFrame(ofFloatAt paneFrame: CGRect) -> CGRect {
        paneFrame.insetBy(dx: -FloatContainerView.chromeOutset, dy: -FloatContainerView.chromeOutset)
    }
}

private struct DrawnFloatEntry {
    let rank: (CGFloat, Int)
    /// Pane rect (float) or frame (PiP): where terminals below ignore the pointer.
    let frame: CGRect
    /// Where presses belong to it: where terminals below show no cursor.
    let owned: CGRect
    let paneID: PaneID
}
