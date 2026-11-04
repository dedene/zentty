import Foundation

/// Sources, cursors, tombstones, `meta` and maintenance.
extension AgentHistoryStore {
    // MARK: - Sources

    /// Inserts the `(agent, root)` source with `currentAdapterVersion`, or returns the stored row
    /// unchanged. The stored `adapter_version` is never overwritten here, so the indexer can
    /// compare it with the adapter's and re-ingest before calling `setAdapterVersion`.
    func upsertSource(agent: AgentHistoryAgent, root: String, currentAdapterVersion: Int) throws -> AgentHistorySourceRow {
        try database.transaction {
            try database.run(
                """
                INSERT INTO sources (agent, root, adapter_version) VALUES (?, ?, ?)
                ON CONFLICT(agent, root) DO NOTHING
                """,
                [.text(agent.rawValue), .text(root), .of(currentAdapterVersion)]
            )
            guard let row = try database.queryOne(
                Self.sourceSelectSQL + " WHERE agent = ? AND root = ?",
                [.text(agent.rawValue), .text(root)],
                map: Self.sourceRow
            ), let row else {
                throw AgentHistoryDatabaseError(kind: .other, code: 1, extendedCode: 1,
                                                message: "source row missing after upsert")
            }
            return row
        }
    }

    func setAdapterVersion(sourceID: Int64, _ version: Int) throws {
        try database.run("UPDATE sources SET adapter_version = ? WHERE id = ?", [.of(version), .integer(sourceID)])
    }

    /// Every source row this build understands (unknown agents are skipped), by id.
    func sources() throws -> [AgentHistorySourceRow] {
        try database.query(Self.sourceSelectSQL + " ORDER BY id", map: Self.sourceRow).compactMap { $0 }
    }

    func updateSourceHealth(
        id: Int64, discovered: Int, indexed: Int, skipped: Int, lastScanAt: Int64, lastError: String?
    ) throws {
        try database.run(
            """
            UPDATE sources SET discovered = ?, indexed = ?, skipped = ?, last_scan_at = ?, last_error = ?
            WHERE id = ?
            """,
            [.of(discovered), .of(indexed), .of(skipped), .integer(lastScanAt), .of(lastError), .integer(id)]
        )
    }

    func setSourceEnabled(id: Int64, _ enabled: Bool) throws {
        try database.run("UPDATE sources SET enabled = ? WHERE id = ?", [.of(enabled), .integer(id)])
    }

    // MARK: - Cursors

    /// Cursors of a source keyed by unit key.
    func cursors(sourceID: Int64) throws -> [String: AgentHistoryCursor] {
        let rows = try database.query(
            """
            SELECT unit_key, dev, ino, size, mtime_ns, byte_offset, next_seq, watermark, fingerprint,
                   rejected, adapter_state
            FROM cursors WHERE source_id = ?
            """,
            [.integer(sourceID)]
        ) { row -> AgentHistoryCursor in
            var identity: AgentHistoryFileIdentity?
            if let dev = row.optionalInt64(1), let ino = row.optionalInt64(2),
               let size = row.optionalInt64(3), let mtime = row.optionalInt64(4) {
                identity = AgentHistoryFileIdentity(dev: dev, ino: ino, size: size, mtimeNs: mtime)
            }
            return AgentHistoryCursor(
                sourceID: sourceID,
                unitKey: row.string(0),
                identity: identity,
                byteOffset: row.optionalInt64(5) ?? 0,
                nextSeq: Int(row.optionalInt64(6) ?? 0),
                watermark: row.optionalInt64(7),
                fingerprint: row.optionalInt64(8),
                isRejected: row.bool(9),
                adapterState: row.optionalData(10)
            )
        }
        return Dictionary(rows.map { ($0.unitKey, $0) }, uniquingKeysWith: { _, last in last })
    }

    func saveCursor(_ cursor: AgentHistoryCursor) throws {
        try database.run(
            """
            INSERT INTO cursors (source_id, unit_key, dev, ino, size, mtime_ns, byte_offset, next_seq,
                                 watermark, fingerprint, rejected, adapter_state)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(source_id, unit_key) DO UPDATE SET
              dev = ?3, ino = ?4, size = ?5, mtime_ns = ?6, byte_offset = ?7, next_seq = ?8,
              watermark = ?9, fingerprint = ?10, rejected = ?11, adapter_state = ?12
            """,
            [
                .integer(cursor.sourceID), .text(cursor.unitKey),
                .of(cursor.identity?.dev), .of(cursor.identity?.ino),
                .of(cursor.identity?.size), .of(cursor.identity?.mtimeNs),
                .integer(cursor.byteOffset), .of(cursor.nextSeq),
                .of(cursor.watermark), .of(cursor.fingerprint),
                .of(cursor.isRejected), .of(cursor.adapterState),
            ]
        )
    }

    func deleteCursor(sourceID: Int64, unitKey: String) throws {
        try database.run("DELETE FROM cursors WHERE source_id = ? AND unit_key = ?",
                         [.integer(sourceID), .text(unitKey)])
    }

