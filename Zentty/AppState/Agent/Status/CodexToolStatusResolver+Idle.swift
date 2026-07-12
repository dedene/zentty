import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")

/// Ready/idle-title Codex reconciliation: recovering a needs-input state
/// from a ready title landing within the notification-recovery window, and
/// surfacing ready status when an idle title lands. Split out of
/// `CodexToolStatusResolver.swift` along its MARK sections.
extension CodexToolStatusResolver {
    // MARK: - Ready-title → needs-input recovery

    /// Recovers a Codex `needsInput` state when a ready/idle title lands within
    /// the notification recovery window. Returns `didChangeStatus` and whether
    /// the store should clear ready status.
    func recoverNeedsInputFromReadyTitle(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        now: Date
    ) -> TitleReconcileOutcome {
        let recognizedTool = aux.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard
            recognizedTool == .codex,
            let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: recognizedTool
            ),
            signature.phase == .idle,
            !aux.raw.codexInterruptSuppressionIsActive(),
            let existingStatus = aux.agentStatus,
            existingStatus.tool == .codex,
            existingStatus.source == .explicit,
            existingStatus.hasObservedRunning,
            existingStatus.state == .running || existingStatus.state == .starting,
            let notificationText = AgentInteractionClassifier.trimmed(aux.raw.lastDesktopNotificationText),
            let notificationDate = aux.raw.lastDesktopNotificationDate
        else {
            return TitleReconcileOutcome()
        }

