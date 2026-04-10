/// Highest priority. Copilot sets the terminal title to "Asking ..." when
/// an askuserquestion-style tool is active. This is more reliable than the
/// preToolUse hook and must win over both OSC activity and any stale hook
/// state.
///
/// Maps to `PaneAuxiliaryState.swift:428-430` in the original normalizer.
struct CopilotTitleNeedsInputReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard context.copilotTitleNeedsInput else {
            return draft
        }
        var draft = draft
        draft.runtimePhase = .needsInput
        return draft
    }
}
