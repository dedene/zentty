enum WorklaneHeaderSummaryBuilder {
    static func summary(for worklane: WorklaneState) -> WorklaneChromeSummary {
        let focusedPaneContext = worklane.focusedPaneContext
        let presentation = focusedPaneContext?.presentation
        let metadata = focusedPaneContext?.metadata
        let focusedLabel = visibleFocusedLabel(
            from: focusedPaneContext?.pane,
            presentation: presentation,
            metadata: metadata
        )
        let remoteContextLabel = visibleRemoteContextLabel(from: presentation)
        let branch = visibleBranch(from: presentation)

        return WorklaneChromeSummary(
            attention: WorklaneAttentionSummaryBuilder.summary(for: worklane),
            worklaneTitle: worklane.title,
            focusedLabel: focusedLabel,
            remoteContextLabel: remoteContextLabel,
            cwdPath: visibleLocalCwdPath(from: presentation),
            branch: branch,
            branchURL: presentation?.branchURL,
            pullRequest: presentation?.pullRequest,
            reviewChips: presentation?.reviewChips ?? []
        )
    }

    private static func visibleFocusedLabel(
        from pane: PaneState?,
        presentation: PanePresentationState?,
        metadata: TerminalMetadata?
    ) -> String? {
        if let pane, let presentation,
           let primaryLabel = PaneDisplayIdentityResolver.primaryLabel(
               pane: pane,
               presentation: presentation,
               metadata: metadata
           ) {
            return primaryLabel
        }

        return presentation.flatMap(visibleFallbackLabel(from:))
    }

    private static func visibleFallbackLabel(from presentation: PanePresentationState) -> String? {
        if let sshConnectionLabel = WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel) {
            return sshConnectionLabel
        }

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

        guard presentation.hasInferredSSHConnection == false else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(presentation.branchDisplayText)
    }

    private static func visibleRemoteContextLabel(from presentation: PanePresentationState?) -> String? {
        guard let presentation, presentation.isRemoteShell else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(presentation.remoteLocationLabel)
    }

    private static func visibleLocalCwdPath(from presentation: PanePresentationState?) -> String? {
        guard let presentation,
              !presentation.isRemoteShell,
              !presentation.hasInferredSSHConnection else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(presentation.cwd)
    }

}
