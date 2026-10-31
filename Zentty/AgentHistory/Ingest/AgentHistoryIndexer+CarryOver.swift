import Foundation

/// What a rebuild or a corruption recovery carries from the old index into the new one (§3.19,
/// D23): removals stay removed and usage (`opens`, `last_opened_at`) comes back on the
/// re-ingested rows through `usage_carryover`.
struct AgentHistoryRebuildCarryOver: Sendable {
    struct Tombstone: Sendable {
        let key: AgentHistorySessionKey
        let removedAtMs: Int64
    }

    struct Usage: Sendable {
        let key: AgentHistorySessionKey
        let opens: Int64
        let lastOpenedAtMs: Int64?
    }

    var tombstones: [Tombstone] = []
    var usage: [Usage] = []

    var isEmpty: Bool {
        tombstones.isEmpty && usage.isEmpty
    }

    /// Union by session key: the first removal time seen wins, usage keeps the larger values.
    mutating func merge(_ other: AgentHistoryRebuildCarryOver) {
        var removals = Dictionary(tombstones.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for tombstone in other.tombstones where removals[tombstone.key] == nil {
            removals[tombstone.key] = tombstone
        }
        var usageByKey: [AgentHistorySessionKey: Usage] = [:]
        for entry in usage + other.usage {
            guard let existing = usageByKey[entry.key] else {
                usageByKey[entry.key] = entry
                continue
            }
            usageByKey[entry.key] = Usage(
                key: entry.key,
                opens: max(existing.opens, entry.opens),
                lastOpenedAtMs: [existing.lastOpenedAtMs, entry.lastOpenedAtMs].compactMap { $0 }.max()
            )
        }
        let order = { (lhs: AgentHistorySessionKey, rhs: AgentHistorySessionKey) in
            (lhs.agent.rawValue, lhs.nativeID) < (rhs.agent.rawValue, rhs.nativeID)
        }
        tombstones = removals.values.sorted { order($0.key, $1.key) }
        usage = usageByKey.values.sorted { order($0.key, $1.key) }
    }
}

/// Rebuild and the carry-over of tombstones and usage. Indexer queue only.
///
/// The carry-over is collected before the index file goes away (Rebuild, corruption recovery)
/// from every place that still knows it: the open index, else the old file opened read-only
/// (a failed index, a newer schema), plus what this run holds in memory (tombstones in force,
/// usage in the snapshot). `startOnQueue` writes it into the new file before it reconciles, and
/// the tombstones are in force even when that write fails; a failed write is retried when the
/// indexer goes idle.
extension AgentHistoryIndexer {
    // MARK: - Rebuild

    /// Collect the carry-over → close the writer → close readers → remove the index files →
    /// reopen through `startOnQueue`, which writes the carry-over into the new file before it
    /// loads tombstones and reconciles every source.
    func rebuildOnQueue() {
        guard lifecycle == .running || lifecycle == .failed, !cancellation.isSet else {
            return
        }
        // Deleting files another instance writes would orphan its writer (a failed indexer
        // released the lock).
        if writerLock?.isHeld != true {
            do {
                writerLock = try storage.acquireWriterLock(timeout: writerLockWait)
            } catch {
                AgentHistoryLog.indexer.error("Agent History rebuild skipped: another instance owns the index")
                return
            }
        }
        pendingCarryOver = collectCarryOver()
        AgentHistoryLog.indexer.info(
            "Agent History rebuilding the index tombstones=\(self.pendingCarryOver?.tombstones.count ?? 0, privacy: .public) usage=\(self.pendingCarryOver?.usage.count ?? 0, privacy: .public)"
        )
        systemConditions.stopObserving()
        stopFreshness()
        writer?.close()
        writer = nil
        store = nil
        storage.readers.closeAll()
        do {
            try storage.removeIndexFiles()
        } catch {
            AgentHistoryLog.indexer.error("Agent History could not remove the index files for a rebuild")
            fail(.openFailed(code: -1))
            return
        }
        resetForReopen()
        corruptionRecoveryPending = false
        corruptionRecoveries = 0
        lifecycle = .idle
        startOnQueue()
    }

    // MARK: - Collecting

    /// Everything known about removals and usage right now; call before the file goes.
    func collectCarryOver() -> AgentHistoryRebuildCarryOver {
        var carryOver = pendingCarryOver ?? AgentHistoryRebuildCarryOver()
        if let store {
            carryOver.merge(Self.readCarryOver(from: store.database))
        } else {
            carryOver.merge(readCarryOverFromIndexFile())
        }
        var remembered = AgentHistoryRebuildCarryOver()
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        remembered.tombstones = admission.tombstones.map { .init(key: $0, removedAtMs: nowMs) }
        remembered.usage = snapshotBuilder.allSessions.filter { $0.opens > 0 }.map {
            .init(key: $0.key, opens: Int64($0.opens), lastOpenedAtMs: $0.lastOpenedAtMs)
        }
        carryOver.merge(remembered)
        return carryOver
    }

    /// The carry-over of an index this indexer cannot use (failed, newer schema), read through
    /// a short-lived read-only connection. Empty when there is no readable file.
    func readCarryOverFromIndexFile() -> AgentHistoryRebuildCarryOver {
        guard FileManager.default.fileExists(atPath: storage.paths.databaseURL.path) else {
            return AgentHistoryRebuildCarryOver()
        }
        do {
            let database = try AgentHistoryDatabase(
                url: storage.paths.databaseURL,
                mode: .readOnly,
                busyTimeoutMilliseconds: storage.options.busyTimeoutMilliseconds
            )
            defer { database.close() }
            return Self.readCarryOver(from: database)
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not open the old index for its removals \(error.description, privacy: .public)")
        } catch {}
        return AgentHistoryRebuildCarryOver()
    }

