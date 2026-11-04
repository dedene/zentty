import Foundation

/// Auto-pop: a pill whose agent starts needing input pops up as a PiP in the
/// bottom-trailing corner, and goes back to its pill once the agent moves on,
/// unless the user touched it in between (any float op clears `autoPopped`).
///
/// It only pops in the active worklane with floats shown and the setting on;
/// otherwise the pill just turns amber. It never un-hides floats. Edges come
/// from `autoPopNeedsInputPaneIDs`, so a float that already needed input when
/// it was minimized (or when the user put a popped PiP away) stays put.
extension WorklaneStore {
    static let autoPopCorner: FloatCorner = .bottomRight

    static func mayChangeAutoPop(_ change: WorklaneChange) -> Bool {
        switch change {
        case .auxiliaryStateUpdated, .paneStructure, .floats, .worklaneListChanged:
            true
        default:
            false
        }
    }

    /// Whether `pane` reads as "needs input" (the amber pill).
    static func floatNeedsInput(_ paneID: PaneID, in worklane: WorklaneState) -> Bool {
        guard let presentation = worklane.auxiliaryStateByPaneID[paneID]?.presentation else {
            return false
        }
        return WorklaneAttentionSummaryBuilder.attentionState(for: presentation) == .needsInput
    }

    /// Records the floats that need input at launch, so a restored workspace
    /// never pops on its own.
    func seedAutoPopNeedsInput() {
        autoPopNeedsInputPaneIDs = Set(worklanes.flatMap { worklane in
            worklane.floatingPanes
                .map(\.pane.id)
                .filter { Self.floatNeedsInput($0, in: worklane) }
        })
    }

    /// Runs from `notify` before subscribers see the change.
    func reconcileAutoPop() {
        guard !isReconcilingAutoPop else {
            return
        }
        guard !autoPopNeedsInputPaneIDs.isEmpty || worklanes.contains(where: { !$0.floatingPanes.isEmpty }) else {
            return
        }
        isReconcilingAutoPop = true
        defer { isReconcilingAutoPop = false }

        var seen: Set<PaneID> = []
        var pops: [PaneID] = []
        var returns: [(worklaneID: WorklaneID, paneID: PaneID)] = []
        for worklane in worklanes {
            for float in worklane.floatingPanes {
                let id = float.pane.id
                seen.insert(id)
                let needsInput = Self.floatNeedsInput(id, in: worklane)
                let wasNeedingInput = autoPopNeedsInputPaneIDs.contains(id)
                if needsInput, !wasNeedingInput {
                    autoPopNeedsInputPaneIDs.insert(id)
                    if case .minimized = float.mode, canAutoPop(in: worklane) {
                        pops.append(id)
                    }
                } else if !needsInput, wasNeedingInput {
                    autoPopNeedsInputPaneIDs.remove(id)
                    if case .pip = float.mode, worklane.auxiliaryStateByPaneID[id]?.autoPopped == true {
                        returns.append((worklane.id, id))
                    }
                }
            }
        }
        // Docked or closed panes leave the set.
        autoPopNeedsInputPaneIDs.formIntersection(seen)
        guard !pops.isEmpty || !returns.isEmpty else {
            return
        }

        batchUpdate {
            for id in pops {
                pipPane(id, corner: Self.autoPopCorner)
                // `pipPane` clears the flag like any op; set it afterwards.
                setAutoPopped(id, true)
            }
            for entry in returns {
                returnAutoPoppedPip(entry.paneID, in: entry.worklaneID)
            }
        }
    }

    /// The user acted on a float without a store op (a PiP dragged back to its
    /// own corner, a bounce): it stays where it is once its agent moves on.
    func markFloatTouched(_ id: PaneID) {
        setAutoPopped(id, false)
    }

    private func canAutoPop(in worklane: WorklaneState) -> Bool {
        worklane.id == activeWorklaneID && !worklane.floatsHidden && autoPopNeedsInputProvider()
    }

    private func setAutoPopped(_ id: PaneID, _ value: Bool) {
        guard let index = worklaneIndex(containingPane: id),
              worklanes[index].auxiliaryStateByPaneID[id] != nil,
              worklanes[index].auxiliaryStateByPaneID[id]?.autoPopped != value else {
            return
        }
        worklanes[index].auxiliaryStateByPaneID[id]?.autoPopped = value
    }

    /// Back to the pill bar (newest rightmost). A PiP never holds focus, so
    /// this works the same in a worklane the user is not looking at.
    private func returnAutoPoppedPip(_ id: PaneID, in worklaneID: WorklaneID) {
        if worklaneID == activeWorklaneID {
            minimizePane(id)
            return
        }
        guard let index = worklanes.firstIndex(where: { $0.id == worklaneID }),
              let floatIndex = worklanes[index].floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        var worklane = worklanes[index]
        worklane.floatingPanes[floatIndex].mode = .minimized(order: Self.nextMinimizedOrder(in: worklane))
        Self.compactFloatOrders(in: &worklane)
        worklane.auxiliaryStateByPaneID[id]?.autoPopped = false
        worklanes[index] = worklane
        notify(.floats(worklaneID))
    }
}
