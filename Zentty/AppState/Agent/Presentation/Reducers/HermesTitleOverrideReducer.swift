/// Hermes' TUI flips its title marker immediately when a prompt is submitted
/// or the turn returns to idle. Its hook events arrive later in the turn, so
/// trust the title as the current user-visible phase whenever it is present.
struct HermesTitleOverrideReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard
            context.recognizedTool == .hermes,
            let titlePhase = context.titlePhase
        else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = titlePhase
        return draft
    }
}
