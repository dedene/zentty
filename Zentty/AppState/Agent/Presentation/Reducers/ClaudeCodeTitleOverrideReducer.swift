/// When Claude Code's hook says `.running` but the terminal title says
/// `.idle` (e.g., after Ctrl+C interruption), trust the title as more
/// current and override to `.idle`. Only once the title has been seen
/// animating: under a terminal multiplexer Claude keeps a static "✳" title
/// for the whole turn.
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
            context.titlePhase == .idle,
            context.raw.claudeCodeTitleHasAnimated,
            !context.raw.agentReducerState.sessionsByID.values.contains(where: { session in
                session.tool == .claudeCode && session.completionCandidateDeadline != nil
            })
        else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = .idle
        return draft
    }
}
