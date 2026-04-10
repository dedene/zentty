/// Default mapping from `PaneAgentStatus.state` to `PanePresentationPhase`.
/// Only fires when no higher-priority reducer (Codex promotion, Claude
/// override, Copilot OSC) has already claimed the draft. Maps each
/// `AgentStatusState` case directly to its presentation equivalent.
///
/// Maps to `PaneAuxiliaryState.swift:464-475` in the original normalizer.
struct ExplicitAgentStateReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard let agentState = context.raw.agentStatus?.state else {
            return draft
        }

        var draft = draft
        switch agentState {
        case .starting:
            draft.runtimePhase = .starting
        case .running:
            draft.runtimePhase = .running
        case .needsInput:
            draft.runtimePhase = .needsInput
        case .idle:
            draft.runtimePhase = .idle
        case .unresolvedStop:
            draft.runtimePhase = .unresolvedStop
        }
        return draft
    }
}
