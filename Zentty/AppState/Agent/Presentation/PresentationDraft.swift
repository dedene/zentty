/// Accumulator carried through the reducer pipeline. Each reducer may
/// claim the `runtimePhase` by setting it from nil to a value. Once
/// claimed, subsequent reducers should return the draft unchanged
/// (the pipeline short-circuits on the first claim).
struct PresentationDraft {
    /// nil until a reducer claims it. The pipeline resolves nil to `.idle`
    /// after all reducers have run.
    var runtimePhase: PanePresentationPhase?
}
