import Foundation

/// SQL fragments shared by every query over `sessions s`.
enum AgentHistorySQL {
    /// The sessions the palette, the snapshot and the CLI may show: not a child thread, and at
    /// least one user turn.
    static let visibleSessionPredicate = "s.parent_native_id IS NULL AND s.turn_count > 0"
}

/// The rows an `apply` touched (upserted or given content) and the rows it deleted.
struct AgentHistoryApplyResult: Equatable, Sendable {
    var touchedSessionIDs: Set<Int64> = []
    var removedSessionIDs: Set<Int64> = []
}

/// One `sources` row.
struct AgentHistorySourceRow: Equatable, Sendable {
    var id: Int64
    var agent: AgentHistoryAgent
    var root: String
    var adapterVersion: Int
    var enabled: Bool
    var discovered: Int
    var indexed: Int
    var skipped: Int
    var lastScanAt: Int64?
    var lastError: String?
}

/// Typed access to the Agent History index.
///
/// Confinement: the store borrows `database` and inherits its owner (the indexer queue for the
/// writer). Mutating calls are meant to run inside the caller's `database.transaction`; the
/// multi-statement ones open their own (nested → savepoint) so they stay atomic either way.
///
/// `messages` and `artifacts` get explicit, chronological row ids: `rowIDBase(at) + n` with
/// `n` in `0..<1000`. FTS5 rowid order is therefore time order, which lets content search walk
/// newest-first and stop at its limit even though backfill inserts newer sessions first.
///
/// Never use `INSERT OR REPLACE` / `REPLACE INTO` here: a replace removes the old row without
/// firing the delete triggers, and the external-content FTS index desyncs.
struct AgentHistoryStore {
    let database: AgentHistoryDatabase
    /// Clock for the insert-time `created_at` fallback when a session has no timestamps at all.
    var now: @Sendable () -> Date = { Date() }

    static let maxMessageRowsPerMillisecond: Int64 = 1000
    static let maxRowIDMilliseconds: Int64 = 9_000_000_000_000

    /// The first row id for a row at `ms` (Unix milliseconds).
    static func rowIDBase(at ms: Int64) -> Int64 {
        min(max(ms, 0), maxRowIDMilliseconds) * maxMessageRowsPerMillisecond
    }

    // MARK: - Sessions

    /// Inserts or merges one session (merge rules: `AgentHistorySessionDraft.merged`) and
    /// returns its stable row id. `unitKey` re-points the row when non-nil (rename).
    /// `firstMessageAtMs`/`lastMessageAtMs` are insert-time fallbacks for `created_at`/`updated_at`.
    @discardableResult
    func upsertSession(
        sourceID: Int64,
        unitKey: String?,
        _ draft: AgentHistorySessionDraft,
        firstMessageAtMs: Int64? = nil,
        lastMessageAtMs: Int64? = nil
    ) throws -> Int64 {
        try database.transaction {
            let existingID = try sessionID(sourceID: sourceID, nativeID: draft.nativeID)
            let createdOnInsert = draft.createdAtMs ?? draft.updatedAtMs ?? firstMessageAtMs
                ?? AgentHistorySchema.milliseconds(since1970: now())
            let updatedOnInsert = draft.updatedAtMs ?? lastMessageAtMs.map { max($0, createdOnInsert) }
                ?? createdOnInsert
            let bindings: [AgentHistoryValue] = [
                .integer(sourceID),                     // ?1
                .text(draft.nativeID),                  // ?2
                .of(unitKey),                           // ?3
                .of(draft.title),                       // ?4
                .of(draft.titleKind?.rawValue),         // ?5
                .of(draft.cwd),                         // ?6
                .of(draft.repoRoot),                    // ?7
                .of(draft.mainRepoRoot),                // ?8
                .of(draft.branch),                      // ?9
                .of(draft.model),                       // ?10
                .of(draft.effort),                      // ?11
                .of(draft.generation),                  // ?12
                .of(draft.transcriptPath),              // ?13
                .integer(createdOnInsert),              // ?14
                .integer(updatedOnInsert),              // ?15
                .of(draft.lastUserAtMs),                // ?16
                .of(draft.archived),                    // ?17
                .of(draft.parentNativeID),              // ?18
                .of(draft.createdAtMs),                 // ?19
                .of(draft.updatedAtMs),                 // ?20
            ]
            guard let id = try database.queryOne(Self.upsertSessionSQL, bindings, map: { $0.int64(0) }) else {
                throw AgentHistoryDatabaseError(kind: .other, code: 1, extendedCode: 1,
                                                message: "session upsert returned no row")
            }
            if existingID == nil {
                try applyUsageCarryover(sessionID: id, sourceID: sourceID, nativeID: draft.nativeID)
            }
            return id
        }
    }

