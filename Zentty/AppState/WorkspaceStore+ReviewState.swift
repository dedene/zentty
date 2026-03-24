import Foundation

extension WorkspaceStore {
    func updateReviewResolution(paneID: PaneID, resolution: WorkspaceReviewResolution) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.auxiliaryStateByPaneID[paneID]?.reviewState
        if resolution.updatePolicy == .preserveExistingOnEmpty,
           resolution.reviewState == nil {
            return
        }
        guard previousState != resolution.reviewState else {
            return
        }

        if let reviewState = resolution.reviewState {
            workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].reviewState = reviewState
        } else {
            workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        }

        recomputePresentation(for: paneID, in: &workspace)
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

        recomputePresentation(for: paneID, in: &workspace)
        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }
}
