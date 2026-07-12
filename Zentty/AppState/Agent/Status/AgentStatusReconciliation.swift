import Foundation

/// Generic reducer-state ⇄ status bridging shared across every agent tool
/// (Claude, Codex, openCode, amp, …). These two helpers rehydrate a reducer
/// from a persisted `PaneAgentStatus` and re-hydrate a status from the reducer
/// output, carrying over per-pane context (working directory, launch snapshot)
/// that the reducer does not itself track.
///
/// Extracted verbatim from `WorklaneStore` so both the store and the
/// per-tool status resolvers can share one implementation.
@MainActor
enum AgentStatusReconciliation {
    static func seededReducerState(
        _ reducerState: PaneAgentReducerState,
        from existingStatus: PaneAgentStatus?
    ) -> PaneAgentReducerState {
        guard reducerState.sessionsByID.isEmpty, let existingStatus else {
            return reducerState
        }

        var seededReducerState = reducerState
        let sessionID = existingStatus.sessionID ?? "pane-\(existingStatus.tool.displayName.lowercased())"
        seededReducerState.sessionsByID[sessionID] = PaneAgentSessionState(
            sessionID: sessionID,
            parentSessionID: existingStatus.parentSessionID,
            agentLaunchSnapshot: existingStatus.agentLaunchSnapshot,
            tool: existingStatus.tool,
            state: existingStatus.state,
            text: existingStatus.text,
            artifactLink: existingStatus.artifactLink,
            updatedAt: existingStatus.updatedAt,
            source: existingStatus.source,
            origin: existingStatus.origin,
            interactionKind: existingStatus.interactionKind,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            hasObservedRunning: existingStatus.hasObservedRunning,
            taskProgress: existingStatus.taskProgress,
            completionCandidateDeadline: nil,
            idleVisibleUntil: existingStatus.state == .idle
                ? existingStatus.updatedAt.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow)
                : nil,
            unresolvedStopVisibleUntil: existingStatus.state == .unresolvedStop
                ? existingStatus.updatedAt.addingTimeInterval(PaneAgentReducerState.unresolvedStopVisibilityWindow)
                : nil,
            transientTextVisibleUntil: existingStatus.text == PaneAgentReducerState.compactingStatusText
                ? existingStatus.updatedAt.addingTimeInterval(PaneAgentReducerState.transientRunningTextVisibilityWindow)
                : nil
        )
        return seededReducerState
    }

    static func hydratedStatus(
        _ status: PaneAgentStatus?,
        existingStatus: PaneAgentStatus?,
        payloadWorkingDirectory: String? = nil
    ) -> PaneAgentStatus? {
        guard var status else {
            return nil
        }

        status.workingDirectory = WorklaneContextFormatter.trimmed(payloadWorkingDirectory)
            ?? existingStatus?.workingDirectory
        status.agentLaunchSnapshot = status.agentLaunchSnapshot ?? existingStatus?.agentLaunchSnapshot
        return status
    }
}
