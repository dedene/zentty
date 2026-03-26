@testable import Zentty

extension WorklaneState {
    /// Test convenience — constructs WorklaneState from separate per-pane dictionaries.
    /// Production code uses `auxiliaryStateByPaneID` directly.
    init(
        id: WorklaneID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneContextByPaneID: [PaneID: PaneShellContext] = [:],
        agentStatusByPaneID: [PaneID: PaneAgentStatus] = [:],
        terminalProgressByPaneID: [PaneID: TerminalProgressReport] = [:],
        reviewStateByPaneID: [PaneID: WorklaneReviewState] = [:]
    ) {
        var aux: [PaneID: PaneAuxiliaryState] = [:]
        let allPaneIDs = Set(metadataByPaneID.keys)
            .union(paneContextByPaneID.keys)
            .union(agentStatusByPaneID.keys)
            .union(terminalProgressByPaneID.keys)
            .union(reviewStateByPaneID.keys)
        for paneID in allPaneIDs {
            aux[paneID] = PaneAuxiliaryState(
                metadata: metadataByPaneID[paneID],
                shellContext: paneContextByPaneID[paneID],
                agentStatus: agentStatusByPaneID[paneID],
                terminalProgress: terminalProgressByPaneID[paneID],
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
