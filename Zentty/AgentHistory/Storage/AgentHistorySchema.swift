import Foundation

/// The FTS5 tokenizer the index was built with. Stored in `meta.tokenizer`.
enum AgentHistoryTokenizer: String, Sendable, Equatable {
    /// Substring matching for any script; needs terms of three or more characters.
    case trigram
    /// Fallback for SQLite builds without trigram: word tokens with prefix indexes.
    case unicode61
    /// No usable FTS5: the index stores rows but has no full-text tables.
    case none
}

/// Schema v1 of the Agent History index (`index.sqlite`).
///
/// Every `*_at` column holds Unix milliseconds. `messages` and `artifacts` use explicit,
/// chronological row ids (`at_ms * 1000 + n`), so FTS rowid order is time order.
///
/// Never write `INSERT OR REPLACE` / `REPLACE INTO` against these tables: a replace deletes the
/// old row without firing the delete triggers, and the external-content FTS index desyncs.
enum AgentHistorySchema {
    static let currentVersion: Int32 = 1
    static let applicationID: Int32 = 0x5A_48_53_54          // "ZHST"

    /// The tables that carry an external-content FTS index, paired with that index.
    static let fullTextTables: [(content: String, fts: String)] = [
        ("messages", "messages_fts"),
        ("artifacts", "artifacts_fts"),
    ]

    enum MetaKey {
        static let tokenizer = "tokenizer"
        static let createdAt = "created_at"
        static let appVersion = "app_version"
    }

    // MARK: - Tokenizer probe

    /// Picks the best tokenizer this SQLite build supports by creating (and dropping) a throwaway
    /// table in the `temp` schema. Never throws: a connection without FTS5 gets `.none`.
    static func probeTokenizer(_ db: AgentHistoryDatabase) -> AgentHistoryTokenizer {
        for tokenizer in [AgentHistoryTokenizer.trigram, .unicode61] {
            guard let clause = tokenizeClause(tokenizer) else { continue }
            do {
                try db.execute("DROP TABLE IF EXISTS temp.zh_probe")
                try db.execute("CREATE VIRTUAL TABLE temp.zh_probe USING fts5(x, \(clause))")
                try db.execute("DROP TABLE temp.zh_probe")
                return tokenizer
            } catch let error as AgentHistoryDatabaseError {
                AgentHistoryLog.indexer.info(
                    "FTS5 tokenizer \(tokenizer.rawValue, privacy: .public) unavailable: \(error.description, privacy: .public)"
                )
            } catch {}
        }
        return .none
    }

    // MARK: - Create / migrate

    /// Creates every v1 table, index, FTS table and trigger, and writes the `meta` rows.
    /// Runs in the caller's transaction when there is one (as a savepoint), else in its own.
    /// The caller stamps `user_version` and `application_id`.
    static func createVersion1(
        _ db: AgentHistoryDatabase,
        tokenizer: AgentHistoryTokenizer,
        now: Date,
        appVersion: String
    ) throws {
        try db.transaction {
            try db.execute(version1TablesSQL)
            try createFullText(db, tokenizer: tokenizer)
            try setMeta(db, MetaKey.tokenizer, tokenizer.rawValue)
            try setMeta(db, MetaKey.createdAt, String(milliseconds(since1970: now)))
            try setMeta(db, MetaKey.appVersion, appVersion)
        }
    }

    /// Brings a database at `from` up to `currentVersion`. Version 0 means "empty": it gets the
    /// full v1 schema. There are no later steps yet; a version above current throws `.schemaTooNew`.
    static func migrate(
        _ db: AgentHistoryDatabase,
        from version: Int32,
        tokenizer: AgentHistoryTokenizer,
        now: Date,
        appVersion: String
    ) throws {
        guard version <= currentVersion else {
            throw AgentHistoryDatabaseError(kind: .schemaTooNew(found: version), code: 0, extendedCode: 0,
                                            message: "schema version \(version) is newer than \(currentVersion)")
        }
        if version == 0 {
            try createVersion1(db, tokenizer: tokenizer, now: now, appVersion: appVersion)
        }
        // v1 is the first shipped schema: add `if version < 2 { … }` steps here.
    }

