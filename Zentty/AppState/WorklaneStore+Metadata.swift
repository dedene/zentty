import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")

extension WorklaneStore {
    // Suppress stale title ticks briefly after a ready-title-forced idle transition.
    private static let codexTitleIdleSuppressionWindow: TimeInterval = 1

    func updateMetadata(paneID: PaneID, metadata: TerminalMetadata) {
        terminalDiagnostics.recordStoreMetadataUpdate(paneID: paneID)

        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        let previousAuxiliaryState = worklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
        let previousMetadata = previousAuxiliaryState.metadata
        clearExpiredCodexTitleIdleSuppression(for: paneID, in: &worklane)
        let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        let metadataChangeKind = TerminalMetadataChangeClassifier.classify(
            previous: previousMetadata,
            next: metadata
        )

        // Volatile-title fast path. When the classifier recognizes a pure
        // supported-agent title tick (phase+subject signature unchanged, only
        // elapsed time differs), skip the full promotion / inference /
        // normalization pipeline below and emit a surgical
        // `.volatileAgentTitleUpdated` for the coordinator to apply a direct
        // label update. The sidebar row and chrome focused label can read
        // `metadata.title` directly for supported realtime agent titles, so
        // storing the new metadata is enough for correct rendering.
        if metadataChangeKind == .volatileTitleOnly,
           shouldTakeVolatileAgentTitleFastPath(
                in: previousAuxiliaryState,
                nextMetadata: metadata
           ) {
            worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
            worklanes[worklaneIndex] = worklane
            emitVolatileAgentTitleUpdateIfAllowed(worklaneID: worklane.id, paneID: paneID)
            return
        }

        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        clearStaleDesktopNotificationIfNeeded(for: paneID, metadata: metadata, in: &worklane)
        clearReadyStatusForBlockedCodexTitleIfNeeded(for: paneID, metadata: metadata, in: &worklane)
        promoteCodexSessionIfTitleIndicatesNeedsInput(
            paneID: paneID,
            metadata: metadata,
            in: &worklane
        )
        if branchContextDidChange(
            previous: previousAuxiliaryState,
            nextMetadata: metadata,
            requestWorkingDirectory: requestWorkingDirectory
        ) {
            clearBranchDerivedState(for: paneID, in: &worklane)
            worklane.auxiliaryStateByPaneID[paneID]?.gitContext = nil
            invalidateCachedGitContext(
                path: PaneTerminalLocationResolver.snapshot(
                    metadata: metadata,
                    shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
                    requestWorkingDirectory: requestWorkingDirectory
                ).workingDirectory
            )
        }
        if
            let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus,
            (existingStatus.source == .inferred || existingStatus.origin == .compatibility),
            AgentToolRecognizer.recognize(metadata: metadata) == nil,
            !shouldPreserveCodexStatusContinuity(
                existingStatus: existingStatus,
                previousMetadata: previousMetadata,
                nextMetadata: metadata
            )
        {
            worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
            worklane.auxiliaryStateByPaneID[paneID]?.agentReducerState = PaneAgentReducerState()
        }
        promoteCodexSessionIfTitleIndicatesRunning(
            paneID: paneID,
            metadata: metadata,
            in: &worklane
        )
        let preTitleStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
        let preTitleTool = preTitleStatus?.tool.displayName ?? "<nil>"
        let preTitleState = preTitleStatus?.state.rawValue ?? "<nil>"
        let preTitleHasObservedRunning = preTitleStatus?.hasObservedRunning == true
        stopSignalLogger.debug(
            "metadata.update pane=\(paneID.rawValue, privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) tool=\(preTitleTool, privacy: .public) state=\(preTitleState, privacy: .public) hasObservedRunning=\(preTitleHasObservedRunning, privacy: .public)"
        )
        let codexInterrupted = surfaceReadyCodexSessionIfTitleIndicatesIdle(
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            in: &worklane
        )
        let claudeCodeInterrupted = markClaudeCodeSessionIdleIfTitleIndicatesIdle(
            paneID: paneID,
            metadata: metadata,
            in: &worklane
        )
        invalidateGitContextIfNeeded(for: paneID, in: &worklane)
        let prePresentationState = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.state.rawValue ?? "<nil>"
        stopSignalLogger.debug(
            "metadata.pre-recompute pane=\(paneID.rawValue, privacy: .public) codexInterrupted=\(codexInterrupted, privacy: .public) claudeInterrupted=\(claudeCodeInterrupted, privacy: .public) state=\(prePresentationState, privacy: .public)"
        )
        recomputePresentation(for: paneID, in: &worklane)
        if codexInterrupted || claudeCodeInterrupted {
            // A user interrupt is not a natural completion, so don't promote
            // the pane to "Agent ready". The generic running→idle bridge in
            // recomputePresentation already fired and requested ready status;
            // roll it back now that we know the transition came from Esc /
            // Esc-Esc. Natural completions drive ready status through
            // `reconcileReadyStatus` (Claude: Stop-hook grace → sweep bridge;
            // Codex: codex-notify agent-turn-complete), not via title flips.
            let wantsReadyBefore = worklane.auxiliaryStateByPaneID[paneID]?.raw.wantsReadyStatus == true
            let showsReadyBefore = worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true
            stopSignalLogger.debug(
                "metadata.clearReady pane=\(paneID.rawValue, privacy: .public) source=\(codexInterrupted ? "codex-title" : "claude-title", privacy: .public) wantsReady=\(wantsReadyBefore, privacy: .public) showsReady=\(showsReadyBefore, privacy: .public)"
            )
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        }

        if metadataChangeKind == .volatileTitleOnly,
           shouldFastPathVolatileMetadataUpdate(
                previousAuxiliaryState: previousAuxiliaryState,
                nextAuxiliaryState: worklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
           ) {
            terminalDiagnostics.recordStoreFastPath(paneID: paneID)
            worklanes[worklaneIndex] = worklane
            return
        }

        worklanes[worklaneIndex] = worklane
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: paneID)
        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        terminalDiagnostics.recordInvalidation(paneID: paneID, impacts: impacts)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
        if auxiliaryUpdateRequiresGitContextRefresh(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane) {
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: paneID))
        }
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    /// Gate for the volatile-title early fast path. Declines the fast path
    /// when the current agent state requires human attention (e.g. approval,
    /// question, auth prompts) so the reducer can re-evaluate via the full
    /// slow path. Everything else (.running, .idle, no agent status) is safe
    /// to short-circuit because the classifier already guarantees that
    /// cwd, processName, gitBranch, recognized tool, and the volatile
    /// phase+subject signature are unchanged across the tick.
    private func shouldTakeVolatileAgentTitleFastPath(
        in auxiliaryState: PaneAuxiliaryState,
        nextMetadata: TerminalMetadata
    ) -> Bool {
        if auxiliaryState.agentStatus?.interactionKind.requiresHumanAttention == true {
            return false
        }
        if let existingStatus = auxiliaryState.agentStatus,
           existingStatus.tool == .codex,
           let nextTitlePhase = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                nextMetadata.title,
                recognizedTool: .codex
           )?.phase,
           !Self.codexVolatileTitleFastPathStatusMatches(
                existingStatus: existingStatus,
                titlePhase: nextTitlePhase
           ) {
            return false
        }
        return true
    }

    private static func codexVolatileTitleFastPathStatusMatches(
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

    /// Emits a `.volatileAgentTitleUpdated` notification for realtime agent
    /// title ticks. Hidden worklanes intentionally stay realtime so the
    /// sidebar continues to feel active while background agents are working.
    private func emitVolatileAgentTitleUpdateIfAllowed(
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        terminalDiagnostics.recordStoreFastPath(paneID: paneID)
        notify(.volatileAgentTitleUpdated(worklaneID: worklaneID, paneID: paneID))
    }

    func clearPaneState(for paneID: PaneID, in worklane: inout WorklaneState) {
        worklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
    }

    func clearStatusDerivedState(for paneID: PaneID, in worklane: inout WorklaneState) {
        worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
    }

    func clearBranchDerivedState(for paneID: PaneID, in worklane: inout WorklaneState) {
        worklane.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        if var status = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus, status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = status
        }
    }

    private func clearReadyStatusForBlockedCodexTitleIfNeeded(
        for paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.raw.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex else {
            return
        }

        let waitingTitleKind = TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title)
        let titleNeedsInput = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        )?.phase == .needsInput
        guard waitingTitleKind != nil || titleNeedsInput else {
            return
        }

        clearReadyStatusIfNeeded(for: paneID, in: &worklane)
    }

    private func promoteCodexSessionIfTitleIndicatesNeedsInput(
        paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard
            recognizedTool == .codex,
            TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title) == .needsInput,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
        else {
            return
        }

        if auxiliaryState.agentStatus?.state == .needsInput {
            return
        }

        let existingStatus = auxiliaryState.agentStatus
        let titleText = AgentInteractionClassifier.trimmed(metadata.title)
        let interactionKind = AgentInteractionClassifier.interactionKind(forWaitingMessage: titleText)
            ?? .genericInput
        auxiliaryState.agentStatus = PaneAgentStatus(
            tool: .codex,
            state: .needsInput,
            text: titleText ?? existingStatus?.text,
            artifactLink: existingStatus?.artifactLink,
            updatedAt: Date(),
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
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func promoteCodexSessionIfTitleIndicatesRunning(
        paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard
            recognizedTool == .codex,
            let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: recognizedTool
            ),
            signature.phase == .running,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
        else {
            return
        }

        if let existingStatus = auxiliaryState.agentStatus,
           existingStatus.interactionKind.requiresHumanAttention,
           existingStatus.interactionKind != .genericInput {
            return
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        let now = Date()
        let preState = auxiliaryState.agentStatus?.state.rawValue ?? "<nil>"
        let didPromoteStarting = auxiliaryState.agentReducerState.promoteExplicitStartingSessionToRunning(now: now)
        let didResumeBlocked = auxiliaryState.agentReducerState.resumeBlockedSessionFromActivity(now: now)

        if didPromoteStarting || didResumeBlocked {
            auxiliaryState.agentStatus = Self.hydratedStatus(
                auxiliaryState.agentReducerState.reducedStatus(),
                existingStatus: auxiliaryState.agentStatus
            )
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            stopSignalLogger.debug(
                "codex.title.running reducer-promote pane=\(paneID.rawValue, privacy: .public) preState=\(preState, privacy: .public) didPromoteStarting=\(didPromoteStarting, privacy: .public) didResumeBlocked=\(didResumeBlocked, privacy: .public)"
            )
            return
        }

        if auxiliaryState.agentStatus?.state == .running {
            return
        }
        // Don't re-promote an idle session that came from an authoritative
        // hook signal (e.g. Codex `Stop`). The title may still show a running
        // phase for a tick or two while the tool updates it, but the hook is
        // authoritative. Note: `.explicitAPI` is excluded here because
        // codex-notify's `agent-turn-complete` can arrive stale, in which
        // case a subsequent title tick should legitimately recover running.
        if let existingStatus = auxiliaryState.agentStatus,
           codexTitleIdleSuppressionIsActive(auxiliaryState.raw, now: now),
           existingStatus.state == .idle,
           existingStatus.hasObservedRunning {
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            stopSignalLogger.debug(
                "codex.title.running skip=withinIdleSuppressionWindow pane=\(paneID.rawValue, privacy: .public)"
            )
            return
        }

        if let existingStatus = auxiliaryState.agentStatus,
           existingStatus.state == .idle,
           existingStatus.hasObservedRunning,
           existingStatus.origin == .explicitHook {
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
            artifactLink: auxiliaryState.agentStatus?.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: .inferred,
            interactionKind: PaneAgentInteractionKind.none,
            confidence: .weak,
            shellActivityState: auxiliaryState.agentStatus?.shellActivityState ?? .unknown,
            trackedPID: auxiliaryState.agentStatus?.trackedPID,
            workingDirectory: auxiliaryState.agentStatus?.workingDirectory,
            hasObservedRunning: true,
            sessionID: auxiliaryState.agentStatus?.sessionID,
            parentSessionID: auxiliaryState.agentStatus?.parentSessionID,
            taskProgress: auxiliaryState.agentStatus?.taskProgress
        )
        auxiliaryState.agentStatus = newStatus
        // Keep the reducer in sync with the direct write so the periodic
        // sweep doesn't resurrect a stale session from before this
        // transition.
        auxiliaryState.agentReducerState = Self.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func shouldPreserveCodexStatusContinuity(
        existingStatus: PaneAgentStatus,
        previousMetadata: TerminalMetadata?,
        nextMetadata: TerminalMetadata
    ) -> Bool {
        guard existingStatus.tool == .codex, existingStatus.hasObservedRunning else {
            return false
        }

        let nextTitlePhase = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            nextMetadata.title,
            recognizedTool: .codex
        )?.phase
        if nextTitlePhase == .idle {
            return true
        }

        let previousTitlePhase = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: .codex
        )?.phase
        return previousTitlePhase == .running || previousTitlePhase == .starting
    }

    /// Returns `true` when the title flip drove a fresh running→idle
    /// transition. The caller uses that signal to clear ready status on the
    /// interrupt path (Esc twice) — natural completions flow through
    /// codex-notify (`agent-turn-complete`) and reach ready via
    /// `reconcileReadyStatus` instead of the terminal title.
    @discardableResult
    private func surfaceReadyCodexSessionIfTitleIndicatesIdle(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) -> Bool {
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title) != .backgroundWait else {
            stopSignalLogger.debug("codex.title.idle skip=backgroundWait pane=\(paneID.rawValue, privacy: .public)")
            return false
        }
        guard
            recognizedTool == .codex,
            let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: recognizedTool
            ),
            signature.phase == .idle,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            Self.codexReadyTitleMayClearStatus(auxiliaryState.agentStatus)
        else {
            return false
        }
        let previousSignature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: recognizedTool
        )
        guard previousSignature?.phase != .idle else {
            stopSignalLogger.debug("codex.title.idle skip=alreadyIdleTitle pane=\(paneID.rawValue, privacy: .public)")
            return false
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        let now = Date()
        let preExistingStatus = auxiliaryState.agentStatus
        if auxiliaryState.agentReducerState.markExplicitCodexSessionIdleFromReadyTitle(now: now) {
            let reducedStatus = Self.hydratedStatus(
                auxiliaryState.agentReducerState.reducedStatus(),
                existingStatus: auxiliaryState.agentStatus
            )
            guard let reducedStatus,
                  reducedStatus.tool == .codex,
                  reducedStatus.source == .explicit,
                  reducedStatus.state == .idle,
                  reducedStatus.hasObservedRunning
            else {
                stopSignalLogger.debug("codex.title.idle firstBranch reducer-gated pane=\(paneID.rawValue, privacy: .public) prevState=\(preExistingStatus?.state.rawValue ?? "<nil>", privacy: .public) source=\(reducedStatus?.source == .explicit ? "explicit" : "other", privacy: .public)")
                return false
            }

            auxiliaryState.agentStatus = reducedStatus
            auxiliaryState.raw.codexTitleIdleSuppressionUntil = now.addingTimeInterval(Self.codexTitleIdleSuppressionWindow)
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            stopSignalLogger.debug(
                "codex.title.idle firstBranch applied pane=\(paneID.rawValue, privacy: .public) prevState=\(preExistingStatus?.state.rawValue ?? "<nil>", privacy: .public) => idle (interrupt candidate, caller will clear ready; suppression window set)"
            )
            return true
        }

        guard let existingStatus = auxiliaryState.agentStatus,
              existingStatus.tool == .codex,
              (
                (
                    existingStatus.hasObservedRunning
                    && (
                        existingStatus.state == .running
                        || existingStatus.state == .idle
                    )
                )
                || Self.codexReadyTitleRecoversGenericNeedsInput(existingStatus)
              )
        else {
            stopSignalLogger.debug("codex.title.idle fallback skip pane=\(paneID.rawValue, privacy: .public) state=\(auxiliaryState.agentStatus?.state.rawValue ?? "<nil>", privacy: .public)")
            return false
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
        auxiliaryState.agentStatus = newStatus
        // Re-seed the reducer from the new idle status so the periodic
        // `clearStaleAgentSessions` sweep (which trusts `reducedStatus()` as
        // the source of truth) doesn't resurrect the previous running
        // session and clobber this direct write.
        auxiliaryState.agentReducerState = Self.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        // The fallback branch handles inferred sessions (no explicit hook /
        // API channel, so no notify to trust) and already-idle sessions
        // (codex-notify already landed). In both cases we still need the
        // title-based ready promotion: inferred sessions have no other
        // completion signal, and for already-idle sessions the call is a
        // no-op since reconcileReadyStatus already surfaced ready.
        stopSignalLogger.debug(
            "codex.title.idle fallback applied pane=\(paneID.rawValue, privacy: .public) prevState=\(existingStatus.state.rawValue, privacy: .public) source=\(existingStatus.source == .explicit ? "explicit" : "inferred", privacy: .public) origin=\(existingStatus.origin.rawValue, privacy: .public) => idle (reducer re-seeded, requesting ready)"
        )
        requestReadyStatusIfNeeded(for: paneID, in: &worklane)
        return false
    }

    private func clearExpiredCodexTitleIdleSuppression(
        for paneID: PaneID,
        in worklane: inout WorklaneState,
        now: Date = Date()
    ) {
        guard let deadline = worklane.auxiliaryStateByPaneID[paneID]?.raw.codexTitleIdleSuppressionUntil,
              now >= deadline else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexTitleIdleSuppressionUntil = nil
    }

    private func codexTitleIdleSuppressionIsActive(
        _ raw: PaneRawState,
        now: Date = Date()
    ) -> Bool {
        guard let deadline = raw.codexTitleIdleSuppressionUntil else {
            return false
        }

        return now < deadline
    }

    private static func codexReadyTitleMayClearStatus(_ status: PaneAgentStatus?) -> Bool {
        guard let status else {
            return true
        }

        guard status.state == .needsInput else {
            return true
        }

        return codexReadyTitleClearsGenericNeedsInput(status)
    }

    private static func codexReadyTitleClearsGenericNeedsInput(_ status: PaneAgentStatus) -> Bool {
        status.tool == .codex
            && status.state == .needsInput
            && status.interactionKind == .genericInput
    }

    private static func codexReadyTitleRecoversGenericNeedsInput(_ status: PaneAgentStatus) -> Bool {
        codexReadyTitleClearsGenericNeedsInput(status)
            && (status.hasObservedRunning || status.origin == .heuristic)
    }

    /// When a Claude Code session is running but the terminal title transitions
    /// to an idle-phase indicator (glyph ✳ on current builds, or the legacy
    /// words "interrupted", "ready", "waiting"), force-resolve the underlying
    /// session state to idle. This catches Ctrl-C / Escape interruptions where
    /// the Stop hook does not fire.
    ///
    /// Returns `true` when the session was transitioned via this path, so the
    /// caller can distinguish a user interrupt from a natural completion and
    /// suppress the "Agent ready" label.
    @discardableResult
    private func markClaudeCodeSessionIdleIfTitleIndicatesIdle(
        paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) -> Bool {
        guard
            let signature = TerminalMetadataChangeClassifier.diagnosticAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: .claudeCode
            ),
            signature.phase == .idle,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            let existingStatus = auxiliaryState.agentStatus,
            existingStatus.tool == .claudeCode,
            existingStatus.hasObservedRunning,
            existingStatus.state == .running || existingStatus.state == .starting
        else {
            return false
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: existingStatus
        )
        guard auxiliaryState.agentReducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: Date()) else {
            return false
        }

        auxiliaryState.agentStatus = Self.hydratedStatus(
            auxiliaryState.agentReducerState.reducedStatus(),
            existingStatus: existingStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        return true
    }

    /// Clears stale desktop notification text when a Codex terminal title transitions to
    /// an active state (Working/Thinking/Starting), preventing old notification text from
    /// surfacing in the sidebar during a new work cycle.
    private func clearStaleDesktopNotificationIfNeeded(
        for paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        guard worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationText != nil else {
            return
        }
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.raw.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex else {
            return
        }
        if let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        ),
           signature.phase == .running || signature.phase == .starting {
            worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationText = nil
            worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationDate = nil
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
    }

    private func branchContextDidChange(
        previous: PaneAuxiliaryState,
        nextMetadata: TerminalMetadata,
        requestWorkingDirectory: String?
    ) -> Bool {
        if PaneTerminalLocationResolver.snapshot(
            metadata: previous.metadata,
            shellContext: previous.shellContext,
            requestWorkingDirectory: requestWorkingDirectory
        ).workingDirectory
            != PaneTerminalLocationResolver.snapshot(
                metadata: nextMetadata,
                shellContext: previous.shellContext,
                requestWorkingDirectory: requestWorkingDirectory
            ).workingDirectory {
            return true
        }

        return WorklaneContextFormatter.displayBranch(previous.metadata?.gitBranch)
            != WorklaneContextFormatter.displayBranch(nextMetadata.gitBranch)
    }

    private func shouldFastPathVolatileMetadataUpdate(
        previousAuxiliaryState: PaneAuxiliaryState,
        nextAuxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        if sidebarVisibleVolatileTitle(for: previousAuxiliaryState)
            != sidebarVisibleVolatileTitle(for: nextAuxiliaryState) {
            return false
        }

        return previousAuxiliaryState.presentation == nextAuxiliaryState.presentation
            && previousAuxiliaryState.shellContext?.scope == nextAuxiliaryState.shellContext?.scope
            && gitContextRefreshHint(for: previousAuxiliaryState) == gitContextRefreshHint(for: nextAuxiliaryState)
    }

    private func sidebarVisibleVolatileTitle(for auxiliaryState: PaneAuxiliaryState) -> String? {
        guard let recognizedTool = auxiliaryState.presentation.recognizedTool,
              let volatileTitle = WorklaneContextFormatter.trimmed(auxiliaryState.metadata?.title),
              TerminalMetadataChangeClassifier.isRealtimeAgentStatusTitle(
                  volatileTitle,
                  recognizedTool: recognizedTool
              ) else {
            return nil
        }

        return volatileTitle
    }

    func auxiliaryInvalidation(
        for paneID: PaneID,
        previousWorklane: WorklaneState,
        nextWorklane: WorklaneState
    ) -> WorklaneAuxiliaryInvalidation {
        let previousAuxiliaryState = previousWorklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
        let nextAuxiliaryState = nextWorklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
        var impacts = WorklaneAuxiliaryInvalidation()
        let isActiveWorklane = nextWorklane.id == activeWorklaneID

        if WorklaneSidebarSummaryBuilder.summary(for: previousWorklane, isActive: isActiveWorklane)
            != WorklaneSidebarSummaryBuilder.summary(for: nextWorklane, isActive: isActiveWorklane) {
            impacts.insert(.sidebar)
        }

        if isActiveWorklane,
           WorklaneHeaderSummaryBuilder.summary(for: previousWorklane)
            != WorklaneHeaderSummaryBuilder.summary(for: nextWorklane) {
            impacts.insert(.header)
        }

        if WorklaneAttentionSummaryBuilder.summary(for: previousWorklane)
            != WorklaneAttentionSummaryBuilder.summary(for: nextWorklane) {
            impacts.insert(.attention)
        }

        if previousWorklane.paneBorderContextDisplayByPaneID[paneID] != nextWorklane.paneBorderContextDisplayByPaneID[paneID] {
            impacts.insert(.canvas)
        }

        if activeFocusedOpenWithContext(in: previousWorklane) != activeFocusedOpenWithContext(in: nextWorklane) {
            impacts.insert(.openWith)
        }

        if previousAuxiliaryState.presentation.prLookupKey != nextAuxiliaryState.presentation.prLookupKey {
            impacts.insert(.reviewRefresh)
        }

        return impacts
    }

    func auxiliaryUpdateRequiresGitContextRefresh(
        for paneID: PaneID,
        previousWorklane: WorklaneState,
        nextWorklane: WorklaneState
    ) -> Bool {
        let previousAuxiliaryState = previousWorklane.auxiliaryStateByPaneID[paneID]
        let nextAuxiliaryState = nextWorklane.auxiliaryStateByPaneID[paneID]

        return localReviewWorkingDirectory(for: paneID, in: previousWorklane)
            != localReviewWorkingDirectory(for: paneID, in: nextWorklane)
            || previousAuxiliaryState?.shellContext?.scope != nextAuxiliaryState?.shellContext?.scope
            || gitContextRefreshHint(for: previousAuxiliaryState) != gitContextRefreshHint(for: nextAuxiliaryState)
    }

    func updateGitContext(paneID: PaneID, gitContext: PaneGitContext?) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        let previousLookupKey = worklane.auxiliaryStateByPaneID[paneID]?.presentation.prLookupKey
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].gitContext = gitContext
        recomputePresentation(for: paneID, in: &worklane)
        let nextLookupKey = worklane.auxiliaryStateByPaneID[paneID]?.presentation.prLookupKey
        if previousLookupKey != nextLookupKey {
            clearBranchDerivedState(for: paneID, in: &worklane)
            worklane.auxiliaryStateByPaneID[paneID]?.gitContext = gitContext
            recomputePresentation(for: paneID, in: &worklane)
        }

        worklanes[worklaneIndex] = worklane
        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
    }

    func recomputePresentation(for paneID: PaneID, in worklane: inout WorklaneState) {
        guard let pane = worklane.paneStripState.panes.first(where: { $0.id == paneID }) else {
            return
        }

        clearExpiredCodexTitleIdleSuppression(for: paneID, in: &worklane)
        let previousPresentation = worklane.auxiliaryStateByPaneID[paneID]?.presentation
        let raw = worklane.auxiliaryStateByPaneID[paneID]?.raw ?? PaneRawState()
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: raw,
            previous: previousPresentation,
            sessionRequestWorkingDirectory: pane.sessionRequest.inheritFromPaneID == nil
                ? pane.sessionRequest.workingDirectory
                : nil
        )
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].presentation = presentation

        // Bridge: when the presentation phase resolves to an active state
        // (.running, .needsInput) but the raw agentStatus hasn't recorded
        // that it was ever running, propagate the observation. This closes
        // the gap for agents like Copilot where "running" is derived from
        // OSC progress at the presentation layer, not from hook events.
        if presentation.isWorking,
           worklane.auxiliaryStateByPaneID[paneID]?.agentStatus != nil,
           worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.hasObservedRunning == false {
            worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.hasObservedRunning = true
        }

        // Bridge: when the presentation phase transitions from actively
        // working to idle, request the "agent ready" indicator. This lets
        // agents whose running state is presentation-derived (Copilot via
        // OSC, generic agents via terminal progress) show ready status on
        // completion — not just agents with explicit hook-driven running
        // states like Claude Code.
        if previousPresentation?.isWorking == true,
           presentation.runtimePhase == .idle,
           worklane.auxiliaryStateByPaneID[paneID]?.agentStatus != nil,
           !codexTitleIdleSuppressionIsActive(raw) {
            let bridgePrevPhase = previousPresentation?.runtimePhase.rawValue ?? "<nil>"
            let bridgeTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool.displayName ?? "<nil>"
            stopSignalLogger.debug(
                "recompute.bridge.working->idle pane=\(paneID.rawValue, privacy: .public) prevPhase=\(bridgePrevPhase, privacy: .public) tool=\(bridgeTool, privacy: .public) => requestReady"
            )
            requestReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
    }

    func invalidateGitContextIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let currentWorkingDirectory = localReviewWorkingDirectory(for: paneID, in: worklane)
        if worklane.auxiliaryStateByPaneID[paneID]?.gitContext?.workingDirectory != currentWorkingDirectory {
            worklane.auxiliaryStateByPaneID[paneID]?.gitContext = nil
        }
    }

    func refreshGitContextIfNeeded(for paneReference: PaneReference) {
        guard
            let worklaneIndex = worklanes.firstIndex(where: { $0.id == paneReference.worklaneID }),
            worklanes[worklaneIndex].paneStripState.panes.contains(where: { $0.id == paneReference.paneID })
        else {
            return
        }

        let auxiliaryState = worklanes[worklaneIndex].auxiliaryStateByPaneID[paneReference.paneID]
        if auxiliaryState?.shellContext?.scope == .remote {
            updateGitContext(paneID: paneReference.paneID, gitContext: nil)
            return
        }

        guard let workingDirectory = localReviewWorkingDirectory(for: paneReference.paneID, in: worklanes[worklaneIndex]) else {
            updateGitContext(paneID: paneReference.paneID, gitContext: nil)
            return
        }

        let shellBranchHint = WorklaneContextFormatter.displayBranch(auxiliaryState?.shellContext?.gitBranch)

        if let cached = cachedGitContextByPath[workingDirectory],
           cachedGitContext(cached, matches: shellBranchHint) {
            updateGitContext(paneID: paneReference.paneID, gitContext: cached)
            return
        }
        cachedGitContextByPath.removeValue(forKey: workingDirectory)

        if knownNonRepositoryPaths.contains(workingDirectory) {
            if shellBranchHint != nil {
                knownNonRepositoryPaths.remove(workingDirectory)
            } else {
            updateGitContext(paneID: paneReference.paneID, gitContext: nil)
            return
            }
        }

        waitingPaneReferencesByPath[workingDirectory, default: []].insert(paneReference)
        guard pendingGitContextPaths.insert(workingDirectory).inserted else {
            return
        }

        let resolver = gitContextResolver
        Task { [weak self] in
            let gitContext = await resolver.resolve(for: workingDirectory)
            await MainActor.run {
                self?.applyResolvedGitContext(
                    gitContext.repoRoot == nil ? nil : gitContext,
                    forWorkingDirectory: workingDirectory
                )
            }
        }
    }

    private func applyResolvedGitContext(
        _ gitContext: PaneGitContext?,
        forWorkingDirectory workingDirectory: String
    ) {
        pendingGitContextPaths.remove(workingDirectory)
        let paneReferences = waitingPaneReferencesByPath.removeValue(forKey: workingDirectory) ?? []

        if let gitContext {
            cachedGitContextByPath[workingDirectory] = gitContext
            knownNonRepositoryPaths.remove(workingDirectory)
        } else {
            cachedGitContextByPath.removeValue(forKey: workingDirectory)
            knownNonRepositoryPaths.insert(workingDirectory)
        }

        for paneReference in paneReferences {
            guard
                let worklaneIndex = worklanes.firstIndex(where: { $0.id == paneReference.worklaneID }),
                worklanes[worklaneIndex].paneStripState.panes.contains(where: { $0.id == paneReference.paneID })
            else {
                continue
            }

            let currentWorkingDirectory = localReviewWorkingDirectory(
                for: paneReference.paneID,
                in: worklanes[worklaneIndex]
            )
            guard currentWorkingDirectory == workingDirectory else {
                refreshGitContextIfNeeded(for: paneReference)
                continue
            }

            updateGitContext(paneID: paneReference.paneID, gitContext: gitContext)
        }
    }

    private func cachedGitContext(
        _ gitContext: PaneGitContext,
        matches shellBranchHint: String?
    ) -> Bool {
        guard let shellBranchHint else {
            return WorklaneContextFormatter.trimmed(gitContext.branchDisplayText) == nil
                || gitContext.branchName == nil
                || WorklaneContextFormatter.displayBranch(gitContext.branchName) == nil
        }

        return WorklaneContextFormatter.displayBranch(gitContext.branchName) == shellBranchHint
    }

    func activeFocusedOpenWithContext(in worklane: WorklaneState) -> WorklaneOpenWithContext? {
        guard worklane.id == activeWorklaneID else {
            return nil
        }

        return focusedOpenWithContext(in: worklane)
    }

    private func gitContextRefreshHint(for auxiliaryState: PaneAuxiliaryState?) -> String? {
        WorklaneContextFormatter.displayBranch(auxiliaryState?.shellContext?.gitBranch)
            ?? WorklaneContextFormatter.displayBranch(auxiliaryState?.metadata?.gitBranch)
    }
}
