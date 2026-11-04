import Foundation

/// The indexer's timing rules in one place. Values are instance properties so tests can shrink
/// them; production uses the defaults.
///
/// Confined to the indexer queue (not thread-safe).
struct AgentHistoryReconcileSchedule: Sendable, Equatable {
    /// Delay between app launch and the indexer's first start.
    var launchDelay: TimeInterval = 5
    /// Periodic full reconcile.
    var interval: TimeInterval = 15 * 60
    /// Delay between wake from sleep and the reconcile it triggers (volumes and network settle).
    var wakeDelay: TimeInterval = 10
    /// Minimum spacing between two polls of the same database (opencode, Codex state).
    var dbPollMinInterval: TimeInterval = 2
    /// Retry cadence while paused on a full disk.
    var diskFullRetry: TimeInterval = 60
    /// Minimum spacing between two status/snapshot publishes (state changes publish immediately).
    var publishInterval: TimeInterval = 1
    /// A unit seen missing is deleted only if still missing this long after it was first seen (A-21).
    var missingGrace: TimeInterval = 30

    /// When the last full reconcile ran; nil until the first one.
    private(set) var lastReconcileAt: Date?

    init() {}

    mutating func recordReconcile(at date: Date) {
        lastReconcileAt = date
    }

    /// True before the first reconcile and once `interval` has passed since the last one.
    func isPeriodicReconcileDue(now: Date) -> Bool {
        guard let lastReconcileAt else {
            return true
        }
        return now.timeIntervalSince(lastReconcileAt) >= interval
    }

    /// When the next database poll may run. Leading edge: the first event (or one after a quiet
    /// period of at least `dbPollMinInterval`) polls `now`; events inside the window coalesce
    /// into one trailing poll at `lastPollAt + dbPollMinInterval`.
    func nextDatabasePoll(lastPollAt: Date?, now: Date) -> Date {
        guard let lastPollAt else {
            return now
        }
        let earliest = lastPollAt.addingTimeInterval(dbPollMinInterval)
        return earliest <= now ? now : earliest
    }

    /// True when a missing unit first seen at `firstSeenMissingAt` may be deleted at `now`.
    func isMissingGraceOver(firstSeenMissingAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(firstSeenMissingAt) >= missingGrace
    }
}
