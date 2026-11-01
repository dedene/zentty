import Foundation

/// Sessions a History launch is starting but the live index can't show yet: while git recreates
/// the session's worktree, and from the launch until the agent registers in its pane (or
/// `launchTimeout` passes). Without this, a second ↩ in that gap, from this window or another,
/// would start a second process on the same session. One set for the whole process, so every
/// window's launcher shares it.
@MainActor
final class AgentHistorySessionReservations {
    static let shared = AgentHistorySessionReservations()
    /// How long a launched pane stands in for its session before the agent has registered.
    static let launchTimeout: TimeInterval = 20

    enum Reservation: Equatable {
        /// `git worktree add` runs for this session; it launches (or reroutes) when git finishes.
        case recreatingWorktree
        /// Launched into this pane; the agent has not shown up in the live index yet.
        case launched(windowID: WindowID, pane: WorklaneStore.LaunchedPane, expiresAt: Date)
    }

    private var reservations: [AgentHistorySessionKey: Reservation] = [:]

    init() {}

    /// The session's reservation, or nil when it has none or its launch reservation has expired.
    func reservation(for key: AgentHistorySessionKey, now: Date) -> Reservation? {
        guard let reservation = reservations[key] else {
            return nil
        }
        if case .launched(_, _, let expiresAt) = reservation, expiresAt <= now {
            reservations[key] = nil
            return nil
        }
        return reservation
    }

    func reserveRecreation(_ key: AgentHistorySessionKey) {
        reservations[key] = .recreatingWorktree
    }

    func reserveLaunch(
        _ key: AgentHistorySessionKey,
        windowID: WindowID,
        pane: WorklaneStore.LaunchedPane,
        now: Date
    ) {
        reservations[key] = .launched(windowID: windowID, pane: pane, expiresAt: now + Self.launchTimeout)
    }

    func release(_ key: AgentHistorySessionKey) {
        reservations[key] = nil
    }

    /// Drops a launch reservation once the session is live; a running recreation keeps its own.
    func releaseLaunch(_ key: AgentHistorySessionKey) {
        if case .launched = reservations[key] {
            reservations[key] = nil
        }
    }
}
