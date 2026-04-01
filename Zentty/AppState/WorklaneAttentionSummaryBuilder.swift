import Foundation

enum WorklaneAttentionSummaryBuilder {
    static func summary(for worklane: WorklaneState) -> WorklaneAttentionSummary? {
        worklane.paneStripState.panes
            .compactMap { pane in
                summary(for: pane, in: worklane)
            }
            .sorted(by: preferred(lhs:rhs:))
            .first
    }

    private static func summary(
        for pane: PaneState,
        in worklane: WorklaneState
    ) -> WorklaneAttentionSummary? {
        guard let paneContext = worklane.paneContext(for: pane.id) else {
            return nil
        }

        let presentation = paneContext.presentation
        guard
            let attentionState = attentionState(for: presentation),
            let tool = presentation.recognizedTool
        else {
            return nil
        }

        return WorklaneAttentionSummary(
            paneID: pane.id,
            tool: tool,
            state: attentionState,
            interactionKind: presentation.interactionKind,
            interactionLabel: presentation.interactionLabel ?? presentation.interactionKind?.defaultLabel,
            primaryText: presentation.visibleIdentityText ?? "Shell",
            statusText: presentation.statusText ?? "",
            contextText: presentation.contextText ?? "",
            artifactLink: presentation.attentionArtifactLink,
            interactionSymbolName: presentation.interactionSymbolName ?? presentation.interactionKind?.defaultSymbolName,
            updatedAt: presentation.updatedAt
        )
    }

    private static func attentionState(for presentation: PanePresentationState) -> WorklaneAttentionState? {
        if presentation.isReady {
            return .ready
        }

        switch presentation.runtimePhase {
        case .idle, .starting:
            return nil
        case .running:
            return .running
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        }
    }

    private static func preferred(lhs: WorklaneAttentionSummary, rhs: WorklaneAttentionSummary) -> Bool {
        if lhs.state.priority != rhs.state.priority {
            return lhs.state.priority > rhs.state.priority
        }

        return lhs.updatedAt > rhs.updatedAt
    }
}

private extension WorklaneAttentionState {
    var priority: Int {
        switch self {
        case .needsInput:
            return 4
        case .unresolvedStop:
            return 3
        case .ready:
            return 2
        case .running:
            return 1
        }
    }
}