    /// Tombstones and usage of an index, best effort: each part that can't be read is empty.
    static func readCarryOver(from database: AgentHistoryDatabase) -> AgentHistoryRebuildCarryOver {
        var carryOver = AgentHistoryRebuildCarryOver()
        do {
            carryOver.tombstones = try database.query(
                "SELECT agent, native_id, removed_at FROM tombstones"
            ) { row -> AgentHistoryRebuildCarryOver.Tombstone? in
                guard let agent = AgentHistoryAgent(rawValue: row.string(0)) else { return nil }
                return .init(key: AgentHistorySessionKey(agent: agent, nativeID: row.string(1)), removedAtMs: row.int64(2))
            }.compactMap { $0 }
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not read removals before a rebuild \(error.description, privacy: .public)")
        } catch {}
        do {
            var usage = AgentHistoryRebuildCarryOver()
            usage.usage = try database.query(
                """
                SELECT src.agent, s.native_id, s.opens, s.last_opened_at
                FROM sessions s JOIN sources src ON src.id = s.source_id WHERE s.opens > 0
                UNION ALL
                SELECT agent, native_id, opens, last_opened_at FROM usage_carryover
                """
            ) { row -> AgentHistoryRebuildCarryOver.Usage? in
                guard let agent = AgentHistoryAgent(rawValue: row.string(0)) else { return nil }
                return .init(key: AgentHistorySessionKey(agent: agent, nativeID: row.string(1)),
                             opens: row.int64(2), lastOpenedAtMs: row.optionalInt64(3))
            }.compactMap { $0 }
            carryOver.merge(usage)
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not read usage before a rebuild \(error.description, privacy: .public)")
        } catch {}
        return carryOver
    }

    // MARK: - Restoring

    /// Writes a pending carry-over into the open index (called by `startOnQueue`, and again
    /// when the indexer goes idle after a failed write). Usage also lands on sessions that are
    /// already stored; removed sessions that are stored leave the snapshot. True once written.
    @discardableResult
    func restorePendingCarryOver(into store: AgentHistoryStore) -> Bool {
        guard let carryOver = pendingCarryOver else {
            return true
        }
        do {
            let removed = try store.database.transaction { () -> [Int64] in
                try beforeCarryOverRestoreForTesting?()
                var removed: [Int64] = []
                for tombstone in carryOver.tombstones {
                    removed += try store.addTombstone(tombstone.key, removedAtMs: tombstone.removedAtMs)
                }
                for usage in carryOver.usage {
                    try store.database.run(
                        """
                        INSERT INTO usage_carryover (agent, native_id, opens, last_opened_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(agent, native_id) DO UPDATE SET
                          opens = max(opens, excluded.opens),
                          last_opened_at = CASE WHEN last_opened_at IS NULL THEN excluded.last_opened_at
                                                WHEN excluded.last_opened_at IS NULL THEN last_opened_at
                                                ELSE max(last_opened_at, excluded.last_opened_at) END
                        """,
                        [.text(usage.key.agent.rawValue), .text(usage.key.nativeID), .integer(usage.opens),
                         .of(usage.lastOpenedAtMs)]
                    )
                }
                try Self.applyStoredUsageCarryOver(store.database)
                return removed
            }
            pendingCarryOver = nil
            if snapshotBuilder.count > 0, !removed.isEmpty || !carryOver.usage.isEmpty {
                // A late restore: rows were ingested before it landed.
                snapshotBuilder.replaceAll(try store.allVisibleSessionSummaries())
                snapshotDirty = true
                lastUpdatedAt = now()
            }
            return true
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not restore removals and usage after a rebuild \(error.description, privacy: .public)")
            if error.kind == .full {
                enterDiskFull()
            }
        } catch {
            AgentHistoryLog.indexer.error("Agent History could not restore removals and usage after a rebuild outside SQLite")
        }
        return false
    }

    /// Moves `usage_carryover` rows onto sessions that already exist (new sessions take theirs
    /// on insert).
    static func applyStoredUsageCarryOver(_ database: AgentHistoryDatabase) throws {
        try database.run(
            """
            UPDATE sessions SET
              opens = max(sessions.opens, u.opens),
              last_opened_at = CASE WHEN sessions.last_opened_at IS NULL THEN u.last_opened_at
                                    WHEN u.last_opened_at IS NULL THEN sessions.last_opened_at
                                    ELSE max(sessions.last_opened_at, u.last_opened_at) END
            FROM usage_carryover u JOIN sources src ON src.agent = u.agent
            WHERE sessions.source_id = src.id AND sessions.native_id = u.native_id
            """
        )
        try database.run(
            """
            DELETE FROM usage_carryover WHERE EXISTS (
              SELECT 1 FROM sessions s JOIN sources src ON src.id = s.source_id
              WHERE src.agent = usage_carryover.agent AND s.native_id = usage_carryover.native_id
            )
            """
        )
    }

    /// The tombstones in force for a freshly opened index: the stored ones plus a carry-over
    /// that could not be written yet.
    func tombstonesInForce(store: AgentHistoryStore) throws -> Set<AgentHistorySessionKey> {
        var tombstones = try store.tombstones()
        if let pending = pendingCarryOver {
            tombstones.formUnion(pending.tombstones.map(\.key))
        }
        return tombstones
    }
}
