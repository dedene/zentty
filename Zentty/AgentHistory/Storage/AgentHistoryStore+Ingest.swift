import Foundation

/// Applying ingest batches, purges and the counts the indexer and status need.
extension AgentHistoryStore {
    /// Writes one adapter batch atomically (its own transaction, or a savepoint inside the
    /// caller's): upsert sessions (setting `unit_key`; with `updatesExistingSessionsOnly`, only
    /// stored sessions, `unit_key` kept) → clear `replaceContentOf` → upsert
    /// messages and artifacts → delete `removedNativeIDs` → recount turns of touched sessions.
    /// Messages and artifacts whose session is neither in the batch nor stored are dropped.
    @discardableResult
    func apply(_ batch: AgentHistoryIngestBatch, sourceID: Int64, unitKey: String) throws -> AgentHistoryApplyResult {
        try database.transaction {
            var result = AgentHistoryApplyResult()
            var rowIDs: [String: Int64] = [:]
            func resolve(_ nativeID: String) throws -> Int64? {
                if let id = rowIDs[nativeID] { return id }
                let id = try sessionID(sourceID: sourceID, nativeID: nativeID)
                rowIDs[nativeID] = id
                return id
            }

            var messageBounds: [String: (first: Int64, last: Int64)] = [:]
            for message in batch.messages {
                let bounds = messageBounds[message.sessionNativeID]
                messageBounds[message.sessionNativeID] = (
                    min(bounds?.first ?? message.atMs, message.atMs),
                    max(bounds?.last ?? message.atMs, message.atMs)
                )
            }

            for draft in batch.sessions {
                if batch.updatesExistingSessionsOnly, try resolve(draft.nativeID) == nil {
                    continue
                }
                let bounds = messageBounds[draft.nativeID]
                let id = try upsertSession(
                    sourceID: sourceID, unitKey: batch.updatesExistingSessionsOnly ? nil : unitKey, draft,
                    firstMessageAtMs: bounds?.first, lastMessageAtMs: bounds?.last
                )
                rowIDs[draft.nativeID] = id
                result.touchedSessionIDs.insert(id)
            }

            for nativeID in batch.replaceContentOf.sorted() {
                guard let id = try resolve(nativeID) else { continue }
                try deleteSessionContent(sessionID: id)
                result.touchedSessionIDs.insert(id)
            }

            var dropped = 0
            for (nativeID, messages) in Dictionary(grouping: batch.messages, by: \.sessionNativeID) {
                guard let id = try resolve(nativeID) else { dropped += messages.count; continue }
                try upsertMessages(sessionID: id, messages.sorted { $0.seq < $1.seq })
                result.touchedSessionIDs.insert(id)
            }
            for (nativeID, artifacts) in Dictionary(grouping: batch.artifacts, by: \.sessionNativeID) {
                guard let id = try resolve(nativeID) else { dropped += artifacts.count; continue }
                try upsertArtifacts(sessionID: id, artifacts.sorted { $0.seq < $1.seq })
                result.touchedSessionIDs.insert(id)
            }
            if dropped > 0 {
                AgentHistoryLog.indexer.info("Dropped \(dropped, privacy: .public) rows without a session")
            }

            if !batch.removedNativeIDs.isEmpty {
                let removed = try deleteSessions(sourceID: sourceID, nativeIDs: batch.removedNativeIDs)
                result.removedSessionIDs.formUnion(removed)
                result.touchedSessionIDs.subtract(removed)
            }

            for id in result.touchedSessionIDs {
                try refreshTurnCount(sessionID: id)
            }
            return result
        }
    }

    // MARK: - Purges

    /// Clears messages and artifacts of every session stored for a unit (a whole-unit rewrite).
    func deleteSessionContent(sourceID: Int64, unitKey: String) throws {
        try database.transaction {
            for id in try sessionIDs(sourceID: sourceID, unitKey: unitKey) {
                try deleteSessionContent(sessionID: id)
            }
        }
    }

    /// Deletes every session stored for a unit; returns their ids.
    func deleteSessions(sourceID: Int64, unitKey: String) throws -> [Int64] {
        try database.transaction {
            let ids = try sessionIDs(sourceID: sourceID, unitKey: unitKey)
            try database.run("DELETE FROM sessions WHERE source_id = ? AND unit_key = ?",
                             [.integer(sourceID), .text(unitKey)])
            return ids
        }
    }

    /// Deletes the named sessions of a source; returns the ids that existed.
    func deleteSessions(sourceID: Int64, nativeIDs: Set<String>) throws -> [Int64] {
        try database.transaction {
            var removed: [Int64] = []
            for nativeID in nativeIDs.sorted() {
                guard let id = try sessionID(sourceID: sourceID, nativeID: nativeID) else { continue }
                try deleteSession(id: id)
                removed.append(id)
            }
            return removed
        }
    }

    /// Deletes sessions whose stored (canonical) `cwd` is one of `folders` or below it, on a `/`
    /// boundary and case-sensitively: the SQL twin of `AgentHistoryExclusionMatcher`.
    /// `folders` must be canonical (`AgentHistoryExclusionMatcher.canonicalFolders`).
    func deleteSessions(underFolders folders: [String]) throws -> [(rowID: Int64, sourceID: Int64, unitKey: String?)] {
        try database.transaction {
            var seen = Set<Int64>()
            var removed: [(rowID: Int64, sourceID: Int64, unitKey: String?)] = []
            for folder in folders where folder.hasPrefix("/") {
                let rows = try database.query(
                    """
                    SELECT id, source_id, unit_key FROM sessions
                    WHERE cwd IS NOT NULL AND (
                      (?1 = '/' AND substr(cwd, 1, 1) = '/')
                      OR cwd = ?1
                      OR substr(cwd, 1, length(?1) + 1) = ?1 || '/'
                    )
                    """,
                    [.text(folder)]
                ) { (rowID: $0.int64(0), sourceID: $0.int64(1), unitKey: $0.optionalString(2)) }
                for row in rows where seen.insert(row.rowID).inserted {
                    try deleteSession(id: row.rowID)
                    removed.append(row)
                }
            }
            return removed
        }
    }