    func sessionID(sourceID: Int64, nativeID: String) throws -> Int64? {
        try database.scalarInt64(
            "SELECT id FROM sessions WHERE source_id = ? AND native_id = ?",
            [.integer(sourceID), .text(nativeID)]
        )
    }

    /// Recounts `turn_count` (the number of user messages).
    func refreshTurnCount(sessionID: Int64) throws {
        try database.run(
            """
            UPDATE sessions
            SET turn_count = (SELECT count(*) FROM messages WHERE session_id = ?1 AND role = 'user')
            WHERE id = ?1
            """,
            [.integer(sessionID)]
        )
    }

    /// Deletes a session's messages and artifacts (FTS follows through the triggers) and
    /// zeroes its turn count. The session row stays.
    func deleteSessionContent(sessionID: Int64) throws {
        try database.transaction {
            try database.run("DELETE FROM messages WHERE session_id = ?", [.integer(sessionID)])
            try database.run("DELETE FROM artifacts WHERE session_id = ?", [.integer(sessionID)])
            try database.run("UPDATE sessions SET turn_count = 0 WHERE id = ?", [.integer(sessionID)])
        }
    }

    /// Deletes a session; messages, artifacts and their FTS rows cascade.
    func deleteSession(id: Int64) throws {
        try database.run("DELETE FROM sessions WHERE id = ?", [.integer(id)])
    }

    // MARK: - Messages and artifacts

