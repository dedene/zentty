import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")
private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")

/// Codex-specific title / interrupt / suppression reconciliation, extracted
/// from `WorklaneStore`'s metadata and agent-status extensions. Stateless: all
/// mutable per-pane state stays on `PaneRawState`; the resolver only reads and
/// writes the `PaneAuxiliaryState` handed to it and returns outcome flags the
/// store honors.
///
/// `now` is injected for parity with the store's clock, but every entry point
/// also threads an explicit `now` so reconciliation stays deterministic under a
/// fixed clock in tests.
@MainActor
struct CodexToolStatusResolver: PaneToolStatusResolving {
    let tool: AgentTool = .codex
    let now: @MainActor () -> Date

    // Suppress stale title ticks briefly after a ready-title-forced idle transition.
    static let titleIdleSuppressionWindow: TimeInterval = 1
    static let readyNotificationRecoveryWindow: TimeInterval = 10

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Suppression windows

    func clearExpiredTitleIdleSuppression(_ aux: inout PaneAuxiliaryState, now: Date) {
        guard let deadline = aux.raw.codexTitleIdleSuppressionUntil, now >= deadline else {
            return
        }
        aux.raw.codexTitleIdleSuppressionUntil = nil
    }

    func clearExpiredInterruptSuppression(_ aux: inout PaneAuxiliaryState, now: Date) {
        guard let deadline = aux.raw.codexInterruptSuppressionUntil, now >= deadline else {
            return
        }
        aux.raw.codexInterruptSuppressionUntil = nil
    }

    func titleIdleSuppressionIsActive(_ raw: PaneRawState, now: Date) -> Bool {
        guard let deadline = raw.codexTitleIdleSuppressionUntil else {
            return false
        }
        return now < deadline
    }

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
                let newStatus = WorklaneStore.codexRunningStatus(from: existingStatus, now: now)
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

    // MARK: - Shell-return stale-state clearing

    func clearStaleStateAfterShellReturn(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        metadata: TerminalMetadata?,
        allowsNonCodexPromptFallback: Bool
    ) -> ShellReturnOutcome {
        var working = aux

        let hasActiveCodexStatus = working.agentStatus?.tool == .codex
            && working.agentStatus?.state != .idle
        let hasActiveCodexSession = working.agentReducerState.sessionsByID.values.contains { session in
            session.tool == .codex
                && (session.state != .idle || session.interactionKind.requiresHumanAttention)
        }
        let hasCodexSuppression = working.raw.codexInterruptSuppressionUntil != nil
        guard hasActiveCodexStatus || hasActiveCodexSession || hasCodexSuppression else {
            codexRestartLogger.notice(
                "shellReturn.skip noStaleCodex pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(working.agentStatus), privacy: .public) sessions=\(working.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(working.raw), privacy: .public)"
            )
            return ShellReturnOutcome()
        }
        let shouldClear = Self.metadataIndicatesShellReturnFromCodex(metadata)
            || (
                allowsNonCodexPromptFallback
                && (
                    Self.metadataIndicatesWeakCodexFallbackEnded(
                        metadata,
                        auxiliaryState: working
                    )
                    || (
                        Self.metadataIndicatesNonCodexPrompt(metadata)
                        && (hasActiveCodexStatus || hasActiveCodexSession)
                    )
                )
            )
        guard shouldClear else {
            return ShellReturnOutcome()
        }

        codexRestartLogger.notice(
            "shellReturn.clear pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(working.agentStatus), privacy: .public) sessions=\(working.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(working.raw), privacy: .public)"
        )
        _ = working.agentReducerState.clearCodexSessionsFromUserInterrupt()
        if working.agentStatus?.tool == .codex {
            working.agentStatus = nil
        }
        working.terminalProgress = nil
        working.raw.wantsReadyStatus = false
        working.raw.showsReadyStatus = false
        working.raw.codexCurrentRunHasObservedActivity = false
        working.raw.codexInterruptSuppressionUntil = nil
        working.raw.codexTitleIdleSuppressionUntil = nil
        working.raw.codexTranscriptContext = nil
        working.raw.lastDesktopNotificationText = nil
        working.raw.lastDesktopNotificationDate = nil
        aux = working
        return ShellReturnOutcome(didClear: true, cancelPendingQuestionTasks: true)
    }

