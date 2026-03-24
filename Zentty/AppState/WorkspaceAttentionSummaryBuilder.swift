import Foundation

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
        guard let paneContext = workspace.paneContext(for: pane.id) else {
            return nil
        }

        let presentation = paneContext.presentation
        guard
            let attentionState = attentionState(for: presentation.runtimePhase),
            let tool = presentation.recognizedTool
        else {
            return nil
        }

        return WorkspaceAttentionSummary(
            paneID: pane.id,
            tool: tool,
            state: attentionState,
            primaryText: presentation.visibleIdentityText ?? "Shell",
            statusText: presentation.statusText ?? "",
            contextText: presentation.contextText ?? "",
            artifactLink: presentation.attentionArtifactLink,
            updatedAt: presentation.updatedAt
        )
    }

    private static func attentionState(for phase: PanePresentationPhase) -> WorkspaceAttentionState? {
        switch phase {
        case .idle, .starting:
            return nil
        case .running:
            return .running
        case .needsInput:
            return .needsInput
        case .completed:
            return .completed
        case .unresolvedStop:
            return .unresolvedStop
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
