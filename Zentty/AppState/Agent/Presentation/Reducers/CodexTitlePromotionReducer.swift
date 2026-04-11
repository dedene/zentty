import Foundation

/// Codex emits status words in the terminal title. When hooks report
/// `.starting` or `.idle` but the title indicates a more advanced phase
/// (`.running` or `.starting`), promote the runtime phase to the title's
/// phase. This lets the title "fill the gap" between hook events.
///
/// Maps to `PaneAuxiliaryState.swift:433-443` in the original normalizer.
struct CodexTitlePromotionReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard
            context.recognizedTool == .codex,
            let agentState = context.raw.agentStatus?.state,
            let titlePhase = context.titlePhase
        else {
            return draft
        }

        if let suppressionDeadline = context.raw.codexTitleIdleSuppressionUntil,
           suppressionDeadline > Date(),
           agentState == .idle,
           titlePhase == .running || titlePhase == .starting {
            return draft
        }

        if agentState == .starting {
            var draft = draft
            draft.runtimePhase = titlePhase
            return draft
        }

        if agentState == .idle,
           titlePhase == .running || titlePhase == .starting {
            var draft = draft
            draft.runtimePhase = titlePhase
            return draft
        }

        return draft
    }
}