    // MARK: - Static Codex predicates

    private static func metadataIndicatesShellReturnFromCodex(_ metadata: TerminalMetadata?) -> Bool {
        guard let metadata,
              AgentToolRecognizer.recognize(metadata: metadata) != .codex else {
            return false
        }

        if let processName = WorklaneContextFormatter.trimmed(metadata.processName),
           isKnownShellName(processName) {
            return true
        }

        if let title = WorklaneContextFormatter.trimmed(metadata.title),
           isKnownShellName(title) {
            return true
        }

        return false
    }

    private static func metadataIndicatesWeakCodexFallbackEnded(
        _ metadata: TerminalMetadata?,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard metadataIndicatesNonCodexPrompt(metadata),
              let status = auxiliaryState.agentStatus,
              status.tool == .codex else {
            return false
        }

        return status.origin == .shell
            || status.source == .inferred
            || auxiliaryState.shellActivityState == .promptIdle
    }

    private static func metadataIndicatesNonCodexPrompt(_ metadata: TerminalMetadata?) -> Bool {
        guard let metadata else {
            return false
        }

        return AgentToolRecognizer.recognize(metadata: metadata) != .codex
    }

    private static func isKnownShellName(_ value: String) -> Bool {
        let basename = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        switch basename {
        case "zsh", "bash", "fish", "sh", "pwsh", "nu":
            return true
        default:
            return false
        }
    }

    private static func readyTitleMayClearStatus(_ status: PaneAgentStatus?) -> Bool {
        guard let status else {
            return true
        }

        guard status.state == .needsInput else {
            return true
        }

        return statusMayClearFromReadyTitle(status)
    }

    private static func runningTitleMayClearBlockedStatus(
        _ status: PaneAgentStatus,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind.requiresHumanAttention else {
            return false
        }

        if auxiliaryState.terminalProgress?.state.indicatesActivity == true {
            return true
        }

        switch status.origin {
        case .explicitHook, .explicitAPI:
            return status.interactionKind == .approval
                || statusIsStalePlanModePrompt(status)
        case .heuristic, .inferred, .compatibility, .shell:
            return statusIsStalePlanModePrompt(status)
        }
    }

    private static func statusShouldBlockTitleDrivenResume(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.interactionKind.requiresHumanAttention else {
            return false
        }

        return !statusIsStaleGenericNeedsInput(status)
            && !statusIsStalePlanModePrompt(status)
    }

    private static func statusIsStalePlanModePrompt(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              let text = AgentInteractionClassifier.trimmed(status.text) else {
            return false
        }

        let lowered = text.lowercased()
        guard lowered.contains("plan-mode-prompt") || lowered.contains("plan mode prompt") else {
            return false
        }

        switch status.origin {
        case .heuristic, .inferred, .compatibility, .explicitAPI:
            return true
        case .explicitHook, .shell:
            return false
        }
    }

    private static func statusIsStaleGenericNeedsInput(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind == .genericInput else {
            return false
        }

        switch status.origin {
        case .heuristic:
            return true
        case .inferred, .compatibility:
            guard let text = AgentInteractionClassifier.trimmed(status.text) else {
                return false
            }
            let lowered = text.lowercased()
            return lowered.contains("waiting for your input")
                || TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: text) != nil
                || TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: text) == .needsInput
                || TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                    text,
                    recognizedTool: .codex
                )?.phase == .needsInput
        case .explicitAPI, .explicitHook, .shell:
            return false
        }
    }

    private static func statusMayClearFromReadyTitle(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind == .genericInput else {
            return false
        }

        if statusIsStaleGenericNeedsInput(status) {
            return true
        }

        guard status.confidence == .weak else {
            return false
        }

        switch status.origin {
        case .heuristic, .inferred, .compatibility:
            return true
        case .explicitAPI, .explicitHook, .shell:
            return false
        }
    }

    private static func previousMetadataCanBeStaleCodexRunningTail(_ previousMetadata: TerminalMetadata?) -> Bool {
        guard let previousMetadata else {
            return true
        }

        return AgentToolRecognizer.recognize(metadata: previousMetadata) == .codex
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
}
