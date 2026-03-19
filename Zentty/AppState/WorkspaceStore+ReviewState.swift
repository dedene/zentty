import Foundation

extension WorkspaceStore {
    func updateInferredArtifact(paneID: PaneID, artifact: WorkspaceArtifactLink?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousArtifact = workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact
        guard previousArtifact != artifact else {
            return
        }
        if let artifact {
            workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].inferredArtifact = artifact
        } else {
            workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact = nil
        }
        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }

    func updateReviewResolution(paneID: PaneID, resolution: WorkspaceReviewResolution) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.auxiliaryStateByPaneID[paneID]?.reviewState
        let previousArtifact = workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact
        guard previousState != resolution.reviewState || previousArtifact != resolution.inferredArtifact else {
            return
        }

        if let reviewState = resolution.reviewState {
            workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].reviewState = reviewState
        } else {
            workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        }

        if let artifact = resolution.inferredArtifact {
            workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].inferredArtifact = artifact
        } else {
            workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact = nil
        }

        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }

    func updateReviewState(paneID: PaneID, reviewState: WorkspaceReviewState?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.auxiliaryStateByPaneID[paneID]?.reviewState
        guard previousState != reviewState else {
            return
        }

        if let reviewState {
            workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].reviewState = reviewState
        } else {
            workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        }

        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }
}
