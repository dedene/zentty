import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")
private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")

/// Title-driven Codex reconciliation: the volatile-title fast-path gate,
/// needs-input/running title promotion, the running-status factory, and
/// the running-promotion diagnostics. Split out of
/// `CodexToolStatusResolver.swift` along its MARK sections.
extension CodexToolStatusResolver {
    // MARK: - Volatile-title fast path gate

    func shouldTakeVolatileTitleFastPath(
        in aux: PaneAuxiliaryState,
        nextMetadata: TerminalMetadata
    ) -> Bool {
        if aux.agentStatus?.interactionKind.requiresHumanAttention == true {
            return false
        }
        if let existingStatus = aux.agentStatus,
           existingStatus.tool == .codex,
           let nextTitlePhase = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                nextMetadata.title,
                recognizedTool: .codex
           )?.phase {
            if nextTitlePhase == .needsInput {
                return false
            }
            if !Self.volatileTitleFastPathStatusMatches(
                existingStatus: existingStatus,
                titlePhase: nextTitlePhase
            ) {
                return false
            }
        } else if AgentToolRecognizer.recognize(metadata: nextMetadata) == .codex,
                  TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            nextMetadata.title,
            recognizedTool: .codex
        ) != nil {
            return false
        }
        return true
    }

    private static func volatileTitleFastPathStatusMatches(
        existingStatus: PaneAgentStatus,
        titlePhase: TerminalMetadataChangeClassifier.VolatileAgentStatusPhase
    ) -> Bool {
        switch titlePhase {
        case .starting:
            return existingStatus.state == .starting
        case .running:
            return existingStatus.state == .running
        case .idle:
            return existingStatus.state == .idle
        case .needsInput:
            return false
        }
    }

    // MARK: - Blocked-title ready clearing

    func blockedTitleRequiresReadyClear(
        in aux: PaneAuxiliaryState,
        metadata: TerminalMetadata
    ) -> Bool {
        let recognizedTool = aux.raw.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex else {
            return false
        }

        let codexTitleInteractionKind = TerminalMetadataChangeClassifier.codexTitleInteractionKind(
            for: metadata.title
        )
        let waitingTitleKind = TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title)
        let titleNeedsInput = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        )?.phase == .needsInput
        return codexTitleInteractionKind != nil || waitingTitleKind != nil || titleNeedsInput
    }

    // MARK: - Needs-input title promotion

    @discardableResult
    func promoteTitleNeedsInput(
        _ aux: inout PaneAuxiliaryState,
        metadata: TerminalMetadata,
        now: Date
    ) -> Bool {
        let recognizedTool = aux.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        let titleInteractionKind = TerminalMetadataChangeClassifier.codexTitleInteractionKind(
            for: metadata.title
        )
        guard
            recognizedTool == .codex,
            titleInteractionKind != nil,
            !aux.raw.codexInterruptSuppressionIsActive()
        else {
            return false
        }

        if aux.agentStatus?.state == .needsInput {
            return false
        }

        let existingStatus = aux.agentStatus
        let titleText = AgentInteractionClassifier.trimmed(metadata.title)
        let interactionKind = titleInteractionKind ?? .genericInput
        aux.agentStatus = PaneAgentStatus(
            tool: .codex,
            state: .needsInput,
            text: titleText ?? existingStatus?.text,
            artifactLink: existingStatus?.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: .inferred,
            interactionKind: interactionKind,
            confidence: .weak,
            shellActivityState: existingStatus?.shellActivityState ?? .unknown,
            trackedPID: existingStatus?.trackedPID,
            workingDirectory: existingStatus?.workingDirectory,
            hasObservedRunning: existingStatus?.hasObservedRunning == true,
            sessionID: existingStatus?.sessionID,
            parentSessionID: existingStatus?.parentSessionID,
            taskProgress: existingStatus?.taskProgress
        )
        return true
    }

    // MARK: - Running title promotion

    func promoteTitleRunning(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        now: Date
    ) {
        let recognizedTool = aux.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex else {
            logRunningPromotionSkippedIfRelevant(
                reason: "recognizedTool",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: aux
            )
            return
        }
        guard let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        ) else {
            logRunningPromotionSkippedIfRelevant(
                reason: "noSignature",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: aux
            )
            return
        }
        guard signature.phase == .running else {
            logRunningPromotionSkippedIfRelevant(
                reason: "phase-\(signature.phase)",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: aux
            )
            return
        }
        var working = aux
        guard !working.raw.codexInterruptSuppressionIsActive() else {
            logRunningPromotionSkippedIfRelevant(
                reason: "interruptSuppression",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: working
            )
            return
        }

        if let existingStatus = working.agentStatus {
            let runningTitleMayClearBlockedStatus = Self.runningTitleMayClearBlockedStatus(
                existingStatus,
                auxiliaryState: working
            )
            if Self.statusShouldBlockTitleDrivenResume(existingStatus),
               !runningTitleMayClearBlockedStatus {
                logRunningPromotionSkippedIfRelevant(
                    reason: "blockedStatus",
                    paneID: paneID,
                    recognizedTool: recognizedTool,
                    previousMetadata: previousMetadata,
                    metadata: metadata,
                    auxiliaryState: working
                )
                return
            }

            if runningTitleMayClearBlockedStatus {
                let newStatus = Self.runningStatus(from: existingStatus, now: now)
                working.agentStatus = newStatus
                working.agentReducerState = AgentStatusReconciliation.seededReducerState(
                    PaneAgentReducerState(),
                    from: newStatus
                )
                aux = working
                stopSignalLogger.debug(
                    "codex.title.running cleared-blocked-status pane=\(paneID.rawValue, privacy: .public)"
                )
                return
            }
        }

        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            working.agentReducerState,
            from: working.agentStatus
        )
        let preState = working.agentStatus?.state.rawValue ?? "<nil>"
        let didPromoteStarting = working.agentReducerState.promoteExplicitStartingSessionToRunning(now: now)
        let didResumeBlocked = working.agentReducerState.resumeBlockedSessionFromActivity(now: now)

        if didPromoteStarting || didResumeBlocked {
            working.agentStatus = AgentStatusReconciliation.hydratedStatus(
                working.agentReducerState.reducedStatus(),
                existingStatus: working.agentStatus
            )
            aux = working
            stopSignalLogger.debug(
                "codex.title.running reducer-promote pane=\(paneID.rawValue, privacy: .public) preState=\(preState, privacy: .public) didPromoteStarting=\(didPromoteStarting, privacy: .public) didResumeBlocked=\(didResumeBlocked, privacy: .public)"
            )
            return
        }

        if working.agentStatus?.state == .running {
            logRestartPromotion(
                stage: "running.already",
                paneID: paneID,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: working
            )
            return
        }
        // Don't re-promote an idle session that came from an authoritative
        // hook signal (e.g. Codex `Stop`). The title may still show a running
        // phase for a tick or two while the tool updates it, but the hook is
        // authoritative. Note: `.explicitAPI` is excluded here because
        // codex-notify's `agent-turn-complete` can arrive stale, in which
        // case a subsequent title tick should legitimately recover running.
        if let existingStatus = working.agentStatus,
           titleIdleSuppressionIsActive(working.raw, now: now),
           existingStatus.state == .idle,
           existingStatus.hasObservedRunning,
           Self.previousMetadataCanBeStaleCodexRunningTail(previousMetadata) {
            aux = working
            stopSignalLogger.debug(
                "codex.title.running skip=withinIdleSuppressionWindow pane=\(paneID.rawValue, privacy: .public)"
            )
            return
        }

        if let existingStatus = working.agentStatus,
           existingStatus.state == .idle,
           existingStatus.hasObservedRunning,
           existingStatus.origin == .explicitHook,
           now.timeIntervalSince(existingStatus.updatedAt) <= Self.titleIdleSuppressionWindow,
           Self.previousMetadataCanBeStaleCodexRunningTail(previousMetadata) {
            stopSignalLogger.debug(
                "codex.title.running skip=explicitHookIdle pane=\(paneID.rawValue, privacy: .public)"
            )
            return
        }

        stopSignalLogger.debug(
            "codex.title.running force-inferred pane=\(paneID.rawValue, privacy: .public) preState=\(preState, privacy: .public) => running (inferred)"
        )

        let newStatus = PaneAgentStatus(
            tool: .codex,
            state: .running,
            text: nil,
            artifactLink: working.agentStatus?.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: .inferred,
            interactionKind: PaneAgentInteractionKind.none,
            confidence: .weak,
            shellActivityState: working.agentStatus?.shellActivityState ?? .unknown,
            trackedPID: working.agentStatus?.trackedPID,
            workingDirectory: working.agentStatus?.workingDirectory,
            hasObservedRunning: true,
            sessionID: working.agentStatus?.sessionID,
            parentSessionID: working.agentStatus?.parentSessionID,
            taskProgress: working.agentStatus?.taskProgress
        )
        working.agentStatus = newStatus
        // Keep the reducer in sync with the direct write so the periodic
        // sweep doesn't resurrect a stale session from before this
        // transition.
        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        aux = working
    }

    // MARK: - Diagnostics

    private func logRunningPromotionSkippedIfRelevant(
        reason: String,
        paneID: PaneID,
        recognizedTool: AgentTool?,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        auxiliaryState: PaneAuxiliaryState?
    ) {
        guard recognizedTool == .codex
            || AgentToolRecognizer.recognize(metadata: metadata) == .codex
            || AgentToolRecognizer.recognize(metadata: previousMetadata) == .codex
            || auxiliaryState?.agentStatus?.tool == .codex
            || auxiliaryState?.raw.codexInterruptSuppressionUntil != nil else {
            return
        }

        codexRestartLogger.notice(
            "running.skip reason=\(reason, privacy: .public) pane=\(paneID.rawValue, privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevProcess=\(previousMetadata?.processName ?? "<nil>", privacy: .public) process=\(metadata.processName ?? "<nil>", privacy: .public) recognized=\(recognizedTool?.displayName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(auxiliaryState?.agentStatus), privacy: .public) sessions=\(auxiliaryState?.agentReducerState.sessionsByID.count ?? -1, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(auxiliaryState?.raw), privacy: .public)"
        )
    }

    private func logRestartPromotion(
        stage: String,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        auxiliaryState: PaneAuxiliaryState
    ) {
        codexRestartLogger.notice(
            "\(stage, privacy: .public) pane=\(paneID.rawValue, privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevProcess=\(previousMetadata?.processName ?? "<nil>", privacy: .public) process=\(metadata.processName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(auxiliaryState.raw), privacy: .public)"
        )
    }

    // MARK: - Running status factory

    static func runningStatus(from existingStatus: PaneAgentStatus, now: Date) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .codex,
            state: .running,
            text: nil,
            artifactLink: existingStatus.artifactLink,
            updatedAt: now,
            source: existingStatus.source,
            origin: existingStatus.origin,
            interactionKind: .none,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            workingDirectory: existingStatus.workingDirectory,
            hasObservedRunning: true,
            sessionID: existingStatus.sessionID,
            parentSessionID: existingStatus.parentSessionID,
            taskProgress: existingStatus.taskProgress
        )
    }

    static func currentTitleIndicatesNeedsInput(_ auxiliaryState: PaneAuxiliaryState) -> Bool {
        guard let title = auxiliaryState.metadata?.title else {
            return false
        }

        if TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: title) != nil {
            return true
        }

        return TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            title,
            recognizedTool: .codex
        )?.phase == .needsInput
    }
}
