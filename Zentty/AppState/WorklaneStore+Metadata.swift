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
        let metadataChangeKind = TerminalMetadataChangeClassifier.classify(
            previous: previousMetadata,
            next: metadata
        )
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        clearStaleDesktopNotificationIfNeeded(for: paneID, metadata: metadata, in: &worklane)
        if branchContextDidChange(previous: previousMetadata, next: metadata) {
            clearBranchDerivedState(for: paneID, in: &worklane)
            worklane.auxiliaryStateByPaneID[paneID]?.gitContext = nil
            invalidateCachedGitContext(path: WorklaneContextFormatter.resolvedWorkingDirectory(for: metadata))
        }
        if
            let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus,
            (existingStatus.source == .inferred || existingStatus.origin == .compatibility),
            AgentToolRecognizer.recognize(metadata: metadata) == nil
        {
            worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
            worklane.auxiliaryStateByPaneID[paneID]?.agentReducerState = PaneAgentReducerState()
        }
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
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstWord = title.prefix(while: { $0.isLetter }).lowercased()
        if firstWord == "working" || firstWord == "thinking" || firstWord == "starting" {
            worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationText = nil
            worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationDate = nil
            worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = false
        }
    }

    private func branchContextDidChange(previous: TerminalMetadata?, next: TerminalMetadata) -> Bool {
        if WorklaneContextFormatter.resolvedWorkingDirectory(for: previous)
            != WorklaneContextFormatter.resolvedWorkingDirectory(for: next) {
            return true
        }

        return WorklaneContextFormatter.displayBranch(previous?.gitBranch)
            != WorklaneContextFormatter.displayBranch(next.gitBranch)
    }

    private func shouldFastPathVolatileMetadataUpdate(
        previousAuxiliaryState: PaneAuxiliaryState,
        nextAuxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        previousAuxiliaryState.presentation == nextAuxiliaryState.presentation
            && previousAuxiliaryState.localReviewWorkingDirectory == nextAuxiliaryState.localReviewWorkingDirectory
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

        return previousAuxiliaryState?.localReviewWorkingDirectory != nextAuxiliaryState?.localReviewWorkingDirectory
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
            previous: previousPresentation
        )
    }

    func invalidateGitContextIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let currentWorkingDirectory = worklane.auxiliaryStateByPaneID[paneID]?.localReviewWorkingDirectory
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

        guard let workingDirectory = auxiliaryState?.localReviewWorkingDirectory else {
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

            let currentWorkingDirectory = worklanes[worklaneIndex]
                .auxiliaryStateByPaneID[paneReference.paneID]?
                .localReviewWorkingDirectory
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
