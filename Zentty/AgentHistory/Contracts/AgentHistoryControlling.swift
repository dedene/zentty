import Foundation

/// The one control surface over Agent History that the palette and Settings use (A-11).
/// `AgentHistoryController` conforms in `AgentHistoryController+Controlling.swift`; tests use fakes.
///
/// Retention and excluded-folder edits are not here: callers go to `ClaudeRetentionSettings` and
/// the config store directly (through injected closures in tests).
@MainActor
protocol AgentHistoryControlling: AnyObject {
    var status: AgentHistoryStatus { get }
    @discardableResult func addStatusObserver(_ handler: @escaping @MainActor (AgentHistoryStatus) -> Void) -> UUID
    func removeObserver(_ id: UUID)
    /// Recounts off-main, then notifies the status observers.
    func refreshStatus()
    /// Which agents have history on this Mac, stat-only (D11).
    func detectSources(_ completion: @escaping @MainActor ([AgentHistoryDetectedSource]) -> Void)
    /// Records consent for `agents` and starts indexing.
    func enable(agents: Set<AgentHistoryAgent>)
    /// `completion` says whether `state.json` saved the change; off takes effect either way.
    func setEnabled(_ enabled: Bool, completion: @escaping @MainActor (AgentHistoryStateChangeOutcome) -> Void)
    /// Off purges that agent's rows (D4).
    func setAgentEnabled(
        _ agent: AgentHistoryAgent,
        _ enabled: Bool,
        completion: @escaping @MainActor (AgentHistoryStateChangeOutcome) -> Void
    )
    /// `deleteIndex: true` is "Delete Index and Turn Off" (also removes consent, D8).
    func disable(deleteIndex: Bool, completion: @escaping @MainActor (AgentHistoryDisableOutcome) -> Void)
    func rebuildIndex()
    func restoreAllRemovedSessions()
    func removeSession(_ key: AgentHistorySessionKey)
}

extension AgentHistoryControlling {
    func setEnabled(_ enabled: Bool) {
        setEnabled(enabled) { _ in }
    }

    func setAgentEnabled(_ agent: AgentHistoryAgent, _ enabled: Bool) {
        setAgentEnabled(agent, enabled) { _ in }
    }
}

typealias AgentHistorySettingsBackend = AgentHistoryControlling
typealias AgentHistoryIndexServicing = AgentHistoryControlling
