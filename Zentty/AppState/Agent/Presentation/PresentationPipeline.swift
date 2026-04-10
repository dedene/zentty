/// Ordered chain of `PresentationReducer`s that resolves a
/// `PanePresentationPhase` from raw pane state. The pipeline is assembled
/// once and reused for every normalization pass.
///
/// **Precedence is encoded by array order.** The first reducer whose
/// `reduce(context:draft:)` sets `draft.runtimePhase` wins — all later
/// reducers are skipped. Adding a new signal means inserting a reducer at
/// the right position in the array, not editing a nested conditional.
///
/// Reducers 1–4 are **tool-specific overrides** that read context signals
/// (`context.copilotTitleNeedsInput`, `context.titlePhase`,
/// `context.recognizedTool`) to claim the phase directly. They do NOT
/// depend on each other — each checks raw context, not the draft.
/// Reducer 5 is the default hook-state mapping. Reducers 6–7 are
/// fallbacks when no hook data exists.
///
/// ```
/// 1. CopilotTitleNeedsInputReducer   — Copilot title "Asking…" → needsInput
/// 2. CodexTitlePromotionReducer       — Codex title promotes starting/idle
/// 3. ClaudeCodeTitleOverrideReducer   — Claude title overrides running→idle
/// 4. CopilotOSCProgressReducer        — Copilot OSC upgrades idle→running
/// 5. ExplicitAgentStateReducer        — default agentStatus.state mapping
/// 6. FallbackTitleHeuristicReducer    — title-based phase when no hooks
/// 7. GenericProgressReducer           — unknown tool + OSC → running
/// ```
struct PresentationPipeline: Sendable {
    let reducers: [any PresentationReducer & Sendable]

    /// Resolve the runtime phase for a pane. Returns `.idle` when no
    /// reducer claims the draft.
    func resolve(context: PresentationReducerContext) -> PanePresentationPhase {
        var draft = PresentationDraft()
        for reducer in reducers {
            draft = reducer.reduce(context: context, draft: draft)
            if draft.runtimePhase != nil {
                break
            }
        }
        return draft.runtimePhase ?? .idle
    }

    /// The standard pipeline matching the precedence rules in the original
    /// `normalizedRuntimePhase(from:recognizedTool:titlePhase:copilotTitleNeedsInput:)`.
    static let standard = PresentationPipeline(reducers: [
        CopilotTitleNeedsInputReducer(),
        CodexTitlePromotionReducer(),
        ClaudeCodeTitleOverrideReducer(),
        CopilotOSCProgressReducer(),
        ExplicitAgentStateReducer(),
        FallbackTitleHeuristicReducer(),
        GenericProgressReducer(),
    ])
}
