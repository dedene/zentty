/// When no explicit agent status is available, use the title-derived phase
/// as the runtime phase. This is the primary detection mechanism for Codex
/// when hooks aren't firing — the terminal title contains status words
/// that `codexTitlePhase(from:recognizedTool:)` parses upstream.
///
/// Maps to `PaneAuxiliaryState.swift:480-482` in the original normalizer.
struct FallbackTitleHeuristicReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard let titlePhase = context.titlePhase else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = titlePhase
        return draft
    }
}
