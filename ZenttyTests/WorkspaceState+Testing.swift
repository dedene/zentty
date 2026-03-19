@testable import Zentty

extension WorkspaceState {
    /// Test convenience — constructs WorkspaceState from separate per-pane dictionaries.
    /// Production code uses `auxiliaryStateByPaneID` directly.
    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneContextByPaneID: [PaneID: PaneShellContext] = [:],
        agentStatusByPaneID: [PaneID: PaneAgentStatus] = [:],
        inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink] = [:],
        reviewStateByPaneID: [PaneID: WorkspaceReviewState] = [:]
    ) {
        var aux: [PaneID: PaneAuxiliaryState] = [:]
        let allPaneIDs = Set(metadataByPaneID.keys)
            .union(paneContextByPaneID.keys)
            .union(agentStatusByPaneID.keys)
            .union(inferredArtifactByPaneID.keys)
            .union(reviewStateByPaneID.keys)
        for paneID in allPaneIDs {
            aux[paneID] = PaneAuxiliaryState(
                metadata: metadataByPaneID[paneID],
                shellContext: paneContextByPaneID[paneID],
                agentStatus: agentStatusByPaneID[paneID],
                inferredArtifact: inferredArtifactByPaneID[paneID],
                reviewState: reviewStateByPaneID[paneID]
            )
        }

        self.init(
            id: id,
            title: title,
            paneStripState: paneStripState,
            nextPaneNumber: nextPaneNumber,
            auxiliaryStateByPaneID: aux
        )
    }
}
