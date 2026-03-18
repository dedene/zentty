enum WorkspaceHeaderSummaryBuilder {
    static func summary(
        for workspace: WorkspaceState,
        reviewStateProvider: WorkspaceReviewStateProvider
    ) -> WorkspaceHeaderSummary {
        let focusedPane = workspace.paneStripState.focusedPane
        let metadata = workspace.paneStripState.focusedPaneID.flatMap { workspace.metadataByPaneID[$0] }
        let reviewState = reviewStateProvider.reviewState(
            for: workspace,
            focusedPaneID: workspace.paneStripState.focusedPaneID
        )

        return WorkspaceHeaderSummary(
            attention: WorkspaceAttentionSummaryBuilder.summary(for: workspace),
            focusedLabel: focusedLabel(metadata: metadata, paneTitle: focusedPane?.title),
            branch: reviewState?.branch,
            pullRequest: reviewState?.pullRequest,
            reviewChips: reviewState?.reviewChips ?? []
        )
    }

    private static func focusedLabel(metadata: TerminalMetadata?, paneTitle: String?) -> String? {
        AgentToolRecognizer.recognize(metadata: metadata)?.displayName
            ?? WorkspaceContextFormatter.displayWorkingDirectory(for: metadata)
            ?? WorkspaceContextFormatter.trimmed(metadata?.title)
            ?? WorkspaceContextFormatter.trimmed(metadata?.processName)
            ?? WorkspaceContextFormatter.trimmed(paneTitle)
    }
}
