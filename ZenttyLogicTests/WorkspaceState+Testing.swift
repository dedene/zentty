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
        terminalProgressByPaneID: [PaneID: TerminalProgressReport] = [:],
        reviewStateByPaneID: [PaneID: WorkspaceReviewState] = [:],
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
            let paneTitle = paneStripState.panes.first(where: { $0.id == paneID })?.title
            var normalizedAuxiliaryState = auxiliaryState
            normalizedAuxiliaryState.presentation = PanePresentationNormalizer.normalize(
                paneTitle: paneTitle,
                raw: auxiliaryState.raw,
                previous: auxiliaryState.presentation
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
            let workingDirectory = WorkspaceContextFormatter.resolvedWorkingDirectory(
                for: metadata,
                shellContext: shellContext
            ),
            let branch = WorkspaceContextFormatter.displayBranch(metadata?.gitBranch)
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
