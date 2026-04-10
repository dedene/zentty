/// Copilot emits OSC 9;4 progress sequences via libghostty.
/// CopilotHookBridge seeds agentStatus at `.idle` on sessionStart; this
/// reducer lets OSC flip to `.running` for the duration of a turn, then
/// back to idle. Copilot has no "turn complete" hook, so OSC is the
/// source of truth for running.
///
/// Maps to `PaneAuxiliaryState.swift:458-462` in the original normalizer.
struct CopilotOSCProgressReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard
            context.recognizedTool == .copilot,
            context.raw.agentStatus?.state == .idle,
            context.raw.terminalProgress?.state.indicatesActivity == true
        else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = .running
        return draft
    }
}
