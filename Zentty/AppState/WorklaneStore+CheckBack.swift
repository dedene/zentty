import Foundation

/// Mark as Unread: a manual "Check back" status on an idle agent pane that
/// survives until the pane is visited again (#76).
extension WorklaneStore {
    func unreadToggle(for paneID: PaneID) -> PaneUnreadToggle? {
        guard let index = checkBackWorklaneIndex(for: paneID),
              let presentation = worklanes[index].auxiliaryStateByPaneID[paneID]?.presentation
        else {
            return nil
        }
        return PaneUnreadToggle.resolve(for: presentation)
    }

    /// Marks an idle agent pane as "Check back", or clears a visible
    /// "Check back" / "Agent ready" status without visiting the pane.
    @discardableResult
    func toggleUnread(paneID: PaneID) -> Bool {
        guard let toggle = unreadToggle(for: paneID),
              let index = checkBackWorklaneIndex(for: paneID)
        else {
            return false
        }

        var worklane = worklanes[index]
        let previousWorklane = worklane
        switch toggle {
        case .markUnread:
            let isCurrentVisit = worklane.id == activeWorklaneID
                && worklane.paneStripState.focusedPaneID == paneID
            worklane.auxiliaryStateByPaneID[paneID]?.raw.checkBackReminder =
                PaneCheckBackReminder(hasLeftPane: !isCurrentVisit)
            recomputePresentation(for: paneID, in: &worklane)
        case .markRead:
            worklane.auxiliaryStateByPaneID[paneID]?.raw.checkBackReminder = nil
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
            recomputePresentation(for: paneID, in: &worklane)
        }
        commitCheckBackChange(paneID: paneID, worklane: worklane, previousWorklane: previousWorklane, at: index)
        return true
    }

    /// Advances every pending "Check back" mark against the current focus:
    /// leaving a marked pane arms it, and returning to an armed pane clears it.
    func reconcileCheckBackVisits() {
        let markedPanes = worklanes.flatMap { worklane in
            worklane.paneStripState.panes.compactMap { pane in
                worklane.auxiliaryStateByPaneID[pane.id]?.raw.checkBackReminder == nil
                    ? nil
                    : PaneReference(worklaneID: worklane.id, paneID: pane.id)
            }
        }
        guard !markedPanes.isEmpty else { return }

        for reference in markedPanes {
            guard let index = worklanes.firstIndex(where: { $0.id == reference.worklaneID }),
                  let reminder = worklanes[index].auxiliaryStateByPaneID[reference.paneID]?.raw.checkBackReminder
            else {
                continue
            }

            let isCurrentVisit = reference.worklaneID == activeWorklaneID
                && worklanes[index].paneStripState.focusedPaneID == reference.paneID
            if !isCurrentVisit {
                if !reminder.hasLeftPane {
                    worklanes[index].auxiliaryStateByPaneID[reference.paneID]?.raw.checkBackReminder?.hasLeftPane = true
                }
                continue
            }
            guard reminder.hasLeftPane else { continue }

            var worklane = worklanes[index]
            let previousWorklane = worklane
            worklane.auxiliaryStateByPaneID[reference.paneID]?.raw.checkBackReminder = nil
            recomputePresentation(for: reference.paneID, in: &worklane)
            commitCheckBackChange(
                paneID: reference.paneID,
                worklane: worklane,
                previousWorklane: previousWorklane,
                at: index
            )
        }
    }

    /// A mark only describes an idle agent: once the agent works again, stops,
    /// or exits, the mark is spent.
    func dropSpentCheckBackReminder(for paneID: PaneID, in worklane: inout WorklaneState) {
        guard let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              auxiliaryState.raw.checkBackReminder != nil,
              auxiliaryState.presentation.runtimePhase != .idle
                || auxiliaryState.presentation.recognizedTool == nil
        else {
            return
        }
        worklane.auxiliaryStateByPaneID[paneID]?.raw.checkBackReminder = nil
    }

    private func commitCheckBackChange(
        paneID: PaneID,
        worklane: WorklaneState,
        previousWorklane: WorklaneState,
        at index: Int
    ) {
        worklanes[index] = worklane
        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
    }

    private func checkBackWorklaneIndex(for paneID: PaneID) -> Int? {
        worklanes.firstIndex { $0.paneStripState.panes.contains { $0.id == paneID } }
    }
}

extension WorklaneChange {
    /// Changes after which the focused pane of the active worklane may differ.
    var mayMoveFocus: Bool {
        switch self {
        case .paneStructure, .focusChanged, .activeWorklaneChanged, .worklaneListChanged:
            true
        case .layoutResized, .auxiliaryStateUpdated, .volatileAgentTitleUpdated, .teamAnchorsChanged, .historyChanged:
            false
        }
    }
}
