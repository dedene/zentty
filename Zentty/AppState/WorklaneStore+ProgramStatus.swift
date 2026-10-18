import Foundation
import os

private let programStatusLogger = Logger(subsystem: "be.zenjoy.zentty", category: "ProgramStatus")

/// Program status: what a pane's program reports about itself through the
/// OSC 9;4 progress sequence. Shown only for panes no agent owns.
extension WorklaneStore {
    /// Records the status an OSC 9;4 report sets. Agent panes keep their
    /// hook status and leave the program status empty.
    func applyProgramStatusReport(
        _ report: TerminalProgressReport,
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
        let paneHasAgent = auxiliaryState?.agentStatus != nil
            || auxiliaryState?.presentation.recognizedTool != nil
        let nextStatus: PaneProgramStatus?
        if programStatusEnabledProvider(), !paneHasAgent {
            nextStatus = PaneProgramStatus(report: report, now: currentDateProvider())
        } else {
            nextStatus = nil
        }

        guard nextStatus != nil || auxiliaryState?.raw.programStatus != nil else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].raw.programStatus = nextStatus
        if nextStatus?.state == .working {
            scheduleProgramStatusStaleCheck(for: paneID)
        } else {
            cancelProgramStatusStaleCheck(for: paneID)
        }
    }

    /// Applies a pane event's clearing rule to the pane's program status.
    func clearProgramStatus(
        _ trigger: PaneProgramStatus.ClearTrigger,
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        guard let current = worklane.auxiliaryStateByPaneID[paneID]?.raw.programStatus else {
            return
        }

        let next = current.surviving(trigger)
        guard next != current else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.programStatus = next
        if next?.state != .working {
            cancelProgramStatusStaleCheck(for: paneID)
        }
    }

    /// Drops every program status once `panes.program_status` is turned
    /// off, so a status set before the change doesn't linger.
    func clearProgramStatusesIfDisabled() {
        guard !programStatusEnabledProvider() else {
            return
        }

        for worklaneIndex in worklanes.indices {
            let paneIDs = worklanes[worklaneIndex].auxiliaryStateByPaneID
                .filter { $0.value.raw.programStatus != nil }
                .map(\.key)
            for paneID in paneIDs {
                cancelProgramStatusStaleCheck(for: paneID)
                removeProgramStatus(paneID: paneID, worklaneIndex: worklaneIndex)
            }
        }
    }

    // Keyed by pane ID alone: a pane keeps its status when it moves to
    // another worklane, so the check must find it there.
    private func scheduleProgramStatusStaleCheck(for paneID: PaneID) {
        pendingProgramStatusStaleTasks[paneID]?.cancel()
        pendingProgramStatusStaleTasks[paneID] = scheduleReadyStatusTask(
            PaneProgramStatus.staleInterval
        ) { [weak self] in
            self?.pendingProgramStatusStaleTasks[paneID] = nil
            self?.dropStaleProgramStatus(for: paneID)
        }
    }

    private func cancelProgramStatusStaleCheck(for paneID: PaneID) {
        pendingProgramStatusStaleTasks.removeValue(forKey: paneID)?.cancel()
    }

    func dropStaleProgramStatus(for paneID: PaneID) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }),
            let auxiliaryState = worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID],
            auxiliaryState.raw.programStatus?.isStale(now: currentDateProvider()) == true
        else {
            return
        }

        // The local shell says the command is still running, and its prompt
        // will clear the status when it ends: keep it and check again later.
        if auxiliaryState.shellActivityState == .commandRunning,
           !auxiliaryState.presentation.isRemotePane {
            scheduleProgramStatusStaleCheck(for: paneID)
            return
        }

        programStatusLogger.debug(
            "Dropping stale program status pane=\(paneID.rawValue, privacy: .public)"
        )
        removeProgramStatus(paneID: paneID, worklaneIndex: worklaneIndex)
    }

    private func removeProgramStatus(paneID: PaneID, worklaneIndex: Int) {
        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        worklane.auxiliaryStateByPaneID[paneID]?.raw.programStatus = nil
        recomputePresentation(for: paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        let impacts = auxiliaryInvalidation(
            for: paneID,
            previousWorklane: previousWorklane,
            nextWorklane: worklane
        )
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
    }
}
