/// Copilot and Codex emit OSC 9;4 progress sequences via libghostty.
/// CopilotHookBridge seeds agentStatus at `.idle` on sessionStart; Codex can
/// also be recognized by process/title before hooks arrive. This reducer lets
/// current OSC activity surface `.running` before the default hook-state mapper.
///
/// Maps to `PaneAuxiliaryState.swift:458-462` in the original normalizer.
struct CopilotOSCProgressReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard context.raw.terminalProgress?.state.indicatesActivity == true else {
            return draft
        }

        if context.recognizedTool == .copilot,
           context.raw.agentStatus?.state == .idle {
            var draft = draft
            draft.runtimePhase = .running
            return draft
        }

        if context.recognizedTool == .codex,
           !context.raw.codexInterruptSuppressionIsActive(),
           context.raw.agentStatus?.interactionKind.requiresHumanAttention != true,
           context.titlePhase == nil || context.titlePhase == .running || context.titlePhase == .starting {
            var draft = draft
            draft.runtimePhase = .running
            return draft
        }

        return draft
    }
}
