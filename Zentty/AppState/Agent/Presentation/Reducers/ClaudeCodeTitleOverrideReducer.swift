/// When Claude Code's hook says `.running` but the terminal title says
/// `.idle` (e.g., after Ctrl+C interruption), trust the title as more
/// current and override to `.idle`.
///
/// Maps to `PaneAuxiliaryState.swift:447-451` in the original normalizer.
struct ClaudeCodeTitleOverrideReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard
            context.recognizedTool == .claudeCode,
            context.raw.agentStatus?.state == .running,
            context.titlePhase == .idle
        else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = .idle
        return draft
    }
}