    /// Deletes the sessions of `sourceIDs` that have no stored `cwd` (adapters that hold such
    /// sessions back while any folder is excluded).
    func deleteSessionsWithoutFolder(sourceIDs: [Int64]) throws -> [(rowID: Int64, sourceID: Int64, unitKey: String?)] {
        try database.transaction {
            var removed: [(rowID: Int64, sourceID: Int64, unitKey: String?)] = []
            for sourceID in sourceIDs {
                let rows = try database.query(
                    "SELECT id, source_id, unit_key FROM sessions WHERE source_id = ? AND cwd IS NULL",
                    [.integer(sourceID)]
                ) { (rowID: $0.int64(0), sourceID: $0.int64(1), unitKey: $0.optionalString(2)) }
                for row in rows {
                    try deleteSession(id: row.rowID)
                    removed.append(row)
                }
            }
            return removed
        }
    }

    /// Deletes every session of a source (source turned off, or its root gone twice).
    func deleteSessions(sourceID: Int64) throws -> [Int64] {
        try database.transaction {
            let ids = try database.query("SELECT id FROM sessions WHERE source_id = ?", [.integer(sourceID)]) {
                $0.int64(0)
            }
            try database.run("DELETE FROM sessions WHERE source_id = ?", [.integer(sourceID)])
            return ids
        }
    }

    // MARK: - Counts and lookups

    func hasSessions(sourceID: Int64, unitKey: String) throws -> Bool {
        try database.scalarInt64(
            "SELECT 1 FROM sessions WHERE source_id = ? AND unit_key = ? LIMIT 1",
            [.integer(sourceID), .text(unitKey)]
        ) != nil
    }

    func indexedNativeIDs(sourceID: Int64) throws -> Set<String> {
        Set(try database.query("SELECT native_id FROM sessions WHERE source_id = ?", [.integer(sourceID)]) {
            $0.string(0)
        })
    }

    /// All stored sessions of a source, visible or not.
    func sessionCount(sourceID: Int64) throws -> Int {
        Int(try database.scalarInt64("SELECT count(*) FROM sessions WHERE source_id = ?", [.integer(sourceID)]) ?? 0)
    }

    func visibleSessionCount() throws -> Int {
        Int(try database.scalarInt64(
            "SELECT count(*) FROM sessions s WHERE \(AgentHistorySQL.visibleSessionPredicate)"
        ) ?? 0)
    }

    /// Counts one open (resume, jump or fork). Returns false when the row no longer exists.
    func recordOpen(sessionID: Int64, atMs: Int64) throws -> Bool {
        try database.run(
            """
            UPDATE sessions
            SET opens = opens + 1,
                last_opened_at = CASE WHEN last_opened_at IS NULL OR last_opened_at < ?2
                                      THEN ?2 ELSE last_opened_at END
            WHERE id = ?1
            """,
            [.integer(sessionID), .integer(atMs)]
        )
        return database.changes > 0
    }

    // MARK: - Summaries

    /// Summaries of the given rows that are still visible (`AgentHistorySQL.visibleSessionPredicate`),
    /// in input order without duplicates. A missing id was deleted or became hidden (child,
    /// no turns): callers drop it from their snapshot.
    func sessionSummaries(rowIDs: some Sequence<Int64>) throws -> [AgentHistorySessionSummary] {
        var order: [Int64] = []
        var seen = Set<Int64>()
        for id in rowIDs where seen.insert(id).inserted {
            order.append(id)
        }
        guard !order.isEmpty else { return [] }

        var byID: [Int64: AgentHistorySessionSummary] = [:]
        let chunkSize = Self.summaryChunkSize
        let placeholders = Array(repeating: "?", count: chunkSize).joined(separator: ", ")
        let sql = AgentHistorySessionSummary.selectSQL
            + " WHERE s.id IN (\(placeholders)) AND \(AgentHistorySQL.visibleSessionPredicate)"
        try database.readTransaction {
            var start = 0
            while start < order.count {
                let chunk = order[start..<min(start + chunkSize, order.count)]
                // Padding with NULL keeps one statement text, so the prepared statement is reused.
                var bindings = chunk.map { AgentHistoryValue.integer($0) }
                bindings += Array(repeating: AgentHistoryValue.null, count: chunkSize - chunk.count)
                for summary in try database.query(sql, bindings, map: AgentHistorySessionSummary.init(row:)) {
                    byID[summary.id] = summary
                }
                start += chunkSize
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Every visible session, most recently updated first.
    func allVisibleSessionSummaries() throws -> [AgentHistorySessionSummary] {
        try database.query(
            AgentHistorySessionSummary.selectSQL
                + " WHERE \(AgentHistorySQL.visibleSessionPredicate) ORDER BY s.updated_at DESC, s.id DESC",
            map: AgentHistorySessionSummary.init(row:)
        )
    }

    static let summaryChunkSize = 128

    // MARK: - Internals

    private func sessionIDs(sourceID: Int64, unitKey: String) throws -> [Int64] {
        try database.query(
            "SELECT id FROM sessions WHERE source_id = ? AND unit_key = ?",
            [.integer(sourceID), .text(unitKey)]
        ) { $0.int64(0) }
    }
}
