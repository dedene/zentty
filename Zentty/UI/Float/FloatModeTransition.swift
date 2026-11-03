import CoreGraphics

/// What a pane looks like in the float layer or the pill bar.
enum FloatPicture: Equatable, Sendable {
    case float
    case pip
    case pill
}

/// The motion one canvas render owes the float layer and the pill bar, read
/// off the content before and after it (FLIP, like the mockup's `withFlip`).
/// Float ⇄ PiP, tile → float and float → tile have motion of their own (the
/// layer's PiP spring, lift in place, the strip's dock settle) and are left
/// out.
struct FloatModeTransitionPlan: Equatable, Sendable {
    /// How a mounted float or PiP leaves while the model has moved on.
    enum Departure: Equatable, Sendable {
        /// Into its pill (minimize, a PiP evicted from a full corner).
        case toPill
        /// Fade and shrink a little: it closed.
        case close
        /// Fade and shrink a little less: Hide Floating Panes.
        case hide
    }

    /// How a float or PiP mounts.
    enum Entry: Equatable, Sendable {
        /// Out of its pill (restore, auto-pop, a pill dragged up).
        case fromPill
        /// Fade and grow in place (Show Floating Panes, a new float).
        case reveal
    }

    var departures: [PaneID: Departure] = [:]
    var entries: [PaneID: Entry] = [:]
    /// Pills that grow out of the float or PiP they replace.
    var pillArrivals: Set<PaneID> = []

    var isEmpty: Bool {
        departures.isEmpty && entries.isEmpty && pillArrivals.isEmpty
    }
}

enum FloatModeTransition {
    /// Each pane's picture: pills from the pill bar's content, floats and PiPs
    /// from the layer's (none while floats are hidden).
    static func pictures(of content: FloatLayerContent, pillIDs: Set<PaneID>) -> [PaneID: FloatPicture] {
        var result: [PaneID: FloatPicture] = [:]
        for float in content.floats {
            let paneID = float.pane.id
            if pillIDs.contains(paneID) {
                result[paneID] = .pill
                continue
            }
            guard !content.floatsHidden else { continue }
            switch float.mode {
            case .floating:
                result[paneID] = .float
            case .pip:
                result[paneID] = .pip
            case .minimized:
                break
            }
        }
        return result
    }

    /// The motion from `old` to `new`. Only within one worklane: a worklane
    /// switch (or the first render) swaps the layer's content without motion.
    /// `stripPaneIDs` are the new strip's panes (a float that docked).
    static func plan(
        from old: FloatLayerContent,
        oldPillIDs: Set<PaneID>,
        to new: FloatLayerContent,
        newPillIDs: Set<PaneID>,
        stripPaneIDs: Set<PaneID>
    ) -> FloatModeTransitionPlan {
        var plan = FloatModeTransitionPlan()
        guard let worklaneID = new.worklaneID, old.worklaneID == worklaneID else {
            return plan
        }
        let before = pictures(of: old, pillIDs: oldPillIDs)
        let after = pictures(of: new, pillIDs: newPillIDs)
        let oldFloatIDs = Set(old.floats.map(\.pane.id))
        let newFloatIDs = Set(new.floats.map(\.pane.id))
        let hidesAll = new.floatsHidden && !old.floatsHidden
        let showsAll = old.floatsHidden && !new.floatsHidden

        for (paneID, picture) in before {
            switch (picture, after[paneID]) {
            case (.float, .pill?), (.pip, .pill?):
                plan.departures[paneID] = .toPill
                plan.pillArrivals.insert(paneID)
            case (.float, nil), (.pip, nil):
                if newFloatIDs.contains(paneID) {
                    if hidesAll {
                        plan.departures[paneID] = .hide
                    }
                } else if !stripPaneIDs.contains(paneID) {
                    plan.departures[paneID] = .close
                }
            case (.pill, .float?), (.pill, .pip?):
                plan.entries[paneID] = .fromPill
            default:
                break
            }
        }
        for (paneID, picture) in after where picture != .pill && before[paneID] == nil {
            if showsAll, oldFloatIDs.contains(paneID) {
                plan.entries[paneID] = .reveal
            } else if !oldFloatIDs.contains(paneID) {
                // New, or a tile that floated: the layer prefers a lift in
                // place when one is pending.
                plan.entries[paneID] = .reveal
            }
        }
        return plan
    }
}
