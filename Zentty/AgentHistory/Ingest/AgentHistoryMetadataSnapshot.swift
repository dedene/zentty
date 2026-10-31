import Foundation

/// An immutable copy of every visible session, newest `updatedAtMs` first. The metadata search
/// tier reads it without touching SQLite; `generation` changes with every build so readers can
/// cache derived data per generation.
struct AgentHistoryMetadataSnapshot: Sendable {
    let generation: UInt64
    /// Visible sessions only (not a child, at least one turn), `updatedAtMs` desc, then id desc.
    let sessions: [AgentHistorySessionSummary]
    /// False while the first backfill is still running.
    let isComplete: Bool

    static let empty = AgentHistoryMetadataSnapshot(generation: 0, sessions: [], isComplete: false)
}

/// Keeps the indexer's working set of session summaries and turns it into snapshots.
///
/// Confined to the indexer queue (not thread-safe). Summaries come from the store's
/// `sessionSummaries(rowIDs:)` / `allVisibleSessionSummaries()`, which already apply
/// `AgentHistorySQL.visibleSessionPredicate`; the builder additionally drops summaries without
/// turns so a row that lost its last user message disappears on upsert.
struct AgentHistoryMetadataSnapshotBuilder: Sendable {
    private var sessionsByID: [Int64: AgentHistorySessionSummary] = [:]
    private(set) var generation: UInt64

    init(generation: UInt64 = AgentHistoryMetadataSnapshot.empty.generation) {
        self.generation = generation
    }

    var count: Int { sessionsByID.count }

    func contains(rowID: Int64) -> Bool {
        sessionsByID[rowID] != nil
    }

    /// Replaces the whole working set (start, rebuild).
    mutating func replaceAll(_ sessions: some Sequence<AgentHistorySessionSummary>) {
        sessionsByID.removeAll(keepingCapacity: true)
        upsert(sessions)
    }

    /// Inserts or replaces by row id; summaries that are not visible are removed instead.
    mutating func upsert(_ sessions: some Sequence<AgentHistorySessionSummary>) {
        for session in sessions {
            if Self.isVisible(session) {
                sessionsByID[session.id] = session
            } else {
                sessionsByID[session.id] = nil
            }
        }
    }

    mutating func remove(rowIDs: some Sequence<Int64>) {
        for id in rowIDs {
            sessionsByID[id] = nil
        }
    }

    /// A new snapshot with the next generation.
    mutating func build(isComplete: Bool) -> AgentHistoryMetadataSnapshot {
        generation &+= 1
        let sorted = sessionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAtMs != rhs.updatedAtMs {
                return lhs.updatedAtMs > rhs.updatedAtMs
            }
            return lhs.id > rhs.id
        }
        return AgentHistoryMetadataSnapshot(generation: generation, sessions: sorted, isComplete: isComplete)
    }

    private static func isVisible(_ session: AgentHistorySessionSummary) -> Bool {
        session.turnCount > 0
    }
}
