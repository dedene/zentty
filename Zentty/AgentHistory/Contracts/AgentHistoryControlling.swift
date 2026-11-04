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
    /// Records first consent for `agents` and starts indexing. `agents` counts only while no
    /// consent is saved; over saved consent it just turns History on and keeps the saved agent
    /// choices, so offer choices only on a loaded, unconsented `status`. `completion` says
    /// whether it was saved, or refused because config.toml can't be trusted.
    func enable(agents: Set<AgentHistoryAgent>, completion: @escaping @MainActor (AgentHistoryStateChangeOutcome) -> Void)
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
    func enable(agents: Set<AgentHistoryAgent>) {
        enable(agents: agents) { _ in }
    }

    func setEnabled(_ enabled: Bool) {
        setEnabled(enabled) { _ in }
    }

    func setAgentEnabled(_ agent: AgentHistoryAgent, _ enabled: Bool) {
        setAgentEnabled(agent, enabled) { _ in }
    }
}

typealias AgentHistorySettingsBackend = AgentHistoryControlling
typealias AgentHistoryIndexServicing = AgentHistoryControlling
