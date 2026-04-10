/// Lowest priority. When no tool is recognized and terminal progress
/// (OSC 9;4) indicates activity, assume the pane is running an
/// unrecognized agent process.
///
/// Maps to `PaneAuxiliaryState.swift:484-486` in the original normalizer.
struct GenericProgressReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard
            context.recognizedTool == nil,
            context.raw.terminalProgress?.state.indicatesActivity == true
        else {
            return draft
        }

        var draft = draft
        draft.runtimePhase = .running
        return draft
    }
}
