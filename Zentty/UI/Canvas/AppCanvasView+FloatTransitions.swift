import AppKit

/// The canvas's half of mode-change motion: it sees the float layer and the
/// pill bar at once, so it records what both drew before a render, reads
/// the plan off the content change (`FloatModeTransition`) and hands each
/// side its motion in its own coordinates.
extension AppCanvasView {
    /// What the float layer and the pill bar showed before a render. Frames
    /// are in float-layer coordinates.
    struct FloatTransitionStart {
        let content: FloatLayerContent
        let pillIDs: Set<PaneID>
        let frames: [PaneID: CGRect]
    }

    func captureFloatTransitionStart() -> FloatTransitionStart {
        var frames = floatLayerView.pictureFrames()
        for (paneID, frame) in pillBarView.pillFrames() {
            frames[paneID] = floatLayerView.convert(frame, from: pillBarView)
        }
        return FloatTransitionStart(
            content: floatLayerView.content,
            pillIDs: Set(pillBarView.content.items.map(\.paneID)),
            frames: frames
        )
    }

    /// Runs after the pill bar's render (new pills have frames) and before
    /// the float layer's (which mounts and unmounts).
    func prepareFloatTransitions(
        from start: FloatTransitionStart,
        to floats: FloatLayerContent,
        strip: PaneStripState
    ) -> FloatModeTransitionPlan {
        let plan = FloatModeTransition.plan(
            from: start.content,
            oldPillIDs: start.pillIDs,
            to: floats,
            newPillIDs: Set(pillBarView.content.items.map(\.paneID)),
            stripPaneIDs: Set(strip.panes.map(\.id))
        )
        guard !plan.isEmpty else { return plan }
        let newPillFrames = pillBarView.pillFrames()
        var departures: [PaneID: FloatDeparture] = [:]
        for (paneID, departure) in plan.departures {
            switch departure {
            case .toPill:
                // An overflowed pill has no frame: fade out in place.
                departures[paneID] = newPillFrames[paneID]
                    .map { .toFrame(floatLayerView.convert($0, from: pillBarView)) } ?? .hide
            case .close:
                departures[paneID] = .close
            case .hide:
                departures[paneID] = .hide
            }
        }
        var entries: [PaneID: FloatEntry] = [:]
        for (paneID, entry) in plan.entries {
            switch entry {
            case .fromPill:
                entries[paneID] = start.frames[paneID].map(FloatEntry.fromFrame) ?? .reveal
            case .reveal:
                entries[paneID] = .reveal
            }
        }
        floatLayerView.prepareTransitions(departures: departures, entries: entries)
        return plan
    }

    /// Runs after the float layer's render: new pills grow out of the float
    /// or PiP they replace.
    func finishFloatTransitions(_ plan: FloatModeTransitionPlan, from start: FloatTransitionStart) {
        for paneID in plan.pillArrivals {
            guard let frame = start.frames[paneID] else { continue }
            pillBarView.animateArrival(of: paneID, from: pillBarView.convert(frame, from: floatLayerView))
        }
    }

    /// Where `paneID` is drawn now as a float, PiP or pill (float-layer
    /// coordinates): where a docking pane flies into the strip from.
    func floatPictureFrame(for paneID: PaneID) -> CGRect? {
        if let frame = floatLayerView.pictureFrames()[paneID] {
            return frame
        }
        return pillBarView.pillFrames()[paneID].map { floatLayerView.convert($0, from: pillBarView) }
    }
}
