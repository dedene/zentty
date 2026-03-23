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
        let branch = WorkspaceContextFormatter.displayBranch(
            reviewState?.branch ?? focusedPaneContext?.metadata?.gitBranch
        )
        let focusedLabelPresentation = focusedLabelPresentation(
            metadata: focusedPaneContext?.metadata,
            paneTitle: focusedPaneContext?.pane.title,
            shellContext: focusedPaneContext?.auxiliaryState?.shellContext,
            branch: branch
        )

        return WorkspaceChromeSummary(
            attention: WorkspaceAttentionSummaryBuilder.summary(for: workspace),
            focusedLabel: focusedLabelPresentation.label,
            branch: focusedLabelPresentation.includesBranch ? nil : branch,
            pullRequest: reviewState?.pullRequest,
            reviewChips: reviewState?.reviewChips ?? []
        )
    }

    private static func focusedLabelPresentation(
        metadata: TerminalMetadata?,
        paneTitle: String?,
        shellContext: PaneShellContext?,
        branch: String?
    ) -> (label: String?, includesBranch: Bool) {
        if let recognized = AgentToolRecognizer.recognize(metadata: metadata) {
            return (recognized.displayName, false)
        }

        let resolvedWorkingDirectory = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: metadata,
            shellContext: shellContext
        )
        let formattedDirectory = WorkspaceContextFormatter.formattedWorkingDirectory(
            resolvedWorkingDirectory,
            branch: branch
        )
        let stableIdentity = WorkspaceContextFormatter.displayStablePaneIdentity(
            for: metadata,
            fallbackTitle: paneTitle,
            workingDirectory: resolvedWorkingDirectory,
            branch: branch
        )

        if formattedDirectory == stableIdentity {
            return (
                WorkspaceContextFormatter.branchPrefixedLocationLabel(
                    workingDirectory: resolvedWorkingDirectory,
                    branch: branch
                ),
                branch != nil
            )
        }

        return (
            stableIdentity
                ?? WorkspaceContextFormatter.displayTerminalIdentity(for: metadata, fallbackTitle: paneTitle)
                ?? WorkspaceContextFormatter.trimmed(paneTitle),
            false
        )
    }
}