    /// The tokenizer recorded in `meta`, or nil when it is missing or not one this build knows.
    static func storedTokenizer(_ db: AgentHistoryDatabase) throws -> AgentHistoryTokenizer? {
        let raw = try db.queryOne("SELECT value FROM meta WHERE key = ?", [.text(MetaKey.tokenizer)]) {
            $0.string(0)
        }
        return raw.flatMap(AgentHistoryTokenizer.init(rawValue:))
    }

    /// Replaces both FTS tables and their triggers with ones for `tokenizer`, re-indexes the
    /// content tables and records the new tokenizer, all in one transaction. A failing DROP (for
    /// example an FTS table built with a tokenizer this SQLite lacks) throws; the caller then
    /// quarantines the database and rebuilds it.
    static func rebuildFullText(_ db: AgentHistoryDatabase, to tokenizer: AgentHistoryTokenizer) throws {
        try db.transaction {
            for (_, fts) in fullTextTables {
                for suffix in triggerSuffixes {
                    try db.execute("DROP TRIGGER IF EXISTS \(fts)_\(suffix)")
                }
                try db.execute("DROP TABLE IF EXISTS \(fts)")
            }
            try createFullText(db, tokenizer: tokenizer)
            if tokenizer != .none {
                for (_, fts) in fullTextTables {
                    try db.execute("INSERT INTO \(fts)(\(fts)) VALUES('rebuild')")
                }
            }
            try setMeta(db, MetaKey.tokenizer, tokenizer.rawValue)
        }
    }

    // MARK: - FTS SQL

    /// `CREATE VIRTUAL TABLE` for an external-content FTS5 index over `content.search_text`,
    /// or nil for `.none`.
    static func ftsTableSQL(_ table: String, content: String, tokenizer: AgentHistoryTokenizer) -> String? {
        guard let clause = tokenizeClause(tokenizer) else { return nil }
        return """
            CREATE VIRTUAL TABLE \(table) USING fts5(
              search_text, content='\(content)', content_rowid='id', \(clause)
            )
            """
    }

    /// Insert / delete / update triggers that keep `fts` in sync with `table`. FK cascades fire
    /// the delete trigger too, so deleting a session cleans its FTS rows. The update trigger also
    /// watches `id` so a row moved to a new chronological id cannot leave a stale FTS rowid.
    static func ftsTriggerSQL(table: String, fts: String) -> String {
        """
        CREATE TRIGGER \(fts)_ai AFTER INSERT ON \(table) BEGIN
          INSERT INTO \(fts)(rowid, search_text) VALUES (new.id, new.search_text);
        END;
        CREATE TRIGGER \(fts)_ad AFTER DELETE ON \(table) BEGIN
          INSERT INTO \(fts)(\(fts), rowid, search_text) VALUES ('delete', old.id, old.search_text);
        END;
        CREATE TRIGGER \(fts)_au AFTER UPDATE OF id, search_text ON \(table) BEGIN
          INSERT INTO \(fts)(\(fts), rowid, search_text) VALUES ('delete', old.id, old.search_text);
          INSERT INTO \(fts)(rowid, search_text) VALUES (new.id, new.search_text);
        END;
        """
    }

    static let triggerSuffixes = ["ai", "ad", "au"]

    // MARK: - Internals

    private static func tokenizeClause(_ tokenizer: AgentHistoryTokenizer) -> String? {
        switch tokenizer {
        case .trigram: return "tokenize='trigram'"
        case .unicode61: return "tokenize='unicode61 remove_diacritics 2', prefix='2 3'"
        case .none: return nil
        }
    }