    func deleteCursors(sourceID: Int64) throws {
        try database.run("DELETE FROM cursors WHERE source_id = ?", [.integer(sourceID)])
    }

    /// Flags units as rejected (excluded or tombstoned). A unit without a cursor gets a bare
    /// rejected one; the indexer normally saves the full cursor with `isRejected` itself.
    func markCursorsRejected(sourceID: Int64, unitKeys: [String]) throws {
        guard !unitKeys.isEmpty else { return }
        try database.transaction {
            for unitKey in unitKeys {
                try database.run(
                    """
                    INSERT INTO cursors (source_id, unit_key, rejected) VALUES (?, ?, 1)
                    ON CONFLICT(source_id, unit_key) DO UPDATE SET rejected = 1
                    """,
                    [.integer(sourceID), .text(unitKey)]
                )
            }
        }
    }

    /// Forgets every rejected cursor so those units classify as `.new` and are read again
    /// (after an exclusion is lifted or tombstones are restored). Clearing only the flag would
    /// leave a matching identity behind and the unit would stay `.unchanged`.
    func clearRejectedCursors() throws {
        try database.run("DELETE FROM cursors WHERE rejected = 1")
    }

    // MARK: - Tombstones

    /// Records a removal and deletes the session from every source of that agent. Returns the
    /// deleted row ids.
    @discardableResult
    func addTombstone(_ key: AgentHistorySessionKey, removedAtMs: Int64) throws -> [Int64] {
        try database.transaction {
            try database.run(
                """
                INSERT INTO tombstones (agent, native_id, removed_at) VALUES (?, ?, ?)
                ON CONFLICT(agent, native_id) DO UPDATE SET removed_at = excluded.removed_at
                """,
                [.text(key.agent.rawValue), .text(key.nativeID), .integer(removedAtMs)]
            )
            let ids = try database.query(
                """
                SELECT s.id FROM sessions s JOIN sources src ON src.id = s.source_id
                WHERE src.agent = ? AND s.native_id = ?
                """,
                [.text(key.agent.rawValue), .text(key.nativeID)]
            ) { $0.int64(0) }
            for id in ids {
                try deleteSession(id: id)
            }
            return ids
        }
    }

    func tombstones() throws -> Set<AgentHistorySessionKey> {
        Set(try database.query("SELECT agent, native_id FROM tombstones") { row -> AgentHistorySessionKey? in
            guard let agent = AgentHistoryAgent(rawValue: row.string(0)) else { return nil }
            return AgentHistorySessionKey(agent: agent, nativeID: row.string(1))
        }.compactMap { $0 })
    }

    /// The stored removals with their removal times (agents this build doesn't know are left out).
    func tombstoneEntries() throws -> [AgentHistoryRebuildCarryOver.Tombstone] {
        try database.query("SELECT agent, native_id, removed_at FROM tombstones") { row -> AgentHistoryRebuildCarryOver.Tombstone? in
            guard let agent = AgentHistoryAgent(rawValue: row.string(0)) else { return nil }
            return .init(key: AgentHistorySessionKey(agent: agent, nativeID: row.string(1)), removedAtMs: row.int64(2))
        }.compactMap { $0 }
    }

    func tombstoneCount() throws -> Int {
        Int(try database.scalarInt64("SELECT count(*) FROM tombstones") ?? 0)
    }

    /// Deletes every tombstone; returns how many there were.
    @discardableResult
    func removeAllTombstones() throws -> Int {
        try database.run("DELETE FROM tombstones")
        return database.changes
    }

    // MARK: - Meta

    func meta(_ key: String) throws -> String? {
        try database.queryOne("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.string(0) }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try database.run(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    // MARK: - Maintenance

    /// `PRAGMA optimize`, FTS5 segment merge for each full-text table, then a passive WAL
    /// checkpoint. Call outside a transaction (after a backfill).
    func optimize() throws {
        try database.execute("PRAGMA optimize")
        for (_, fts) in AgentHistorySchema.fullTextTables {
            let exists = try database.scalarInt64(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(fts)]
            ) != nil
            guard exists else { continue }
            try database.run("INSERT INTO \(fts)(\(fts)) VALUES('optimize')")
        }
        if !database.isInTransaction {
            _ = try database.query("PRAGMA wal_checkpoint(PASSIVE)") { $0.int64(0) }
        }
    }

    // MARK: - Internals

    private static let sourceSelectSQL = """
        SELECT id, agent, root, adapter_version, enabled, discovered, indexed, skipped, last_scan_at, last_error
        FROM sources
        """

    private static func sourceRow(_ row: AgentHistoryRow) -> AgentHistorySourceRow? {
        guard let agent = AgentHistoryAgent(rawValue: row.string(1)) else { return nil }
        return AgentHistorySourceRow(
            id: row.int64(0),
            agent: agent,
            root: row.string(2),
            adapterVersion: Int(row.int64(3)),
            enabled: row.bool(4),
            discovered: Int(row.int64(5)),
            indexed: Int(row.int64(6)),
            skipped: Int(row.int64(7)),
            lastScanAt: row.optionalInt64(8),
            lastError: row.optionalString(9)
        )
    }
}
