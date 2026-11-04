import Foundation
import XCTest
@testable import Zentty

final class AgentHistorySchemaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000.5)

    private func makeDatabase(tokenizer: AgentHistoryTokenizer = .trigram) throws -> AgentHistoryDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = try AgentHistoryDatabase(
            url: directory.appendingPathComponent("index.sqlite"),
            mode: .readWrite,
            busyTimeoutMilliseconds: 2_000
        )
        addTeardownBlock { database.close() }
        try AgentHistorySchema.createVersion1(database, tokenizer: tokenizer, now: now, appVersion: "1.2.3")
        return database
    }

    @discardableResult
    private func insertSession(_ db: AgentHistoryDatabase, nativeID: String = "s1") throws -> Int64 {
        try db.run(
            "INSERT INTO sources(agent, root, adapter_version) VALUES ('claude', '/r', 1) ON CONFLICT(agent, root) DO NOTHING"
        )
        let sourceID = try XCTUnwrap(try db.scalarInt64("SELECT id FROM sources WHERE agent = 'claude'"))
        try db.run(
            """
            INSERT INTO sessions(source_id, native_id, title, title_kind, created_at, updated_at)
            VALUES (?, ?, 't', 'first_prompt', 1, 1)
            """,
            [.integer(sourceID), .text(nativeID)]
        )
        return db.lastInsertRowID
    }

    private func insertMessage(_ db: AgentHistoryDatabase, id: Int64, session: Int64, seq: Int64, text: String) throws {
        try db.run(
            "INSERT INTO messages(id, session_id, seq, role, at, search_text, text) VALUES (?, ?, ?, 'user', 1, ?, ?)",
            [.integer(id), .integer(session), .integer(seq), .text(text), .text(text)]
        )
    }

    private func insertArtifact(_ db: AgentHistoryDatabase, id: Int64, session: Int64, value: String) throws {
        try db.run(
            "INSERT INTO artifacts(id, session_id, seq, kind, value, search_text, at) VALUES (?, ?, 0, 'path', ?, ?, 1)",
            [.integer(id), .integer(session), .text(value), .text(value)]
        )
    }

    private func matches(_ db: AgentHistoryDatabase, _ fts: String, _ expression: String) throws -> [Int64] {
        try db.query("SELECT rowid FROM \(fts) WHERE \(fts) MATCH ? ORDER BY rowid", [.text(expression)]) {
            $0.int64(0)
        }
    }

    private func names(_ db: AgentHistoryDatabase, type: String) throws -> Set<String> {
        Set(try db.query("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%'", [.text(type)]) {
            $0.string(0)
        })
    }

    private func columns(_ db: AgentHistoryDatabase, _ table: String) throws -> [String] {
        try db.query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.text(table)]) { $0.string(0) }
    }

    private func integrityCheck(_ db: AgentHistoryDatabase) throws {
        for (_, fts) in AgentHistorySchema.fullTextTables {
            try db.run("INSERT INTO \(fts)(\(fts), rank) VALUES ('integrity-check', 1)")
        }
    }

    // MARK: - Layout

    func test_version1_creates_all_tables_indexes_and_triggers() throws {
        let db = try makeDatabase()
        let tables = try names(db, type: "table")
        for table in ["meta", "sources", "sessions", "messages", "artifacts", "cursors", "tombstones",
                      "usage_carryover", "messages_fts", "artifacts_fts"] {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
        XCTAssertTrue(try names(db, type: "index").isSuperset(of: ["sessions_updated", "sessions_repo", "sessions_unit"]))
        XCTAssertEqual(try names(db, type: "trigger"), [
            "messages_fts_ai", "messages_fts_ad", "messages_fts_au",
            "artifacts_fts_ai", "artifacts_fts_ad", "artifacts_fts_au",
        ])

        XCTAssertTrue(try columns(db, "sessions").contains("unit_key"))
        let cursorColumns = try columns(db, "cursors")
        for column in ["fingerprint", "rejected", "adapter_state"] {
            XCTAssertTrue(cursorColumns.contains(column), "cursors is missing \(column)")
        }
        XCTAssertEqual(try columns(db, "usage_carryover"), ["agent", "native_id", "opens", "last_opened_at"])
        XCTAssertFalse(try columns(db, "sessions").contains("metadata_only"), "D1 was approved: no metadata_only column")

        let unitIndex = try db.query("SELECT name FROM pragma_index_info('sessions_unit') ORDER BY seqno") { $0.string(0) }
        XCTAssertEqual(unitIndex, ["source_id", "unit_key"])
        XCTAssertEqual(try db.scalarInt64("PRAGMA foreign_key_check"), nil)
    }

    func test_messages_search_text_precedes_text() throws {
        let db = try makeDatabase()
        XCTAssertEqual(try columns(db, "messages"), ["id", "session_id", "seq", "role", "at", "search_text", "text"])
    }

    func test_meta_records_tokenizer_created_at_and_app_version() throws {
        let db = try makeDatabase(tokenizer: .unicode61)
        let meta = Dictionary(uniqueKeysWithValues: try db.query("SELECT key, value FROM meta") { ($0.string(0), $0.string(1)) })
        XCTAssertEqual(meta, ["tokenizer": "unicode61", "created_at": "1793000000500", "app_version": "1.2.3"])
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(db), .unicode61)
    }

    func test_probe_detects_trigram_on_this_system() throws {
        let db = try makeDatabase()
        XCTAssertEqual(AgentHistorySchema.probeTokenizer(db), .trigram)
        // The probe leaves nothing behind.
        XCTAssertEqual(try db.scalarInt64("SELECT count(*) FROM temp.sqlite_master"), 0)
        // A second probe works (the throwaway table was dropped).
        XCTAssertEqual(AgentHistorySchema.probeTokenizer(db), .trigram)
    }

    // MARK: - Triggers

    func test_insert_message_is_findable_through_fts() throws {
        let db = try makeDatabase()
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "fix the flaky websocket test")
        try insertMessage(db, id: 2_000, session: session, seq: 1, text: "renamed the config loader")
        try insertArtifact(db, id: 1_000, session: session, value: "/src/websocket/client.swift")

        XCTAssertEqual(try matches(db, "messages_fts", "socket"), [1_000])
        XCTAssertEqual(try matches(db, "messages_fts", "loader"), [2_000])
        XCTAssertEqual(try matches(db, "artifacts_fts", "\"client.swift\""), [1_000])
    }

    func test_update_search_text_replaces_fts_terms() throws {
        let db = try makeDatabase()
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "original wording")
        try db.run("UPDATE messages SET search_text = 'replacement phrasing', text = 'Replacement phrasing' WHERE id = 1000")

        XCTAssertEqual(try matches(db, "messages_fts", "original"), [])
        XCTAssertEqual(try matches(db, "messages_fts", "phrasing"), [1_000])

        // Updating only the display text leaves the FTS row alone and consistent.
        try db.run("UPDATE messages SET text = 'other' WHERE id = 1000")
        XCTAssertEqual(try matches(db, "messages_fts", "phrasing"), [1_000])
        try integrityCheck(db)
    }

    func test_deleting_session_cascades_into_fts() throws {
        let db = try makeDatabase()
        let kept = try insertSession(db, nativeID: "kept")
        let doomed = try insertSession(db, nativeID: "doomed")
        try insertMessage(db, id: 1_000, session: kept, seq: 0, text: "shared needle kept")
        try insertMessage(db, id: 2_000, session: doomed, seq: 0, text: "shared needle doomed")
        try insertArtifact(db, id: 2_000, session: doomed, value: "needle.swift")

        try db.run("DELETE FROM sessions WHERE id = ?", [.integer(doomed)])

        XCTAssertEqual(try matches(db, "messages_fts", "needle"), [1_000])
        XCTAssertEqual(try matches(db, "artifacts_fts", "needle"), [])
        XCTAssertEqual(try db.scalarInt64("SELECT count(*) FROM messages"), 1)
        try integrityCheck(db)
    }

    func test_fts_integrity_check_passes_after_mixed_operations() throws {
        let db = try makeDatabase()
        let first = try insertSession(db, nativeID: "a")
        let second = try insertSession(db, nativeID: "b")
        try db.transaction {
            for index in 0..<50 {
                let session = index.isMultiple(of: 2) ? first : second
                try insertMessage(db, id: Int64(index) * 1_000, session: session, seq: Int64(index), text: "message number \(index) héllo")
                try insertArtifact(db, id: Int64(index) * 1_000, session: session, value: "/path/file\(index).swift")
            }
        }
        try db.run("UPDATE messages SET search_text = 'edited ' || id WHERE id % 3000 = 0")
        try db.run("DELETE FROM messages WHERE id % 7000 = 0")
        try db.run("UPDATE messages SET id = id + 1 WHERE id = 1000")
        try db.run("DELETE FROM artifacts WHERE id % 5000 = 0")
        try db.run("DELETE FROM sessions WHERE id = ?", [.integer(second)])

        try integrityCheck(db)
        XCTAssertEqual(try matches(db, "messages_fts", "edited"), try db.query(
            "SELECT id FROM messages WHERE search_text LIKE 'edited%' ORDER BY id"
        ) { $0.int64(0) })
        XCTAssertEqual(try matches(db, "messages_fts", "\"message number\""), try db.query(
            "SELECT id FROM messages WHERE search_text LIKE '%message number%' ORDER BY id"
        ) { $0.int64(0) })
    }

    // MARK: - Tokenizers

    func test_unicode61_fallback_schema_supports_prefix_queries() throws {
        let db = try makeDatabase(tokenizer: .unicode61)
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "update the configuration loader")
        try insertMessage(db, id: 2_000, session: session, seq: 1, text: "unrelated text")

        XCTAssertEqual(try matches(db, "messages_fts", "\"conf\"*"), [1_000])
        XCTAssertEqual(try matches(db, "messages_fts", "\"co\"*"), [1_000])
        XCTAssertEqual(try matches(db, "messages_fts", "loader"), [1_000])
        // Word tokens: an infix is not a match without trigram.
        XCTAssertEqual(try matches(db, "messages_fts", "figuration"), [])
        let sql = try XCTUnwrap(try db.queryOne("SELECT sql FROM sqlite_master WHERE name = 'messages_fts'") { $0.string(0) })
        XCTAssertTrue(sql.contains("prefix='2 3'"))
        try integrityCheck(db)
    }

    func test_none_tokenizer_creates_no_fts_tables_or_triggers() throws {
        let db = try makeDatabase(tokenizer: .none)
        let tables = try names(db, type: "table")
        XCTAssertFalse(tables.contains { $0.hasSuffix("_fts") || $0.contains("_fts_") })
        XCTAssertEqual(try names(db, type: "trigger"), [])
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(db), AgentHistoryTokenizer.none)
        XCTAssertNil(AgentHistorySchema.ftsTableSQL("messages_fts", content: "messages", tokenizer: .none))

        // Content rows still work.
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "plain row")
        try db.run("UPDATE messages SET search_text = 'x' WHERE id = 1000")
        try db.run("DELETE FROM sessions")
        XCTAssertEqual(try db.scalarInt64("SELECT count(*) FROM messages"), 0)
    }

    func test_tokenizer_change_rebuilds_fts_and_keeps_rows_searchable() throws {
        let db = try makeDatabase(tokenizer: .unicode61)
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "update the configuration loader")
        try insertArtifact(db, id: 1_000, session: session, value: "/src/config/loader.swift")
        XCTAssertEqual(try matches(db, "messages_fts", "figuration"), [])

        try AgentHistorySchema.rebuildFullText(db, to: .trigram)

        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(db), .trigram)
        XCTAssertEqual(try matches(db, "messages_fts", "figuration"), [1_000])
        XCTAssertEqual(try matches(db, "artifacts_fts", "\"fig/load\""), [1_000])
        XCTAssertEqual(try names(db, type: "trigger").count, 6)
        let sql = try XCTUnwrap(try db.queryOne("SELECT sql FROM sqlite_master WHERE name = 'messages_fts'") { $0.string(0) })
        XCTAssertTrue(sql.contains("trigram"))

        // The recreated triggers keep new rows in sync.
        try insertMessage(db, id: 2_000, session: session, seq: 1, text: "another configuration change")
        XCTAssertEqual(try matches(db, "messages_fts", "figuration"), [1_000, 2_000])
        try integrityCheck(db)

        // Down to none and back keeps the content rows.
        try AgentHistorySchema.rebuildFullText(db, to: .none)
        XCTAssertEqual(try names(db, type: "trigger"), [])
        XCTAssertEqual(try db.scalarInt64("SELECT count(*) FROM messages"), 2)
        try AgentHistorySchema.rebuildFullText(db, to: .trigram)
        XCTAssertEqual(try matches(db, "messages_fts", "figuration"), [1_000, 2_000])
        try integrityCheck(db)
    }

    func test_trigram_does_not_match_two_character_terms() throws {
        let db = try makeDatabase(tokenizer: .trigram)
        let session = try insertSession(db)
        try insertMessage(db, id: 1_000, session: session, seq: 0, text: "go to the ui layer")

        XCTAssertEqual(try matches(db, "messages_fts", "ui"), [])
        XCTAssertEqual(try matches(db, "messages_fts", "go"), [])
        XCTAssertEqual(try matches(db, "messages_fts", "\"ui \""), [1_000])
    }

    // MARK: - Migration entry point

    func test_migrate_from_zero_creates_version1_and_newer_throws() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let db = try AgentHistoryDatabase(url: directory.appendingPathComponent("index.sqlite"),
                                          mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        addTeardownBlock { db.close() }

        try AgentHistorySchema.migrate(db, from: 0, tokenizer: .trigram, now: now, appVersion: "1")
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(db), .trigram)
        try AgentHistorySchema.migrate(db, from: AgentHistorySchema.currentVersion, tokenizer: .trigram, now: now, appVersion: "1")
        XCTAssertThrowsError(try AgentHistorySchema.migrate(db, from: 2, tokenizer: .trigram, now: now, appVersion: "1")) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .schemaTooNew(found: 2))
        }
    }
}
