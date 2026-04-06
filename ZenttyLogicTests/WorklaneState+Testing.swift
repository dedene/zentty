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
        reviewStateByPaneID: [PaneID: WorklaneReviewState] = [:],
        gitContextByPaneID: [PaneID: PaneGitContext] = [:]
    ) {
        var aux: [PaneID: PaneAuxiliaryState] = [:]
        let allPaneIDs = Set(metadataByPaneID.keys)
            .union(paneContextByPaneID.keys)
            .union(agentStatusByPaneID.keys)
            .union(terminalProgressByPaneID.keys)
            .union(reviewStateByPaneID.keys)
            .union(gitContextByPaneID.keys)
        for paneID in allPaneIDs {
            let metadata = metadataByPaneID[paneID]
            let synthesizedGitContext = gitContextByPaneID[paneID] ?? Self.syntheticGitContext(
                metadata: metadata,
                shellContext: paneContextByPaneID[paneID]
            )
            let auxiliaryState = PaneAuxiliaryState(
                metadata: metadata,
                shellContext: paneContextByPaneID[paneID],
                agentStatus: agentStatusByPaneID[paneID],
                terminalProgress: terminalProgressByPaneID[paneID],
                reviewState: reviewStateByPaneID[paneID],
                gitContext: synthesizedGitContext
            )
            let pane = paneStripState.panes.first(where: { $0.id == paneID })
            let paneTitle = pane?.title
            var normalizedAuxiliaryState = auxiliaryState
            normalizedAuxiliaryState.presentation = PanePresentationNormalizer.normalize(
                paneTitle: paneTitle,
                raw: auxiliaryState.raw,
                previous: auxiliaryState.presentation,
                sessionRequestWorkingDirectory: pane?.sessionRequest.inheritFromPaneID == nil
                    ? pane?.sessionRequest.workingDirectory
                    : nil
            )
            aux[paneID] = normalizedAuxiliaryState
        }

        self.init(
            id: id,
            title: title,
            paneStripState: paneStripState,
            nextPaneNumber: nextPaneNumber,
            auxiliaryStateByPaneID: aux
        )
    }

    private static func syntheticGitContext(
        metadata: TerminalMetadata?,
        shellContext: PaneShellContext?
    ) -> PaneGitContext? {
        guard
            let workingDirectory = PaneTerminalLocationResolver.snapshot(
                metadata: metadata,
                shellContext: shellContext
            ).workingDirectory,
            let branch = WorklaneContextFormatter.displayBranch(metadata?.gitBranch)
        else {
            return nil
        }

        return PaneGitContext(
            workingDirectory: workingDirectory,
            repositoryRoot: workingDirectory,
            reference: .branch(branch)
        )
    }
}
