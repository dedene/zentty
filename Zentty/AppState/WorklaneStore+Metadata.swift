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
        if auxiliaryState.agentStatus?.interactionKind.requiresHumanAttention == true {
            return false
        }
        if let existingStatus = auxiliaryState.agentStatus,
           existingStatus.tool == .codex,
           let nextTitlePhase = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                nextMetadata.title,
                recognizedTool: .codex
           )?.phase {
            if nextTitlePhase == .needsInput {
                return false
            }
            if !Self.codexVolatileTitleFastPathStatusMatches(
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

        let codexTitleInteractionKind = TerminalMetadataChangeClassifier.codexTitleInteractionKind(
            for: metadata.title
        )
        let waitingTitleKind = TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title)
        let titleNeedsInput = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        )?.phase == .needsInput
        guard codexTitleInteractionKind != nil || waitingTitleKind != nil || titleNeedsInput else {
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
        let titleInteractionKind = TerminalMetadataChangeClassifier.codexTitleInteractionKind(
            for: metadata.title
        )
        guard
            recognizedTool == .codex,
            titleInteractionKind != nil,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            !auxiliaryState.raw.codexInterruptSuppressionIsActive()
        else {
            return
        }

        if auxiliaryState.agentStatus?.state == .needsInput {
            return
        }

        let existingStatus = auxiliaryState.agentStatus
        let titleText = AgentInteractionClassifier.trimmed(metadata.title)
        let interactionKind = titleInteractionKind ?? .genericInput
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
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard recognizedTool == .codex else {
            logCodexRunningPromotionSkippedIfRelevant(
                reason: "recognizedTool",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: worklane.auxiliaryStateByPaneID[paneID]
            )
            return
        }
        guard let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: recognizedTool
        ) else {
            logCodexRunningPromotionSkippedIfRelevant(
                reason: "noSignature",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: worklane.auxiliaryStateByPaneID[paneID]
            )
            return
        }
        guard signature.phase == .running else {
            logCodexRunningPromotionSkippedIfRelevant(
                reason: "phase-\(signature.phase)",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: worklane.auxiliaryStateByPaneID[paneID]
            )
            return
        }
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            logCodexRunningPromotionSkippedIfRelevant(
                reason: "missingAuxiliaryState",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: nil
            )
            return
        }
        guard !auxiliaryState.raw.codexInterruptSuppressionIsActive() else {
            logCodexRunningPromotionSkippedIfRelevant(
                reason: "interruptSuppression",
                paneID: paneID,
                recognizedTool: recognizedTool,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: auxiliaryState
            )
            return
        }

        if let existingStatus = auxiliaryState.agentStatus {
            let runningTitleMayClearBlockedStatus = Self.codexRunningTitleMayClearBlockedStatus(
                existingStatus,
                auxiliaryState: auxiliaryState
            )
            if Self.codexStatusShouldBlockTitleDrivenResume(existingStatus),
               !runningTitleMayClearBlockedStatus {
                logCodexRunningPromotionSkippedIfRelevant(
                    reason: "blockedStatus",
                    paneID: paneID,
                    recognizedTool: recognizedTool,
                    previousMetadata: previousMetadata,
                    metadata: metadata,
                    auxiliaryState: auxiliaryState
                )
                return
            }

            if runningTitleMayClearBlockedStatus {
                let now = Date()
                let newStatus = Self.codexRunningStatus(from: existingStatus, now: now)
                auxiliaryState.agentStatus = newStatus
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    PaneAgentReducerState(),
                    from: newStatus
                )
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
                stopSignalLogger.debug(
                    "codex.title.running cleared-blocked-status pane=\(paneID.rawValue, privacy: .public)"
                )
                return
            }
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
            logCodexRestartPromotion(
                stage: "running.already",
                paneID: paneID,
                previousMetadata: previousMetadata,
                metadata: metadata,
                auxiliaryState: auxiliaryState
            )
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
           existingStatus.hasObservedRunning,
           previousMetadataCanBeStaleCodexRunningTail(previousMetadata) {
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            stopSignalLogger.debug(
                "codex.title.running skip=withinIdleSuppressionWindow pane=\(paneID.rawValue, privacy: .public)"
            )
            return
        }

        if let existingStatus = auxiliaryState.agentStatus,
           existingStatus.state == .idle,
           existingStatus.hasObservedRunning,
           existingStatus.origin == .explicitHook,
           now.timeIntervalSince(existingStatus.updatedAt) <= Self.codexTitleIdleSuppressionWindow,
           previousMetadataCanBeStaleCodexRunningTail(previousMetadata) {
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
            !auxiliaryState.raw.codexInterruptSuppressionIsActive(),
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
            guard codexReadyPromotionAllowed(in: auxiliaryState) else {
                stopSignalLogger.debug("codex.title.idle firstBranch skip=noCurrentRunEvidence pane=\(paneID.rawValue, privacy: .public)")
                return false
            }
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
              codexReadyPromotionAllowed(in: auxiliaryState),
              (
                (
                    existingStatus.hasObservedRunning
                    && (
                        existingStatus.state == .running
                        || existingStatus.state == .idle
                    )
                )
                || Self.codexStatusMayClearFromReadyTitle(existingStatus)
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

    @discardableResult
    private func promoteCodexSessionIfReadyTitleRecoversNeedsInput(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        in worklane: inout WorklaneState
    ) -> Bool {
        let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        guard
            recognizedTool == .codex,
            let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                metadata.title,
                recognizedTool: recognizedTool
            ),
            signature.phase == .idle,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            !auxiliaryState.raw.codexInterruptSuppressionIsActive(),
            let existingStatus = auxiliaryState.agentStatus,
            existingStatus.tool == .codex,
            existingStatus.source == .explicit,
            existingStatus.hasObservedRunning,
            existingStatus.state == .running || existingStatus.state == .starting,
            let notificationText = AgentInteractionClassifier.trimmed(auxiliaryState.raw.lastDesktopNotificationText),
            let notificationDate = auxiliaryState.raw.lastDesktopNotificationDate
        else {
            return false
        }

        if TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: recognizedTool
        )?.phase == .idle {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(notificationDate) <= Self.codexReadyNotificationRecoveryWindow,
              let interactionKind = AgentInteractionClassifier.interactionKind(forWaitingMessage: notificationText),
              interactionKind != .genericInput else {
            return false
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
        auxiliaryState.agentStatus = newStatus
        auxiliaryState.agentReducerState = Self.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        stopSignalLogger.debug(
            "codex.title.ready recoverNeedsInput pane=\(paneID.rawValue, privacy: .public) interaction=\(interactionKind.rawValue, privacy: .public) notification=\(notificationText, privacy: .public)"
        )
        return true
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

    private func clearExpiredCodexInterruptSuppression(
        for paneID: PaneID,
        in worklane: inout WorklaneState,
        now: Date = Date()
    ) {
        guard let deadline = worklane.auxiliaryStateByPaneID[paneID]?.raw.codexInterruptSuppressionUntil,
              now >= deadline else {
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexInterruptSuppressionUntil = nil
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

        let hasActiveCodexStatus = auxiliaryState.agentStatus?.tool == .codex
            && auxiliaryState.agentStatus?.state != .idle
        let hasActiveCodexSession = auxiliaryState.agentReducerState.sessionsByID.values.contains { session in
            session.tool == .codex
                && (session.state != .idle || session.interactionKind.requiresHumanAttention)
        }
        let hasCodexSuppression = auxiliaryState.raw.codexInterruptSuppressionUntil != nil
        guard hasActiveCodexStatus || hasActiveCodexSession || hasCodexSuppression else {
            codexRestartLogger.notice(
                "shellReturn.skip noStaleCodex pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState.raw), privacy: .public)"
            )
            return false
        }
        let shouldClear = Self.metadataIndicatesShellReturnFromCodex(metadata)
            || (
                allowsNonCodexPromptFallback
                && (
                    Self.metadataIndicatesWeakCodexFallbackEnded(
                        metadata,
                        auxiliaryState: auxiliaryState
                    )
                    || (
                        Self.metadataIndicatesNonCodexPrompt(metadata)
                        && (hasActiveCodexStatus || hasActiveCodexSession)
                    )
                )
            )
        guard shouldClear else {
            return false
        }

        codexRestartLogger.notice(
            "shellReturn.clear pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState.raw), privacy: .public)"
        )
        _ = auxiliaryState.agentReducerState.clearCodexSessionsFromUserInterrupt()
        if auxiliaryState.agentStatus?.tool == .codex {
            auxiliaryState.agentStatus = nil
        }
        auxiliaryState.terminalProgress = nil
        auxiliaryState.raw.wantsReadyStatus = false
        auxiliaryState.raw.showsReadyStatus = false
        auxiliaryState.raw.codexCurrentRunHasObservedActivity = false
        auxiliaryState.raw.codexInterruptSuppressionUntil = nil
        auxiliaryState.raw.codexTitleIdleSuppressionUntil = nil
        auxiliaryState.raw.codexTranscriptContext = nil
        auxiliaryState.raw.lastDesktopNotificationText = nil
        auxiliaryState.raw.lastDesktopNotificationDate = nil
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        pendingCodexQuestionTasks[paneReference]?.cancel()
        pendingCodexQuestionTasks[paneReference] = nil
        pendingCodexQuestionRequests[paneReference] = nil
        return true
    }

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

    private func logCodexRunningPromotionSkippedIfRelevant(
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
            "running.skip reason=\(reason, privacy: .public) pane=\(paneID.rawValue, privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevProcess=\(previousMetadata?.processName ?? "<nil>", privacy: .public) process=\(metadata.processName ?? "<nil>", privacy: .public) recognized=\(recognizedTool?.displayName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState?.agentStatus), privacy: .public) sessions=\(auxiliaryState?.agentReducerState.sessionsByID.count ?? -1, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState?.raw), privacy: .public)"
        )
    }

    private func logCodexRestartPromotion(
        stage: String,
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
        metadata: TerminalMetadata,
        auxiliaryState: PaneAuxiliaryState
    ) {
        codexRestartLogger.notice(
            "\(stage, privacy: .public) pane=\(paneID.rawValue, privacy: .public) prevTitle=\(previousMetadata?.title ?? "<nil>", privacy: .public) title=\(metadata.title ?? "<nil>", privacy: .public) prevProcess=\(previousMetadata?.processName ?? "<nil>", privacy: .public) process=\(metadata.processName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState.raw), privacy: .public)"
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
        guard let deadline = raw.codexTitleIdleSuppressionUntil else {
            return false
        }

        return now < deadline
    }

    private func previousMetadataCanBeStaleCodexRunningTail(_ previousMetadata: TerminalMetadata?) -> Bool {
        guard let previousMetadata else {
            return true
        }

        return AgentToolRecognizer.recognize(metadata: previousMetadata) == .codex
    }

    private static func codexReadyTitleMayClearStatus(_ status: PaneAgentStatus?) -> Bool {
        guard let status else {
            return true
        }

        guard status.state == .needsInput else {
            return true
        }

        return codexStatusMayClearFromReadyTitle(status)
    }

    private static func codexRunningTitleMayClearBlockedStatus(
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
                || codexStatusIsStalePlanModePrompt(status)
        case .heuristic, .inferred, .compatibility, .shell:
            return codexStatusIsStalePlanModePrompt(status)
        }
    }

    private static func codexStatusShouldBlockTitleDrivenResume(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.interactionKind.requiresHumanAttention else {
            return false
        }

        return !codexStatusIsStaleGenericNeedsInput(status)
            && !codexStatusIsStalePlanModePrompt(status)
    }

    private static func codexStatusIsStalePlanModePrompt(_ status: PaneAgentStatus) -> Bool {
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

    private static func codexStatusIsStaleGenericNeedsInput(_ status: PaneAgentStatus) -> Bool {
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

    private static func codexStatusMayClearFromReadyTitle(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind == .genericInput else {
            return false
        }

        if codexStatusIsStaleGenericNeedsInput(status) {
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
        let now = currentDateProvider()
        guard auxiliaryState.agentReducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: now) else {
            return false
        }

        auxiliaryState.agentStatus = Self.hydratedStatus(
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
