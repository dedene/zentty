/// A single step in the presentation normalization pipeline. Each reducer
/// inspects the raw state + context and may claim the `runtimePhase` in the
/// draft. Reducers must be pure: no side effects, no stored state.
///
/// The reducer pipeline is a first-writer-wins chain: the first reducer
/// that sets `draft.runtimePhase` to a non-nil value ends the chain.
/// All subsequent reducers are skipped.
protocol PresentationReducer: Sendable {
    func reduce(
        context: PresentationReducerContext,
        draft: PresentationDraft
    ) -> PresentationDraft
}