    private static func createFullText(_ db: AgentHistoryDatabase, tokenizer: AgentHistoryTokenizer) throws {
        for (content, fts) in fullTextTables {
            guard let tableSQL = ftsTableSQL(fts, content: content, tokenizer: tokenizer) else { continue }
            try db.execute(tableSQL)
            try db.execute(ftsTriggerSQL(table: content, fts: fts))
        }
    }

    private static func setMeta(_ db: AgentHistoryDatabase, _ key: String, _ value: String) throws {
        try db.run(
            "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Spec §5.3 plus the plan's v1 deltas: `sessions.unit_key` (+ `sessions_unit`),
    /// `cursors.fingerprint/rejected/adapter_state`, `messages.search_text` before `text`,
    /// and `usage_carryover` (opens carried across a rebuild).
    static let version1TablesSQL = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

        CREATE TABLE sources (
          id INTEGER PRIMARY KEY,
          agent TEXT NOT NULL,
          root TEXT NOT NULL,
          adapter_version INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          discovered INTEGER NOT NULL DEFAULT 0,
          indexed INTEGER NOT NULL DEFAULT 0,
          skipped INTEGER NOT NULL DEFAULT 0,
          last_scan_at INTEGER,
          last_error TEXT,
          UNIQUE (agent, root)
        );

        CREATE TABLE sessions (
          id INTEGER PRIMARY KEY,
          source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          native_id TEXT NOT NULL,
          unit_key TEXT,
          title TEXT NOT NULL,
          title_kind TEXT NOT NULL,
          cwd TEXT,
          repo_root TEXT,
          main_repo_root TEXT,
          branch TEXT,
          model TEXT,
          effort TEXT,
          generation TEXT,
          transcript_path TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          last_user_at INTEGER,
          turn_count INTEGER NOT NULL DEFAULT 0,
          archived INTEGER NOT NULL DEFAULT 0,
          parent_native_id TEXT,
          opens INTEGER NOT NULL DEFAULT 0,
          last_opened_at INTEGER,
          UNIQUE (source_id, native_id)
        );
        CREATE INDEX sessions_updated ON sessions(updated_at DESC);
        CREATE INDEX sessions_repo ON sessions(main_repo_root, updated_at DESC);
        CREATE INDEX sessions_unit ON sessions(source_id, unit_key);

        CREATE TABLE messages (
          id INTEGER PRIMARY KEY,
          session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('user', 'agent')),
          at INTEGER NOT NULL,
          search_text TEXT NOT NULL,
          text TEXT NOT NULL,
          UNIQUE (session_id, seq)
        );

        CREATE TABLE artifacts (
          id INTEGER PRIMARY KEY,
          session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('path', 'command', 'commit', 'pr')),
          value TEXT NOT NULL,
          search_text TEXT NOT NULL,
          at INTEGER NOT NULL,
          UNIQUE (session_id, kind, value)
        );

        CREATE TABLE cursors (
          source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          unit_key TEXT NOT NULL,
          dev INTEGER,
          ino INTEGER,
          size INTEGER,
          mtime_ns INTEGER,
          byte_offset INTEGER,
          watermark INTEGER,
          next_seq INTEGER,
          fingerprint INTEGER,
          rejected INTEGER NOT NULL DEFAULT 0,
          adapter_state BLOB,
          PRIMARY KEY (source_id, unit_key)
        );

        CREATE TABLE tombstones (
          agent TEXT NOT NULL,
          native_id TEXT NOT NULL,
          removed_at INTEGER NOT NULL,
          PRIMARY KEY (agent, native_id)
        );

        CREATE TABLE usage_carryover (
          agent TEXT NOT NULL,
          native_id TEXT NOT NULL,
          opens INTEGER NOT NULL,
          last_opened_at INTEGER,
          PRIMARY KEY (agent, native_id)
        ) WITHOUT ROWID;
        """
}
