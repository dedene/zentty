import Foundation

extension WorkspaceStore {
    func updateMetadata(paneID: PaneID, metadata: TerminalMetadata) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousMetadata = workspace.metadataByPaneID[paneID]
        workspace.metadataByPaneID[paneID] = metadata
        if branchContextDidChange(previous: previousMetadata, next: metadata) {
            clearBranchDerivedState(for: paneID, in: &workspace)
        }
        if
            let existingStatus = workspace.agentStatusByPaneID[paneID],
            existingStatus.source == .inferred,
            AgentToolRecognizer.recognize(metadata: metadata) == nil
        {
            workspace.agentStatusByPaneID.removeValue(forKey: paneID)
        }
        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: paneID)
        notifyStateChanged()
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    func clearPaneState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.metadataByPaneID.removeValue(forKey: paneID)
        workspace.paneContextByPaneID.removeValue(forKey: paneID)
        clearStatusDerivedState(for: paneID, in: &workspace)
        clearBranchDerivedState(for: paneID, in: &workspace)
    }

    private func clearStatusDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.agentStatusByPaneID.removeValue(forKey: paneID)
    }

    private func clearBranchDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        if var status = workspace.agentStatusByPaneID[paneID], status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            workspace.agentStatusByPaneID[paneID] = status
        }
    }

    private func branchContextDidChange(previous: TerminalMetadata?, next: TerminalMetadata) -> Bool {
        WorkspaceContextFormatter.trimmed(previous?.gitBranch) != WorkspaceContextFormatter.trimmed(next.gitBranch)
            || WorkspaceContextFormatter.resolvedWorkingDirectory(for: previous) != WorkspaceContextFormatter.resolvedWorkingDirectory(for: next)
    }
}
