enum WorklaneHeaderSummaryBuilder {
    static func summary(for worklane: WorklaneState) -> WorklaneChromeSummary {
        let focusedPaneContext = worklane.focusedPaneContext
        let presentation = focusedPaneContext?.presentation
        let metadata = focusedPaneContext?.metadata
        let focusedLabel = visibleFocusedLabel(from: presentation, metadata: metadata)
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

    private static func visibleFocusedLabel(
        from presentation: PanePresentationState?,
        metadata: TerminalMetadata?
    ) -> String? {
        // When the focused codex pane is in a volatile agent status state
        // (e.g. "Working... (5s) · my-project"), surface the raw codex title
        // in the chrome so the title bar ticks in realtime alongside the
        // sidebar row. This mirrors WorklaneSidebarSummaryBuilder.paneIdentity
        // which also reads metadata?.title directly for codex volatile titles.
        if presentation?.recognizedTool == .codex,
           let volatileTitle = WorklaneContextFormatter.trimmed(metadata?.title),
           TerminalMetadataChangeClassifier.isVolatileAgentStatusTitle(
               volatileTitle,
               recognizedTool: .codex
           ) {
            return volatileTitle
        }

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
               WorklaneContextFormatter.isDeveloperRootPath(cwd),
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
