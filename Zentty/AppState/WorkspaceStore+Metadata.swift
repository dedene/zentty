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
        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: paneID)
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    func clearPaneState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID.removeValue(forKey: paneID)
    }

    private func clearStatusDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
    }

    private func clearBranchDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact = nil
        workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        if var status = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus, status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = status
        }
    }

    private func branchContextDidChange(previous: TerminalMetadata?, next: TerminalMetadata) -> Bool {
        WorkspaceContextFormatter.trimmed(previous?.gitBranch) != WorkspaceContextFormatter.trimmed(next.gitBranch)
            || WorkspaceContextFormatter.resolvedWorkingDirectory(for: previous) != WorkspaceContextFormatter.resolvedWorkingDirectory(for: next)
    }
}