    /// Upserts messages by `(session_id, seq)`:
    /// - new → a fresh chronological id from `rowIDBase(at)`;
    /// - same `at`, changed role or text → updated in place, id kept;
    /// - changed `at` → deleted and re-inserted under a new chronological id (A-4).
    func upsertMessages(sessionID: Int64, _ messages: [AgentHistoryMessageDraft]) throws {
        guard !messages.isEmpty else { return }
        try database.transaction {
            for message in messages {
                let existing = try database.queryOne(
                    "SELECT id, at, role, search_text, text FROM messages WHERE session_id = ? AND seq = ?",
                    [.integer(sessionID), .of(message.seq)]
                ) { row in
                    StoredMessage(id: row.int64(0), atMs: row.int64(1), role: row.string(2),
                                  searchText: row.string(3), text: row.string(4))
                }
                if let existing {
                    if existing.atMs == message.atMs {
                        guard existing.role != message.role.rawValue
                            || existing.searchText != message.searchText
                            || existing.text != message.text
                        else { continue }
                        try database.run(
                            "UPDATE messages SET role = ?, search_text = ?, text = ? WHERE id = ?",
                            [.text(message.role.rawValue), .text(message.searchText), .text(message.text),
                             .integer(existing.id)]
                        )
                        continue
                    }
                    try database.run("DELETE FROM messages WHERE id = ?", [.integer(existing.id)])
                }
                let id = try nextRowID(in: "messages", atMs: message.atMs)
                try database.run(
                    """
                    INSERT INTO messages (id, session_id, seq, role, at, search_text, text)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(id), .integer(sessionID), .of(message.seq), .text(message.role.rawValue),
                     .integer(message.atMs), .text(message.searchText), .text(message.text)]
                )
            }
        }
    }

    /// Inserts artifacts not yet stored for `(session_id, kind, value)`; the first sighting wins.
    func upsertArtifacts(sessionID: Int64, _ artifacts: [AgentHistoryArtifactDraft]) throws {
        guard !artifacts.isEmpty else { return }
        try database.transaction {
            for artifact in artifacts {
                let bindings: [AgentHistoryValue] = [
                    .integer(sessionID), .text(artifact.kind.rawValue), .text(artifact.value),
                ]
                let exists = try database.scalarInt64(
                    "SELECT 1 FROM artifacts WHERE session_id = ? AND kind = ? AND value = ?", bindings
                ) != nil
                if exists { continue }
                let id = try nextRowID(in: "artifacts", atMs: artifact.atMs)
                try database.run(
                    """
                    INSERT INTO artifacts (id, session_id, seq, kind, value, search_text, at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, kind, value) DO NOTHING
                    """,
                    [.integer(id), .integer(sessionID), .of(artifact.seq), .text(artifact.kind.rawValue),
                     .text(artifact.value), .text(artifact.searchText), .integer(artifact.atMs)]
                )
            }
        }
    }

    // MARK: - Internals

    private struct StoredMessage {
        let id: Int64
        let atMs: Int64
        let role: String
        let searchText: String
        let text: String
    }

    /// The next free id in `[base, base + 999]` for `atMs`; a full millisecond spills into the
    /// next one, so ids stay monotonic with time.
    private func nextRowID(in table: String, atMs: Int64) throws -> Int64 {
        var base = Self.rowIDBase(at: atMs)
        let sql = "SELECT COALESCE(MAX(id), ?1 - 1) + 1 FROM \(table) WHERE id BETWEEN ?1 AND ?1 + ?2"
        while true {
            let candidate = try database.scalarInt64(
                sql, [.integer(base), .integer(Self.maxMessageRowsPerMillisecond - 1)]
            ) ?? base
            if candidate < base + Self.maxMessageRowsPerMillisecond {
                return candidate
            }
            base += Self.maxMessageRowsPerMillisecond
        }
    }

    /// On first insert, moves a matching `usage_carryover` row (kept across a rebuild) onto
    /// the new session and deletes it.
    private func applyUsageCarryover(sessionID: Int64, sourceID: Int64, nativeID: String) throws {
        struct Usage { let agent: String; let opens: Int64; let lastOpenedAt: Int64? }
        let usage = try database.queryOne(
            """
            SELECT u.agent, u.opens, u.last_opened_at
            FROM usage_carryover u JOIN sources src ON src.agent = u.agent
            WHERE src.id = ? AND u.native_id = ?
            """,
            [.integer(sourceID), .text(nativeID)]
        ) { Usage(agent: $0.string(0), opens: $0.int64(1), lastOpenedAt: $0.optionalInt64(2)) }
        guard let usage else { return }
        try database.run(
            "UPDATE sessions SET opens = ?, last_opened_at = ? WHERE id = ?",
            [.integer(usage.opens), .of(usage.lastOpenedAt), .integer(sessionID)]
        )
        try database.run(
            "DELETE FROM usage_carryover WHERE agent = ? AND native_id = ?",
            [.text(usage.agent), .text(nativeID)]
        )
    }

    /// Insert defaults: `title ?? ''`, `title_kind ?? 'first_prompt'`, archived 0. On conflict the
    /// numbered parameters carry the raw (nullable) update so nil never clears or moves a value.
    /// Title: an empty incoming title never wins; a stored empty title always loses; otherwise a
    /// higher rank wins and equal-rank `custom`/`generated` take the update. `opens` and
    /// `last_opened_at` are never touched here.
    static let upsertSessionSQL = """
        INSERT INTO sessions (
          source_id, native_id, unit_key, title, title_kind, cwd, repo_root, main_repo_root, branch,
          model, effort, generation, transcript_path, created_at, updated_at, last_user_at, archived,
          parent_native_id
        ) VALUES (
          ?1, ?2, ?3, COALESCE(?4, ''), COALESCE(?5, 'first_prompt'), ?6, ?7, ?8, ?9,
          ?10, ?11, ?12, ?13, ?14, ?15, ?16, COALESCE(?17, 0), ?18
        )
        ON CONFLICT(source_id, native_id) DO UPDATE SET
          title = CASE WHEN \(takesTitleSQL) THEN excluded.title ELSE sessions.title END,
          title_kind = CASE WHEN \(takesTitleSQL) THEN excluded.title_kind ELSE sessions.title_kind END,
          cwd = COALESCE(?6, sessions.cwd),
          repo_root = COALESCE(?7, sessions.repo_root),
          main_repo_root = COALESCE(?8, sessions.main_repo_root),
          branch = COALESCE(?9, sessions.branch),
          model = COALESCE(?10, sessions.model),
          effort = COALESCE(?11, sessions.effort),
          generation = COALESCE(?12, sessions.generation),
          transcript_path = COALESCE(?13, sessions.transcript_path),
          created_at = CASE WHEN ?19 IS NULL THEN sessions.created_at ELSE MIN(sessions.created_at, ?19) END,
          updated_at = CASE WHEN ?20 IS NULL THEN sessions.updated_at ELSE MAX(sessions.updated_at, ?20) END,
          last_user_at = CASE WHEN ?16 IS NULL THEN sessions.last_user_at
                              WHEN sessions.last_user_at IS NULL THEN ?16
                              ELSE MAX(sessions.last_user_at, ?16) END,
          archived = COALESCE(?17, sessions.archived),
          parent_native_id = COALESCE(?18, sessions.parent_native_id),
          unit_key = COALESCE(?3, sessions.unit_key)
        RETURNING id
        """

    private static func rankSQL(_ kind: String) -> String {
        "(CASE \(kind) WHEN 'custom' THEN 3 WHEN 'generated' THEN 2 ELSE 1 END)"
    }

    private static let takesTitleSQL = """
        (?4 IS NOT NULL AND ?4 <> '' AND (
          sessions.title = ''
          OR \(rankSQL("excluded.title_kind")) > \(rankSQL("sessions.title_kind"))
          OR (\(rankSQL("excluded.title_kind")) = \(rankSQL("sessions.title_kind"))
              AND excluded.title_kind <> 'first_prompt')
        ))
        """
}
