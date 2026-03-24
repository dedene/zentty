import Foundation

extension WorkspaceStore {
    func updateMetadata(paneID: PaneID, metadata: TerminalMetadata) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousMetadata = workspace.auxiliaryStateByPaneID[paneID]?.metadata
        workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        if branchContextDidChange(previous: previousMetadata, next: metadata) {
            clearBranchDerivedState(for: paneID, in: &workspace)
        }
        if
            let existingStatus = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus,
            existingStatus.source == .inferred,
            AgentToolRecognizer.recognize(metadata: metadata) == nil
        {
            workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
        }
        invalidateGitContextIfNeeded(for: paneID, in: &workspace)
        recomputePresentation(for: paneID, in: &workspace)
        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: paneID)
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
        refreshGitContextIfNeeded(for: PaneReference(workspaceID: workspace.id, paneID: paneID))
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    func clearPaneState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID.removeValue(forKey: paneID)
    }

    func clearStatusDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
    }

    func clearBranchDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        if var status = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus, status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = status
        }
    }

    private func branchContextDidChange(previous: TerminalMetadata?, next: TerminalMetadata) -> Bool {
        WorkspaceContextFormatter.resolvedWorkingDirectory(for: previous)
            != WorkspaceContextFormatter.resolvedWorkingDirectory(for: next)
    }

    func updateGitContext(paneID: PaneID, gitContext: PaneGitContext?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousLookupKey = workspace.auxiliaryStateByPaneID[paneID]?.presentation.prLookupKey
        workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].gitContext = gitContext
        recomputePresentation(for: paneID, in: &workspace)
        let nextLookupKey = workspace.auxiliaryStateByPaneID[paneID]?.presentation.prLookupKey
        if previousLookupKey != nextLookupKey {
            clearBranchDerivedState(for: paneID, in: &workspace)
            workspace.auxiliaryStateByPaneID[paneID]?.gitContext = gitContext
            recomputePresentation(for: paneID, in: &workspace)
        }

        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }

    func recomputePresentation(for paneID: PaneID, in workspace: inout WorkspaceState) {
        guard let pane = workspace.paneStripState.panes.first(where: { $0.id == paneID }) else {
            return
        }

        let previousPresentation = workspace.auxiliaryStateByPaneID[paneID]?.presentation
        let raw = workspace.auxiliaryStateByPaneID[paneID]?.raw ?? PaneRawState()
        workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].presentation = PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: raw,
            previous: previousPresentation
        )
    }

    func invalidateGitContextIfNeeded(for paneID: PaneID, in workspace: inout WorkspaceState) {
        let currentWorkingDirectory = workspace.auxiliaryStateByPaneID[paneID]?.localReviewWorkingDirectory
        if workspace.auxiliaryStateByPaneID[paneID]?.gitContext?.workingDirectory != currentWorkingDirectory {
            workspace.auxiliaryStateByPaneID[paneID]?.gitContext = nil
        }
    }

    func refreshGitContextIfNeeded(for paneReference: PaneReference) {
        guard
            let workspaceIndex = workspaces.firstIndex(where: { $0.id == paneReference.workspaceID }),
            workspaces[workspaceIndex].paneStripState.panes.contains(where: { $0.id == paneReference.paneID })
        else {
            return
        }

        let auxiliaryState = workspaces[workspaceIndex].auxiliaryStateByPaneID[paneReference.paneID]
        if auxiliaryState?.shellContext?.scope == .remote {
            updateGitContext(paneID: paneReference.paneID, gitContext: nil)
            return
        }

        guard let workingDirectory = auxiliaryState?.localReviewWorkingDirectory else {
            updateGitContext(paneID: paneReference.paneID, gitContext: nil)
            return
        }

        let shellBranchHint = WorkspaceContextFormatter.displayBranch(auxiliaryState?.shellContext?.gitBranch)

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
                let workspaceIndex = workspaces.firstIndex(where: { $0.id == paneReference.workspaceID }),
                workspaces[workspaceIndex].paneStripState.panes.contains(where: { $0.id == paneReference.paneID })
            else {
                continue
            }

            let currentWorkingDirectory = workspaces[workspaceIndex]
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
            return WorkspaceContextFormatter.trimmed(gitContext.branchDisplayText) == nil
                || gitContext.branchName == nil
                || WorkspaceContextFormatter.displayBranch(gitContext.branchName) == nil
        }

        return WorkspaceContextFormatter.displayBranch(gitContext.branchName) == shellBranchHint
    }
}
