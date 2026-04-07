import Foundation

extension WorklaneStore {
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
        let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        let metadataChangeKind = TerminalMetadataChangeClassifier.classify(
            previous: previousMetadata,
            next: metadata
        )
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        clearStaleDesktopNotificationIfNeeded(for: paneID, metadata: metadata, in: &worklane)
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
        surfaceReadyCodexSessionIfTitleIndicatesIdle(
            paneID: paneID,
            previousMetadata: previousMetadata,
            metadata: metadata,
            in: &worklane
        )
        invalidateGitContextIfNeeded(for: paneID, in: &worklane)
        recomputePresentation(for: paneID, in: &worklane)

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

        if auxiliaryState.agentStatus?.interactionKind.requiresHumanAttention == true {
            return
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        let now = Date()
        let didPromoteStarting = auxiliaryState.agentReducerState.promoteExplicitStartingSessionToRunning(now: now)
        let didResumeBlocked = auxiliaryState.agentReducerState.resumeBlockedSessionFromActivity(now: now)

        if didPromoteStarting || didResumeBlocked {
            auxiliaryState.agentStatus = Self.hydratedStatus(
                auxiliaryState.agentReducerState.reducedStatus(),
                existingStatus: auxiliaryState.agentStatus
            )
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            return
        }

        if auxiliaryState.agentStatus?.state == .running {
            return
        }

        auxiliaryState.agentStatus = PaneAgentStatus(
            tool: .codex,
            state: .running,
            text: nil,
            artifactLink: auxiliaryState.agentStatus?.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: .inferred,
            interactionKind: .none,
            confidence: .weak,
            shellActivityState: auxiliaryState.agentStatus?.shellActivityState ?? .unknown,
            trackedPID: auxiliaryState.agentStatus?.trackedPID,
            workingDirectory: auxiliaryState.agentStatus?.workingDirectory,
            hasObservedRunning: true,
            sessionID: auxiliaryState.agentStatus?.sessionID,
            parentSessionID: auxiliaryState.agentStatus?.parentSessionID
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

    private func surfaceReadyCodexSessionIfTitleIndicatesIdle(
        paneID: PaneID,
        previousMetadata: TerminalMetadata?,
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
            signature.phase == .idle,
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            auxiliaryState.agentStatus?.state != .needsInput
        else {
            return
        }
        let previousSignature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            previousMetadata?.title,
            recognizedTool: recognizedTool
        )
        guard previousSignature?.phase != .idle else {
            return
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        let now = Date()
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
                return
            }

            auxiliaryState.agentStatus = reducedStatus
            auxiliaryState.raw.showsReadyStatus = true
            worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            return
        }

        guard let existingStatus = auxiliaryState.agentStatus,
              existingStatus.tool == .codex,
              existingStatus.hasObservedRunning,
              existingStatus.state == .running || existingStatus.state == .idle
        else {
            return
        }

        auxiliaryState.agentStatus = PaneAgentStatus(
            tool: .codex,
            state: .idle,
            text: nil,
            artifactLink: existingStatus.artifactLink,
            updatedAt: now,
            source: .inferred,
            origin: existingStatus.origin == .explicitAPI || existingStatus.origin == .explicitHook ? existingStatus.origin : .inferred,
            interactionKind: .none,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            workingDirectory: existingStatus.workingDirectory,
            hasObservedRunning: true,
            sessionID: existingStatus.sessionID,
            parentSessionID: existingStatus.parentSessionID
        )
        auxiliaryState.raw.showsReadyStatus = true
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
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
            worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = false
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
        previousAuxiliaryState.presentation == nextAuxiliaryState.presentation
            && previousAuxiliaryState.shellContext?.scope == nextAuxiliaryState.shellContext?.scope
            && gitContextRefreshHint(for: previousAuxiliaryState) == gitContextRefreshHint(for: nextAuxiliaryState)
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

        let previousPresentation = worklane.auxiliaryStateByPaneID[paneID]?.presentation
        let raw = worklane.auxiliaryStateByPaneID[paneID]?.raw ?? PaneRawState()
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].presentation = PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: raw,
            previous: previousPresentation,
            sessionRequestWorkingDirectory: pane.sessionRequest.inheritFromPaneID == nil
                ? pane.sessionRequest.workingDirectory
                : nil
        )
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
