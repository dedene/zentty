import Foundation

/// Machine conditions that pause backfill (low power, thermal pressure, a full disk).
///
/// The indexer reads `pauseReason` on its queue before each step and re-evaluates whenever the
/// `onChange` handler fires (from any thread). Live events keep running while paused.
protocol AgentHistorySystemConditions: AnyObject, Sendable {
    /// Why backfill should pause right now; nil = run.
    var pauseReason: AgentHistoryPauseReason? { get }
    /// Starts reporting changes. Calling it again replaces the handler.
    func startObserving(_ onChange: @escaping @Sendable () -> Void)
    /// Stops reporting; idempotent.
    func stopObserving()
}

/// Production conditions. Until the real power, thermal and disk monitoring lands it never
/// pauses.
final class LiveAgentHistorySystemConditions: AgentHistorySystemConditions {
    init() {}

    var pauseReason: AgentHistoryPauseReason? { nil }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {}

    func stopObserving() {}
}