        if TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: recognizedTool
        )?.phase == .idle {
            return TitleReconcileOutcome()
        }

        guard now.timeIntervalSince(notificationDate) <= Self.readyNotificationRecoveryWindow,
              let interactionKind = AgentInteractionClassifier.interactionKind(forWaitingMessage: notificationText),
              interactionKind != .genericInput else {
            return TitleReconcileOutcome()
        }

        let newStatus = PaneAgentStatus(
            tool: .codex,
            state: .needsInput,
            text: notificationText,
            artifactLink: existingStatus.artifactLink,
            updatedAt: now,
            source: existingStatus.source,
            origin: .heuristic,
            interactionKind: interactionKind,
            confidence: .strong,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            workingDirectory: existingStatus.workingDirectory,
            hasObservedRunning: true,
            sessionID: existingStatus.sessionID,
            parentSessionID: existingStatus.parentSessionID,
            taskProgress: existingStatus.taskProgress
        )
        aux.agentStatus = newStatus
        aux.agentReducerState = AgentStatusReconciliation.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        stopSignalLogger.debug(
            "codex.title.ready recoverNeedsInput pane=\(paneID.rawValue, privacy: .public) interaction=\(interactionKind.rawValue, privacy: .public) notification=\(notificationText, privacy: .public)"
        )
        return TitleReconcileOutcome(didChangeStatus: true, clearReadyStatus: true)
    }

    // MARK: - Idle-title ready surfacing

    /// Surfaces ready status when a Codex idle title lands. `suppressReadyAfterRecompute`
    /// is set when the transition looks like a user interrupt (caller clears
    /// ready after recompute); `requestReadyReveal` is set on the fallback
    /// natural-completion branch.
    func surfaceReadyFromIdleTitle(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        readyPromotionAllowed: Bool,
        now: Date
    ) -> TitleReconcileOutcome {
        let recognizedTool = aux.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title) != .backgroundWait else {
            stopSignalLogger.debug("codex.title.idle skip=backgroundWait pane=\(paneID.rawValue, privacy: .public)")
            return TitleReconcileOutcome()
        }
        guard
            recognizedTool == .codex,
            let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: recognizedTool
            ),
            signature.phase == .idle,
            !aux.raw.codexInterruptSuppressionIsActive(),
            Self.readyTitleMayClearStatus(aux.agentStatus)
        else {
            return TitleReconcileOutcome()
        }
        let previousSignature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: recognizedTool
        )
        guard previousSignature?.phase != .idle else {
            stopSignalLogger.debug("codex.title.idle skip=alreadyIdleTitle pane=\(paneID.rawValue, privacy: .public)")
            return TitleReconcileOutcome()
        }

        var working = aux
        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            working.agentReducerState,
            from: working.agentStatus
        )
        let preExistingStatus = working.agentStatus
        if working.agentReducerState.markExplicitCodexSessionIdleFromReadyTitle(now: now) {
            guard readyPromotionAllowed else {
                stopSignalLogger.debug("codex.title.idle firstBranch skip=noCurrentRunEvidence pane=\(paneID.rawValue, privacy: .public)")
                return TitleReconcileOutcome()
            }
            let reducedStatus = AgentStatusReconciliation.hydratedStatus(
                working.agentReducerState.reducedStatus(),
                existingStatus: working.agentStatus
            )
            guard let reducedStatus,
                  reducedStatus.tool == .codex,
                  reducedStatus.source == .explicit,
                  reducedStatus.state == .idle,
                  reducedStatus.hasObservedRunning
            else {
                stopSignalLogger.debug("codex.title.idle firstBranch reducer-gated pane=\(paneID.rawValue, privacy: .public) prevState=\(preExistingStatus?.state.rawValue ?? "<nil>", privacy: .public) source=\(reducedStatus?.source == .explicit ? "explicit" : "other", privacy: .public)")
                return TitleReconcileOutcome()
            }

            working.agentStatus = reducedStatus
            working.raw.codexTitleIdleSuppressionUntil = now.addingTimeInterval(Self.titleIdleSuppressionWindow)
            aux = working
            stopSignalLogger.debug(
                "codex.title.idle firstBranch applied pane=\(paneID.rawValue, privacy: .public) prevState=\(preExistingStatus?.state.rawValue ?? "<nil>", privacy: .public) => idle (interrupt candidate, caller will clear ready; suppression window set)"
            )
            return TitleReconcileOutcome(didChangeStatus: true, suppressReadyAfterRecompute: true)
        }

        guard let existingStatus = working.agentStatus,
              existingStatus.tool == .codex,
              readyPromotionAllowed,
              (
                (
                    existingStatus.hasObservedRunning
                    && (
                        existingStatus.state == .running
                        || existingStatus.state == .idle
                    )
                )
                || Self.statusMayClearFromReadyTitle(existingStatus)
              )
        else {
            stopSignalLogger.debug("codex.title.idle fallback skip pane=\(paneID.rawValue, privacy: .public) state=\(working.agentStatus?.state.rawValue ?? "<nil>", privacy: .public)")
            return TitleReconcileOutcome()
        }

        let newStatus = PaneAgentStatus(
            tool: .codex,
            state: .idle,
            text: nil,
            artifactLink: existingStatus.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: existingStatus.origin == .explicitAPI || existingStatus.origin == .explicitHook ? existingStatus.origin : .inferred,
            interactionKind: PaneAgentInteractionKind.none,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            workingDirectory: existingStatus.workingDirectory,
            hasObservedRunning: true,
            sessionID: existingStatus.sessionID,
            parentSessionID: existingStatus.parentSessionID,
            taskProgress: existingStatus.taskProgress
        )
        working.agentStatus = newStatus
        // Re-seed the reducer from the new idle status so the periodic
        // `clearStaleAgentSessions` sweep (which trusts `reducedStatus()` as
        // the source of truth) doesn't resurrect the previous running
        // session and clobber this direct write.
        working.agentReducerState = AgentStatusReconciliation.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        aux = working
        // The fallback branch handles inferred sessions (no explicit hook /
        // API channel, so no notify to trust) and already-idle sessions
        // (codex-notify already landed). In both cases we still need the
        // title-based ready promotion: inferred sessions have no other
        // completion signal, and for already-idle sessions the call is a
        // no-op since reconcileReadyStatus already surfaced ready.
        stopSignalLogger.debug(
            "codex.title.idle fallback applied pane=\(paneID.rawValue, privacy: .public) prevState=\(existingStatus.state.rawValue, privacy: .public) source=\(existingStatus.source == .explicit ? "explicit" : "inferred", privacy: .public) origin=\(existingStatus.origin.rawValue, privacy: .public) => idle (reducer re-seeded, requesting ready)"
        )
        return TitleReconcileOutcome(requestReadyReveal: true)
    }
}
