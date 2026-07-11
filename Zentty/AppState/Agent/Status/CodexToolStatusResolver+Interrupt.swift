import Foundation
import os

private let worklaneStoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneStore")
private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")
private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")

/// User-input/progress-driven Codex promotion, the interrupt /
/// suppression payload policy, and transient-state / transcript-context
/// clearing. Split out of `CodexToolStatusResolver.swift` along its MARK
/// sections.
extension CodexToolStatusResolver {
    // MARK: - User-input & progress promotion

    @discardableResult
    func promoteFromUserInput(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        allowNeedsInputResume: Bool,
        allowIdleResume: Bool,
        now: Date
    ) -> Bool {
        guard aux.agentStatus?.tool == .codex,
              aux.agentStatus?.source == .explicit
        else {
            return false
        }

        var working = aux
        let priorState = working.agentStatus?.state
        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            working.agentReducerState,
            from: working.agentStatus
        )
        guard working.agentReducerState.promoteExplicitCodexSessionFromUserInput(
            allowNeedsInputResume: allowNeedsInputResume,
            allowIdleResume: allowIdleResume,
            now: now
        ) else {
            return false
        }

        worklaneStoreLogger.notice(
            "promoteCodexAgentStateFromUserInput priorState=\(priorState.map(String.init(describing:)) ?? "nil", privacy: .public) pane=\(paneID.rawValue, privacy: .public)"
        )

