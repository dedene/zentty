import AppKit

/// Terminal tracking areas are geometric: a terminal reports pointer motion
/// (and so mouse-tracking escape sequences) wherever its rect is, even under
/// a view drawn over it. The layer tells each terminal it hosts where to
/// ignore the pointer, and the canvas re-tells the strip whenever a float or
/// PiP moves, not only on renders.
extension FloatLayerView {
    /// A PiP owns every event over it, so its scaled terminal ignores the
    /// pointer everywhere. A float ignores it under every float or PiP drawn
    /// above it (stack order, and a dragged PiP's raised layer). Leaving
    /// copies (+Transitions) are hit-transparent: they cover nothing, and
    /// their own terminal is muted when they leave.
    func updateFloatMouseOcclusion() {
        // Back to front, as drawn: layer zPosition first, then subview order.
        let drawn = subviews.enumerated().compactMap { index, view -> (rank: (CGFloat, Int), frame: CGRect, paneID: PaneID)? in
            if let float = view as? FloatContainerView, floatHosts[float.paneID] === float {
                return ((float.layer?.zPosition ?? 0, index), float.paneFrame, float.paneID)
            }
            if let pip = view as? PipContainerView, pipHosts[pip.paneID] === pip {
                return ((pip.layer?.zPosition ?? 0, index), pip.frame, pip.paneID)
            }
            return nil
        }.sorted { $0.rank < $1.rank }

        for (position, entry) in drawn.enumerated() {
            guard let container = containers[entry.paneID] else { continue }
            if pipHosts[entry.paneID] != nil {
                container.setFloatMouseOcclusionRects([container.bounds])
                continue
            }
            let covering = drawn[(position + 1)...].compactMap { above -> CGRect? in
                let rect = container.convert(above.frame, from: self).intersection(container.bounds)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            container.setFloatMouseOcclusionRects(covering)
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
}
