enum WorklaneHeaderSummaryBuilder {
    static func summary(for worklane: WorklaneState) -> WorklaneChromeSummary {
        let focusedPaneContext = worklane.focusedPaneContext
        let presentation = focusedPaneContext?.presentation
        let focusedLabel = visibleFocusedLabel(from: presentation)
        let branch = visibleBranch(from: presentation)

        return WorklaneChromeSummary(
            attention: WorklaneAttentionSummaryBuilder.summary(for: worklane),
            focusedLabel: focusedLabel,
            cwdPath: WorklaneContextFormatter.trimmed(presentation?.cwd),
            branch: branch,
            branchURL: presentation?.branchURL,
            pullRequest: presentation?.pullRequest,
            reviewChips: presentation?.reviewChips ?? []
        )
    }

    private static func visibleFocusedLabel(from presentation: PanePresentationState?) -> String? {
        guard
            let presentation,
            let rememberedTitle = WorklaneContextFormatter.trimmed(presentation.rememberedTitle)
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
        if let cwd = WorklaneContextFormatter.trimmed(presentation.cwd) {
            let formattedWorkingDirectory = WorklaneContextFormatter.formattedWorkingDirectory(cwd, branch: nil)
            if presentation.lookupBranch != nil,
               formattedWorkingDirectory?.hasPrefix("~/󰲋") == true,
               let compactRepositoryPath = WorklaneContextFormatter.compactRepositorySidebarPath(cwd) {
                return compactRepositoryPath
            }

            return formattedWorkingDirectory
        }

        return WorklaneContextFormatter.trimmed(presentation.visibleIdentityText)
    }

    private static func visibleBranch(from presentation: PanePresentationState?) -> String? {
        guard let presentation else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(presentation.branchDisplayText)
    }

    private static func decomposedRememberedTitle(
        _ rememberedTitle: String,
        presentation: PanePresentationState
    ) -> String? {
        guard
            let branch = WorklaneContextFormatter.trimmed(presentation.branchDisplayText)
        else {
            return nil
        }

        for separator in [" · ", " • "] {
            let prefix = branch + separator
            if rememberedTitle.hasPrefix(prefix) {
                return WorklaneContextFormatter.trimmed(String(rememberedTitle.dropFirst(prefix.count)))
            }
        }

        return nil
    }
}
