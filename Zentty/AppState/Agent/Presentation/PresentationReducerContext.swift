/// All inputs needed by presentation reducers to determine the runtime
/// phase. Assembled once per normalization pass from the pane's raw state
/// and passed through the reducer pipeline immutably.
struct PresentationReducerContext {
    let raw: PaneRawState
    let recognizedTool: AgentTool?
    let titlePhase: PanePresentationPhase?
    let copilotTitleNeedsInput: Bool
}
