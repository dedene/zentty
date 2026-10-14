import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")

/// Muse Code's title spinner is the turn boundary the user sees (see
/// `MuseTitleActivity`). Both reconciliations act only on a title seen
/// spinning, so a Muse under a multiplexer with a static title is left to
/// its hooks.
extension WorklaneStore {
    /// A running Muse turn whose spinner settled is over, `Stop` or not.
    func completeMuseTurnIfTitleSettled(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        guard MuseTitleActivity.isBusy(previousMetadata?.title),
              !MuseTitleActivity.isBusy(metadata.title),
              var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              let existingStatus = auxiliaryState.agentStatus,
              existingStatus.tool == .muse,
              existingStatus.state == .running
        else {
            return
        }

        auxiliaryState.agentReducerState = AgentStatusReconciliation.seededReducerState(
            auxiliaryState.agentReducerState,
            from: existingStatus
        )
        let now = currentDateProvider()
        guard auxiliaryState.agentReducerState.markExplicitMuseSessionIdleFromSettledTitle(now: now) else {
            return
        }

        auxiliaryState.agentStatus = AgentStatusReconciliation.hydratedStatus(
            auxiliaryState.agentReducerState.reducedStatus(now: now),
            existingStatus: existingStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        stopSignalLogger.debug(
            "metadata.museTitleSettled pane=\(paneID.rawValue, privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) => idle"
        )
        requestReadyStatusIfNeeded(for: paneID, in: &worklane)
    }

    /// A Muse idle hook (root `Stop`) that lands while the spinner still runs
    /// is held as running: the post-turn reminder threads are still working,
    /// and `completeMuseTurnIfTitleSettled` ends the turn when they finish.
    static func museIdleIsHeldByBusyTitle(
        _ payload: AgentStatusPayload,
        tool: AgentTool,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        tool == .muse
            && payload.state == .idle
            && payload.origin == .explicitHook
            && MuseTitleActivity.isBusy(auxiliaryState.metadata?.title)
    }
}
