/// Lowest priority. A pane with no agent shows the status its program set
/// through OSC 9;4 (`PaneProgramStatus`). Any agent signal claims the draft
/// earlier in the pipeline, so hook status always wins.
struct ProgramStatusReducer: PresentationReducer {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft {
        guard let programStatus = Self.displayedProgramStatus(
            raw: context.raw,
            recognizedTool: context.recognizedTool
        ) else {
            return draft
        }

        var draft = draft
        switch programStatus.state {
        case .working:
            draft.runtimePhase = .running
        case .paused:
            draft.runtimePhase = .needsInput
        case .error:
            draft.runtimePhase = .unresolvedStop
        }
        return draft
    }

    /// The program status a pane presents: only when no agent owns it.
    static func displayedProgramStatus(
        raw: PaneRawState,
        recognizedTool: AgentTool?
    ) -> PaneProgramStatus? {
        guard recognizedTool == nil, raw.agentStatus == nil else {
            return nil
        }

        return raw.programStatus
    }
}
