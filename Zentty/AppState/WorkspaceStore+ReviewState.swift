import Foundation

extension WorkspaceStore {
    func updateInferredArtifact(paneID: PaneID, artifact: WorkspaceArtifactLink?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousArtifact = workspace.inferredArtifactByPaneID[paneID]
        guard previousArtifact != artifact else {
            return
        }
        if let artifact {
            workspace.inferredArtifactByPaneID[paneID] = artifact
        } else {
            workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        }
        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func updateReviewResolution(paneID: PaneID, resolution: WorkspaceReviewResolution) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.reviewStateByPaneID[paneID]
        let previousArtifact = workspace.inferredArtifactByPaneID[paneID]
        guard previousState != resolution.reviewState || previousArtifact != resolution.inferredArtifact else {
            return
        }

        if let reviewState = resolution.reviewState {
            workspace.reviewStateByPaneID[paneID] = reviewState
        } else {
            workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        }

        if let artifact = resolution.inferredArtifact {
            workspace.inferredArtifactByPaneID[paneID] = artifact
        } else {
            workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        }

        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func updateReviewState(paneID: PaneID, reviewState: WorkspaceReviewState?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.reviewStateByPaneID[paneID]
        guard previousState != reviewState else {
            return
        }

        if let reviewState {
            workspace.reviewStateByPaneID[paneID] = reviewState
        } else {
            workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        }

        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }
}