        working.agentStatus = AgentStatusReconciliation.hydratedStatus(
            working.agentReducerState.reducedStatus(now: now),
            existingStatus: working.agentStatus
        )
        aux = working
        return true
    }

    @discardableResult
    func promoteRunningFromCurrentTitle(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        now: Date
    ) -> Bool {
        guard !aux.raw.codexInterruptSuppressionIsActive(),
              aux.agentStatus?.tool == .codex,
              aux.agentStatus?.source == .explicit,
              let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                  aux.metadata?.title,
                  recognizedTool: .codex
              ),
              signature.phase == .running else {
            return false
        }

        var working = aux
        let preState = working.agentStatus?.state.rawValue ?? "<nil>"
        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            working.agentReducerState,
            from: working.agentStatus
        )
        let didPromoteStarting = working.agentReducerState.promoteExplicitStartingSessionToRunning(now: now)
        let didResumeBlocked = working.agentReducerState.resumeBlockedSessionFromActivity(now: now)
        guard didPromoteStarting || didResumeBlocked else {
            return false
        }

        working.agentStatus = AgentStatusReconciliation.hydratedStatus(
            working.agentReducerState.reducedStatus(now: now),
            existingStatus: working.agentStatus
        )
        aux = working
        stopSignalLogger.debug(
            "codex.applyPayload.repromote pane=\(paneID.rawValue, privacy: .public) preState=\(preState, privacy: .public) didPromoteStarting=\(didPromoteStarting, privacy: .public) didResumeBlocked=\(didResumeBlocked, privacy: .public) => running"
        )
        return true
    }

    @discardableResult
    func promoteRunningFromCurrentTitleAndProgress(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        now: Date
    ) -> Bool {
        guard aux.terminalProgress?.state.indicatesActivity == true,
              !aux.raw.codexInterruptSuppressionIsActive(now: now),
              let existingStatus = aux.agentStatus,
              existingStatus.tool == .codex,
              existingStatus.state == .needsInput,
              existingStatus.interactionKind.requiresHumanAttention,
              let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                  aux.metadata?.title,
                  recognizedTool: .codex
              ),
              signature.phase == .running else {
            return false
        }

        let newStatus = Self.runningStatus(from: existingStatus, now: now)
        aux.agentStatus = newStatus
        aux.agentReducerState = AgentStatusReconciliation.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        stopSignalLogger.debug(
            "codex.progress.running force pane=\(paneID.rawValue, privacy: .public) preState=needsInput => running"
        )
        return true
    }

    func needsInputResumeAllowedFromUserSubmit(status: PaneAgentStatus?, now: Date) -> Bool {
        guard let status,
              status.tool == .codex,
              status.state == .needsInput || status.interactionKind.requiresHumanAttention else {
            return true
        }

        return now.timeIntervalSince(status.updatedAt) >= Self.inputSubmitStabilizationWindow
    }

    // MARK: - Interrupt / suppression payload policy

    func shouldSuppressPayloadDuringInterrupt(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        aux: PaneAuxiliaryState
    ) -> Bool {
        guard tool == .codex,
              aux.raw.codexInterruptSuppressionIsActive() else {
            return false
        }

        switch payload.signalKind {
        case .lifecycle:
            return payload.state == .idle || payload.clearsStatus
        case .pid, .paneRootPID, .shellState, .paneContext:
            return false
        }
    }

    func shouldSuppressTurnCompleteForCurrentNeedsInputTitle(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        aux: PaneAuxiliaryState
    ) -> Bool {
        guard tool == .codex,
              payload.lifecycleEvent == .turnComplete else {
            return false
        }

        return Self.currentTitleIndicatesNeedsInput(aux)
    }

    func shouldClearInterruptSuppression(
        payload: AgentStatusPayload,
        tool: AgentTool?
    ) -> Bool {
        guard tool == .codex else {
            return false
        }

        switch payload.signalKind {
        case .pid:
            return payload.pidEvent == .attach
        case .lifecycle:
            guard let state = payload.state else {
                return false
            }
            return state == .starting || state == .running || state == .needsInput
        case .shellState, .paneRootPID, .paneContext:
            return false
        }
    }

    func shouldClearTitleIdleSuppression(
        existingStatus: PaneAgentStatus?,
        incomingTool: AgentTool?,
        payload: AgentStatusPayload
    ) -> Bool {
        let tool = incomingTool ?? existingStatus?.tool
        guard tool == .codex else {
            return false
        }

        switch payload.signalKind {
        case .lifecycle:
            return payload.state != nil
        case .pid:
            return payload.pidEvent == .attach
        case .shellState:
            return payload.shellActivityState == .commandRunning
        case .paneRootPID, .paneContext:
            return false
        }
    }

    // MARK: - Transient state clearing & transcript context

    func clearTransientState(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        reason: String
    ) {
        let statusDescription = WorklaneStore.codexRestartStatusDescription(aux.agentStatus)
        let sessionCount = aux.agentReducerState.sessionsByID.count
        codexRestartLogger.notice(
            "\(reason, privacy: .public) clear pane=\(paneID.rawValue, privacy: .public) status=\(statusDescription, privacy: .public) sessions=\(sessionCount, privacy: .public)"
        )
        _ = aux.agentReducerState.clearCodexSessionsFromUserInterrupt()
        if aux.agentStatus?.tool == .codex {
            aux.agentStatus = nil
        }
        aux.terminalProgress = nil
        aux.raw.wantsReadyStatus = false
        aux.raw.showsReadyStatus = false
        aux.raw.codexCurrentRunHasObservedActivity = false
        aux.raw.codexTitleIdleSuppressionUntil = nil
        aux.raw.codexInterruptSuppressionUntil = nil
        aux.raw.codexTranscriptContext = nil
        aux.raw.lastDesktopNotificationText = nil
        aux.raw.lastDesktopNotificationDate = nil
    }

    func updateTranscriptContext(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        aux: inout PaneAuxiliaryState
    ) {
        guard tool == .codex else {
            return
        }

        if let path = WorklaneContextFormatter.trimmed(payload.agentTranscriptPath) {
            aux.raw.codexTranscriptContext = PaneCodexTranscriptContext(
                sessionID: WorklaneContextFormatter.trimmed(payload.sessionID)
                    ?? aux.raw.codexTranscriptContext?.sessionID,
                path: path
            )
            return
        }

        if (payload.state == .starting || payload.state == .running),
           let sessionID = WorklaneContextFormatter.trimmed(payload.sessionID),
           aux.raw.codexTranscriptContext?.sessionID != sessionID {
            aux.raw.codexTranscriptContext = nil
            return
        }

        guard let sessionID = WorklaneContextFormatter.trimmed(payload.sessionID),
              var context = aux.raw.codexTranscriptContext else {
            return
        }
        context.sessionID = sessionID
        aux.raw.codexTranscriptContext = context
    }
}
