enum WorkspaceHeaderSummaryBuilder {
    static func summary(for workspace: WorkspaceState) -> WorkspaceChromeSummary {
        let focusedPaneContext = workspace.focusedPaneContext
        let presentation = focusedPaneContext?.presentation
        let focusedLabel = visibleFocusedLabel(from: presentation)
        let branch = visibleBranch(from: presentation)

        return WorkspaceChromeSummary(
            attention: WorkspaceAttentionSummaryBuilder.summary(for: workspace),
            focusedLabel: focusedLabel,
            branch: branch,
            pullRequest: presentation?.pullRequest,
            reviewChips: presentation?.reviewChips ?? []
        )
    }

    private static func visibleFocusedLabel(from presentation: PanePresentationState?) -> String? {
        guard
            let presentation,
            let rememberedTitle = WorkspaceContextFormatter.trimmed(presentation.rememberedTitle)
        else {
            return presentation.flatMap(visibleFallbackLabel(from:))
        }

        if let decomposedTitle = decomposedRememberedTitle(
            rememberedTitle,
            presentation: presentation
        ) {
            return decomposedTitle
        }

        return rememberedTitle
    }

    private static func visibleFallbackLabel(from presentation: PanePresentationState) -> String? {
        if let cwd = WorkspaceContextFormatter.trimmed(presentation.cwd) {
            return WorkspaceContextFormatter.formattedWorkingDirectory(cwd, branch: nil)
        }

        return WorkspaceContextFormatter.trimmed(presentation.visibleIdentityText)
    }

    private static func visibleBranch(from presentation: PanePresentationState?) -> String? {
        guard let presentation else {
            return nil
        }

        return WorkspaceContextFormatter.trimmed(presentation.branchDisplayText)
    }

    private static func decomposedRememberedTitle(
        _ rememberedTitle: String,
        presentation: PanePresentationState
    ) -> String? {
        guard
            let branch = WorkspaceContextFormatter.trimmed(presentation.branchDisplayText)
        else {
            return nil
        }

        for separator in [" · ", " • "] {
            let prefix = branch + separator
            if rememberedTitle.hasPrefix(prefix) {
                return WorkspaceContextFormatter.trimmed(String(rememberedTitle.dropFirst(prefix.count)))
            }
        }

        return nil
    }
}
