enum WorkspaceHeaderSummaryBuilder {
    static func summary(
        for workspace: WorkspaceState,
        reviewStateProvider: WorkspaceReviewStateProvider
    ) -> WorkspaceChromeSummary {
        let focusedPaneContext = workspace.focusedPaneContext
        let reviewState = reviewStateProvider.reviewState(
            for: workspace,
            focusedPaneID: focusedPaneContext?.paneID
        )

        return WorkspaceChromeSummary(
            attention: WorkspaceAttentionSummaryBuilder.summary(for: workspace),
            focusedLabel: focusedLabel(
                metadata: focusedPaneContext?.metadata,
                paneTitle: focusedPaneContext?.pane.title
            ),
            branch: reviewState?.branch,
            pullRequest: reviewState?.pullRequest,
            reviewChips: reviewState?.reviewChips ?? []
        )
    }

    private static func focusedLabel(metadata: TerminalMetadata?, paneTitle: String?) -> String? {
        AgentToolRecognizer.recognize(metadata: metadata)?.displayName
            ?? WorkspaceContextFormatter.displayMeaningfulTerminalIdentity(for: metadata, fallbackTitle: paneTitle)
            ?? WorkspaceContextFormatter.displayWorkingDirectory(for: metadata)
            ?? WorkspaceContextFormatter.displayTerminalIdentity(for: metadata, fallbackTitle: paneTitle)
            ?? WorkspaceContextFormatter.trimmed(paneTitle)
    }
}
