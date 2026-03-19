import Foundation

enum WorkspaceArtifactLinkResolver {
    static func bestLink(
        explicit: WorkspaceArtifactLink?,
        inferred: WorkspaceArtifactLink?
    ) -> WorkspaceArtifactLink? {
        [explicit, inferred]
            .compactMap { $0 }
            .max { left, right in
                left.priority < right.priority
            }
    }
}

enum WorkspaceAttentionSummaryBuilder {
    static func summary(for workspace: WorkspaceState) -> WorkspaceAttentionSummary? {
        workspace.paneStripState.panes
            .compactMap { pane in
                summary(for: pane, in: workspace)
            }
            .sorted(by: preferred(lhs:rhs:))
            .first
    }

    private static func summary(
        for pane: PaneState,
        in workspace: WorkspaceState
    ) -> WorkspaceAttentionSummary? {
        let aux = workspace.auxiliaryStateByPaneID[pane.id]
        guard let status = aux?.agentStatus else {
            return nil
        }

        let metadata = aux?.metadata
        let primaryText = status.tool.displayName
        let artifactLink = WorkspaceArtifactLinkResolver.bestLink(
            explicit: status.artifactLink,
            inferred: aux?.inferredArtifact
        )

        return WorkspaceAttentionSummary(
            paneID: pane.id,
            tool: status.tool,
            state: workspaceState(for: status.state),
            primaryText: primaryText,
            statusText: status.statusText,
            contextText: WorkspaceContextFormatter.paneDetailLine(
                metadata: metadata,
                fallbackTitle: pane.title
            ) ?? "",
            artifactLink: artifactLink,
            updatedAt: status.updatedAt
        )
    }

    private static func workspaceState(for state: PaneAgentState) -> WorkspaceAttentionState {
        switch state {
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .running:
            return .running
        case .completed:
            return .completed
        }
    }

    private static func preferred(lhs: WorkspaceAttentionSummary, rhs: WorkspaceAttentionSummary) -> Bool {
        if lhs.state.priority != rhs.state.priority {
            return lhs.state.priority > rhs.state.priority
        }

        return lhs.updatedAt > rhs.updatedAt
    }
}

private extension WorkspaceAttentionState {
    var priority: Int {
        switch self {
        case .needsInput:
            return 4
        case .unresolvedStop:
            return 3
        case .running:
            return 2
        case .completed:
            return 1
        }
    }
}
