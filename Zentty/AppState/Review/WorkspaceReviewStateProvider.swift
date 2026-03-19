import Foundation

protocol WorkspaceReviewStateProvider: Sendable {
    func reviewState(for workspace: WorkspaceState, focusedPaneID: PaneID?) -> WorkspaceReviewState?
}

struct DefaultWorkspaceReviewStateProvider: WorkspaceReviewStateProvider {
    func reviewState(for workspace: WorkspaceState, focusedPaneID: PaneID?) -> WorkspaceReviewState? {
        guard let focusedPaneID else {
            return nil
        }

        let aux = workspace.auxiliaryStateByPaneID[focusedPaneID]
        let metadata = aux?.metadata
        let metadataBranch = displayableMetadataBranch(metadata?.gitBranch)
        let cachedState = sanitizedCachedState(
            aux?.reviewState,
            metadataBranch: metadataBranch
        )
        let explicitArtifact = pullRequestArtifact(from: aux?.agentStatus?.artifactLink)
        let inferredArtifact = pullRequestArtifact(from: aux?.inferredArtifact)
        let pullRequest = cachedState?.pullRequest ?? (explicitArtifact ?? inferredArtifact).flatMap(pullRequestSummary(from:))
        let branch = cachedState?.branch ?? metadataBranch
        let reviewChips = normalizedReviewChips(
            cachedState?.reviewChips ?? [],
            pullRequest: pullRequest
        )

        guard branch != nil || pullRequest != nil else {
            return nil
        }

        return WorkspaceReviewState(
            branch: branch,
            pullRequest: pullRequest,
            reviewChips: reviewChips
        )
    }

    private func sanitizedCachedState(
        _ cachedState: WorkspaceReviewState?,
        metadataBranch: String?
    ) -> WorkspaceReviewState? {
        guard var cachedState else {
            return nil
        }

        cachedState.branch = displayableMetadataBranch(cachedState.branch)

        if
            let metadataBranch,
            let cachedBranch = WorkspaceContextFormatter.trimmed(cachedState.branch),
            cachedBranch != metadataBranch
        {
            return nil
        }

        if cachedState.branch == nil {
            cachedState.branch = metadataBranch
        }

        return cachedState
    }

    private func pullRequestArtifact(from artifact: WorkspaceArtifactLink?) -> WorkspaceArtifactLink? {
        guard artifact?.kind == .pullRequest else {
            return nil
        }

        return artifact
    }

    private func pullRequestSummary(from artifact: WorkspaceArtifactLink) -> WorkspacePullRequestSummary? {
        guard let number = pullRequestNumber(from: artifact) else {
            return nil
        }

        return WorkspacePullRequestSummary(
            number: number,
            url: artifact.url,
            state: .open
        )
    }

    private func pullRequestNumber(from artifact: WorkspaceArtifactLink) -> Int? {
        let trimmedLabel = artifact.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directMatch = Self.trailingNumber(in: trimmedLabel) {
            return directMatch
        }

        let pathComponents = artifact.url.pathComponents.reversed()
        return pathComponents.compactMap(Int.init).first
    }

    private func normalizedReviewChips(
        _ reviewChips: [WorkspaceReviewChip],
        pullRequest: WorkspacePullRequestSummary?
    ) -> [WorkspaceReviewChip] {
        guard reviewChips.isEmpty, let pullRequest else {
            return reviewChips
        }

        switch pullRequest.state {
        case .draft:
            return [WorkspaceReviewChip(text: "Draft", style: .info)]
        case .open:
            return [WorkspaceReviewChip(text: "Ready", style: .success)]
        case .merged:
            return [WorkspaceReviewChip(text: "Merged", style: .success)]
        case .closed:
            return [WorkspaceReviewChip(text: "Closed", style: .neutral)]
        }
    }

    private static func trailingNumber(in value: String) -> Int? {
        guard let match = value.range(of: #"\d+$"#, options: .regularExpression) else {
            return nil
        }

        return Int(value[match])
    }

    private func displayableMetadataBranch(_ branch: String?) -> String? {
        let trimmedBranch = WorkspaceContextFormatter.trimmed(branch)
        guard !WorkspaceContextFormatter.looksCompactedForDisplay(trimmedBranch) else {
            return nil
        }

        return trimmedBranch
    }
}
