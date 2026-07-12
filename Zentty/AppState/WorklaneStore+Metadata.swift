import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")
private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")

extension WorklaneStore {
    // Suppress stale title ticks briefly after a ready-title-forced idle transition.
    private static let codexTitleIdleSuppressionWindow: TimeInterval = 1
    private static let codexReadyNotificationRecoveryWindow: TimeInterval = 10
    private static let codexQuestionRetryDelayNanoseconds: [UInt64] = [
        0,
        100_000_000,
        200_000_000,
        400_000_000,
        600_000_000
    ]

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
        clearExpiredCodexInterruptSuppression(for: paneID, in: &worklane)
        let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        let metadataChangeKind = TerminalMetadataChangeClassifier.classify(
            previous: previousMetadata,
            next: metadata
        )
        logCodexRestartMetadataUpdate(
            stage: "metadata.begin",
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            metadataChangeKind: metadataChangeKind,
            auxiliaryState: previousAuxiliaryState
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
            logCodexRestartMetadataUpdate(
                stage: "metadata.fastPath",
                paneID: paneID,
                previousMetadata: previousMetadata,
                metadata: metadata,
                metadataChangeKind: metadataChangeKind,
                auxiliaryState: previousAuxiliaryState
            )
            worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
            worklanes[worklaneIndex] = worklane
            emitVolatileAgentTitleUpdateIfAllowed(worklaneID: worklane.id, paneID: paneID)
            return
        }

        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        if Self.metadataIndicatesCodexCurrentRunActivity(metadata) {
            markCodexCurrentRunActivityIfNeeded(for: paneID, in: &worklane)
        }
        clearStaleCodexStateAfterShellReturnIfNeeded(
            paneID: paneID,
            metadata: metadata,
            allowsNonCodexPromptFallback: false,
            in: &worklane
        )
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
            previousMetadata: previousMetadata,
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
        let codexRecoveredNeedsInput = promoteCodexSessionIfReadyTitleRecoversNeedsInput(
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            in: &worklane
        )
        let codexInterrupted = codexRecoveredNeedsInput
            ? false
            : surfaceReadyCodexSessionIfTitleIndicatesIdle(
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
        if let auxiliaryState = worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID] {
            scheduleCodexQuestionEnrichmentIfPossible(
                worklaneID: worklane.id,
                paneID: paneID,
                auxiliaryState: auxiliaryState
            )
        }
        if auxiliaryUpdateRequiresGitContextRefresh(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane) {
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: paneID))
        }
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    func updateForegroundSSHDestination(
        paneID: PaneID,
        destination: SSHDestination?
    ) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
        guard auxiliaryState.raw.foregroundSSHDestination != destination else {
            return
        }

        auxiliaryState.raw.foregroundSSHDestination = destination
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        recomputePresentation(for: paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane

        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
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
        codexResolver.shouldTakeVolatileTitleFastPath(
            in: auxiliaryState,
            nextMetadata: nextMetadata
        )
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
        guard let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }
        guard codexResolver.blockedTitleRequiresReadyClear(
            in: auxiliaryState,
            metadata: metadata
        ) else {
            return
        }

        clearReadyStatusIfNeeded(for: paneID, in: &worklane)
    }

    private func promoteCodexSessionIfTitleIndicatesNeedsInput(
        paneID: PaneID,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }
        if codexResolver.promoteTitleNeedsInput(
            &auxiliaryState,
            metadata: metadata,
            now: Date()
        ) {
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        }
    }

    func scheduleCodexQuestionEnrichmentIfPossible(
        worklaneID: WorklaneID,
        paneID: PaneID,
        auxiliaryState: PaneAuxiliaryState
    ) {
        guard auxiliaryState.agentStatus?.tool == .codex,
              auxiliaryState.agentStatus?.state == .needsInput,
              Self.codexQuestionEnrichmentIsEligible(auxiliaryState.agentStatus),
              let context = codexTranscriptContextForQuestionEnrichment(
                  worklaneID: worklaneID,
                  paneID: paneID,
                  auxiliaryState: auxiliaryState
              ),
              let transcriptPath = WorklaneContextFormatter.trimmed(context.path) else {
            return
        }

        let request = CodexTranscriptQuestionRequest(
            sessionID: WorklaneContextFormatter.trimmed(auxiliaryState.agentStatus?.sessionID)
                ?? WorklaneContextFormatter.trimmed(context.sessionID),
            transcriptPath: transcriptPath
        )
        let paneReference = PaneReference(worklaneID: worklaneID, paneID: paneID)
        if pendingCodexQuestionRequests[paneReference] == request {
            return
        }

        let cacheKey = CodexTranscriptQuestionExtractor.cacheKey(forTranscriptPath: transcriptPath)
        if let cacheKey,
           let cachedQuestion = cachedCodexTranscriptQuestions[cacheKey] {
            applyCodexTranscriptQuestion(cachedQuestion, request: request, paneReference: paneReference)
            return
        }

        pendingCodexQuestionTasks[paneReference]?.cancel()
        pendingCodexQuestionRequests[paneReference] = request
        let resolver = codexQuestionResolver
        pendingCodexQuestionTasks[paneReference] = Task { [weak self] in
            var question: CodexTranscriptQuestion?
            for delayNanoseconds in Self.codexQuestionRetryDelayNanoseconds {
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled else {
                    return
                }
                question = await Task.detached(priority: .utility) {
                    await resolver(request)
                }.value
                if question != nil {
                    break
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self?.pendingCodexQuestionRequests[paneReference] == request else {
                    return
                }
                self?.pendingCodexQuestionTasks[paneReference] = nil
                self?.pendingCodexQuestionRequests[paneReference] = nil
                guard let question else {
                    return
                }
                if let cacheKey {
                    self?.cachedCodexTranscriptQuestions[cacheKey] = question
                }
                self?.applyCodexTranscriptQuestion(question, request: request, paneReference: paneReference)
            }
        }
    }

    private func codexTranscriptContextForQuestionEnrichment(
        worklaneID: WorklaneID,
        paneID: PaneID,
        auxiliaryState: PaneAuxiliaryState
    ) -> PaneCodexTranscriptContext? {
        if let context = auxiliaryState.raw.codexTranscriptContext,
           WorklaneContextFormatter.trimmed(context.path) != nil {
            return context
        }

        let workingDirectory = WorklaneContextFormatter.trimmed(auxiliaryState.metadata?.currentWorkingDirectory)
            ?? WorklaneContextFormatter.trimmed(auxiliaryState.agentStatus?.workingDirectory)
        guard let transcriptPath = CodexTranscriptQuestionExtractor.locateRecentTranscriptPath(
            workingDirectory: workingDirectory,
            environment: processEnvironment,
            now: currentDateProvider()
        ) else {
            return nil
        }

        let context = PaneCodexTranscriptContext(
            sessionID: WorklaneContextFormatter.trimmed(auxiliaryState.agentStatus?.sessionID),
            path: transcriptPath
        )
        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            return context
        }
        worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]?.raw.codexTranscriptContext = context
        return context
    }

    private func applyCodexTranscriptQuestion(
        _ question: CodexTranscriptQuestion,
        request: CodexTranscriptQuestionRequest,
        paneReference: PaneReference
    ) {
        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == paneReference.worklaneID }),
              let auxiliaryState = worklanes[worklaneIndex].auxiliaryStateByPaneID[paneReference.paneID],
              let status = auxiliaryState.agentStatus,
              status.tool == .codex,
              status.state == .needsInput,
              Self.codexQuestionEnrichmentIsEligible(status),
              let context = auxiliaryState.raw.codexTranscriptContext,
              context.path == request.transcriptPath,
              request.sessionID == nil || context.sessionID == nil || context.sessionID == request.sessionID else {
            return
        }

        applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: paneReference.worklaneID,
            paneID: paneReference.paneID,
            signalKind: .lifecycle,
            state: .needsInput,
            origin: .explicitAPI,
            toolName: AgentTool.codex.displayName,
            text: question.text,
            interactionKind: question.interactionKind,
            confidence: .strong,
            sessionID: request.sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentTranscriptPath: request.transcriptPath
        ))
    }

    private static func codexQuestionEnrichmentIsEligible(_ status: PaneAgentStatus?) -> Bool {
        guard let status,
              status.tool == .codex,
              status.state == .needsInput else {
            return false
        }

        if status.origin == .inferred, status.confidence == .weak {
            return true
        }

        guard let text = AgentInteractionClassifier.trimmed(status.text) else {
            return status.interactionKind == .genericInput
        }

        let lowered = text.lowercased()
        if lowered.contains("plan-mode-prompt") || lowered.contains("plan mode prompt") {
            return status.origin == .heuristic || status.origin == .explicitAPI
        }

        if AgentInteractionClassifier.isGenericNeedsInputContent(text)
            || AgentInteractionClassifier.isGenericNeedsInputMessage(text) {
            return status.origin != .explicitHook
        }

        return TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: text) != nil
            || TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: text) == .needsInput
            || TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                text,
                recognizedTool: .codex
            )?.phase == .needsInput
    }

    private func promoteCodexSessionIfTitleIndicatesRunning(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }
        codexResolver.promoteTitleRunning(
            &auxiliaryState,
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            now: Date()
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
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return false
        }
        let readyPromotionAllowed = codexReadyPromotionAllowed(in: auxiliaryState)
        let outcome = codexResolver.surfaceReadyFromIdleTitle(
            &auxiliaryState,
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            readyPromotionAllowed: readyPromotionAllowed,
            now: Date()
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        if outcome.requestReadyReveal {
            requestReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
        return outcome.suppressReadyAfterRecompute
    }

    @discardableResult
    private func promoteCodexSessionIfReadyTitleRecoversNeedsInput(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) -> Bool {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return false
        }
        let outcome = codexResolver.recoverNeedsInputFromReadyTitle(
            &auxiliaryState,
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            now: Date()
        )
        if outcome.didChangeStatus {
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        }
        if outcome.clearReadyStatus {
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
        return outcome.didChangeStatus
    }

    private func clearExpiredCodexTitleIdleSuppression(
        for paneID: PaneID,
        in worklane: inout WorklaneState,
        now: Date = Date()
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }
        codexResolver.clearExpiredTitleIdleSuppression(&auxiliaryState, now: now)
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func clearExpiredCodexInterruptSuppression(
        for paneID: PaneID,
        in worklane: inout WorklaneState,
        now: Date = Date()
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }
        codexResolver.clearExpiredInterruptSuppression(&auxiliaryState, now: now)
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    @discardableResult
    func clearStaleCodexStateAfterShellReturnIfNeeded(
        paneID: PaneID,
        metadata: TerminalMetadata?,
        allowsNonCodexPromptFallback: Bool = true,
        in worklane: inout WorklaneState
    ) -> Bool {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            codexRestartLogger.notice(
                "shellReturn.skip missingAux pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public)"
            )
            return false
        }
        let outcome = codexResolver.clearStaleStateAfterShellReturn(
            &auxiliaryState,
            paneID: paneID,
            metadata: metadata,
            allowsNonCodexPromptFallback: allowsNonCodexPromptFallback
        )
        if outcome.didClear {
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        }
        if outcome.cancelPendingQuestionTasks {
            let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
            pendingCodexQuestionTasks[paneReference]?.cancel()
            pendingCodexQuestionTasks[paneReference] = nil
            pendingCodexQuestionRequests[paneReference] = nil
        }
        return outcome.didClear
    }

    private func logCodexRestartMetadataUpdate(
        stage: String,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        metadataChangeKind: TerminalMetadataChangeKind,
        auxiliaryState: PaneAuxiliaryState
    ) {
        let recognizedTool = auxiliaryState.agentStatus?.tool ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex
            || AgentToolRecognizer.recognize(metadata: previousMetadata) == .codex
            || auxiliaryState.raw.codexInterruptSuppressionUntil != nil
            || auxiliaryState.agentStatus?.tool == .codex else {
            return
        }

        codexRestartLogger.debug(
            "\(stage, privacy: .public) pane=\(paneID.rawValue, privacy: .public) change=\(String(describing: metadataChangeKind), privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevProcess=\(previousMetadata?.processName ?? "<nil>", privacy: .public) process=\(metadata.processName ?? "<nil>", privacy: .public) recognized=\(recognizedTool?.displayName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState.raw), privacy: .public)"
        )
    }

    static func codexRestartStatusDescription(_ status: PaneAgentStatus?) -> String {
        guard let status else {
            return "<nil>"
        }
        return "\(status.tool.displayName):\(status.state.rawValue):\(status.origin.rawValue):\(String(describing: status.source)):session=\(status.sessionID ?? "<nil>")"
    }

    static func codexRestartSuppressionDescription(_ raw: PaneRawState?) -> String {
        guard let raw,
              let deadline = raw.codexInterruptSuppressionUntil else {
            return "<nil>"
        }
        let remaining = deadline.timeIntervalSinceNow
        return String(format: "%.2fs active=%@", remaining, raw.codexInterruptSuppressionIsActive() ? "true" : "false")
    }

    private func codexTitleIdleSuppressionIsActive(
        _ raw: PaneRawState,
        now: Date = Date()
    ) -> Bool {
        codexResolver.titleIdleSuppressionIsActive(raw, now: now)
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

        auxiliaryState.agentReducerState = AgentStatusReconciliation.seededReducerState(
            auxiliaryState.agentReducerState,
            from: existingStatus
        )
        let now = currentDateProvider()
        guard auxiliaryState.agentReducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: now) else {
            return false
        }

        auxiliaryState.agentStatus = AgentStatusReconciliation.hydratedStatus(
            auxiliaryState.agentReducerState.reducedStatus(now: now),
            existingStatus: existingStatus
        )
        auxiliaryState.raw.codexTitleIdleSuppressionUntil = Date().addingTimeInterval(
            PaneAgentReducerState.stopGraceWindow + Self.codexTitleIdleSuppressionWindow
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        scheduleAgentStatusSweep(
            for: PaneReference(worklaneID: worklane.id, paneID: paneID),
            after: PaneAgentReducerState.stopGraceWindow
        )
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

        if previousAuxiliaryState.presentation.prLookupKey != nextAuxiliaryState.presentation.prLookupKey
            || agentLifecycleRequiresReviewRefresh(
                previousAuxiliaryState: previousAuxiliaryState,
                nextAuxiliaryState: nextAuxiliaryState
            ) {
            impacts.insert(.reviewRefresh)
        }

        return impacts
    }

    private func agentLifecycleRequiresReviewRefresh(
        previousAuxiliaryState: PaneAuxiliaryState,
        nextAuxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard nextAuxiliaryState.presentation.prLookupKey != nil else {
            return false
        }

        let previousPhase = previousAuxiliaryState.presentation.runtimePhase
        let nextPhase = nextAuxiliaryState.presentation.runtimePhase
        if previousPhase != .starting, nextPhase == .starting {
            return true
        }

        return previousAuxiliaryState.presentation.isWorking != nextAuxiliaryState.presentation.isWorking
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
        clearExpiredCodexInterruptSuppression(for: paneID, in: &worklane)
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

    func refreshGitContextIfNeeded(
        for paneReference: PaneReference,
        forceReload: Bool = false
    ) {
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

        if forceReload {
            invalidateCachedGitContext(path: workingDirectory)
        }

        if !forceReload,
           let cached = cachedGitContextByPath[workingDirectory],
           cachedGitContext(cached, matches: shellBranchHint) {
            updateGitContext(paneID: paneReference.paneID, gitContext: cached)
            return
        }
        cachedGitContextByPath.removeValue(forKey: workingDirectory)

        if !forceReload,
           knownNonRepositoryPaths.contains(workingDirectory) {
            if shellBranchHint != nil {
                knownNonRepositoryPaths.remove(workingDirectory)
                nonRepositoryRetryDeadlineByPath.removeValue(forKey: workingDirectory)
            } else if let retryDeadline = nonRepositoryRetryDeadlineByPath[workingDirectory],
                      retryDeadline > currentDateProvider() {
                updateGitContext(paneID: paneReference.paneID, gitContext: nil)
                return
            } else {
                knownNonRepositoryPaths.remove(workingDirectory)
                nonRepositoryRetryDeadlineByPath.removeValue(forKey: workingDirectory)
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
            nonRepositoryRetryDeadlineByPath.removeValue(forKey: workingDirectory)
        } else {
            cachedGitContextByPath.removeValue(forKey: workingDirectory)
            knownNonRepositoryPaths.insert(workingDirectory)
            nonRepositoryRetryDeadlineByPath[workingDirectory] = currentDateProvider()
                .addingTimeInterval(nonRepositoryRetryInterval)
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
