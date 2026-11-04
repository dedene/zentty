import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryStoreTests: XCTestCase {
    private typealias F = AgentHistoryFixtures
    private let sid = "11111111-1111-4111-8111-111111111111"
    private let t: Int64 = 1_790_000_000_000

    private func setUp(_ index: AgentHistoryTestIndex) throws -> (AgentHistoryStore, AgentHistoryDatabase, Int64) {
        let store = try index.makeStore()
        let sourceID = try index.makeSource()
        return (store, store.database, sourceID)
    }

    private func messageIDs(_ db: AgentHistoryDatabase, session: Int64) throws -> [Int64] {
        try db.query("SELECT id FROM messages WHERE session_id = ? ORDER BY seq", [.integer(session)]) { $0.int64(0) }
    }

    // MARK: - Row ids

    func test_row_id_is_timestamp_times_thousand() throws {
        XCTAssertEqual(AgentHistoryStore.rowIDBase(at: 1_700_000_000_123), 1_700_000_000_123_000)
        XCTAssertEqual(AgentHistoryStore.rowIDBase(at: -5), 0)
        XCTAssertEqual(AgentHistoryStore.rowIDBase(at: .max), 9_000_000_000_000 * 1000)

        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, atMs: t, text: "hello there")])
        XCTAssertEqual(try messageIDs(db, session: session), [t * 1000])
    }

    func test_same_millisecond_messages_get_sequential_ids() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertMessages(sessionID: session, (0..<3).map { F.message(sid, seq: $0, atMs: t, text: "m\($0)") })
        XCTAssertEqual(try messageIDs(db, session: session), [t * 1000, t * 1000 + 1, t * 1000 + 2])
    }

    func test_thousand_collisions_spill_to_next_millisecond_and_fts_order_stays_monotonic() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        let burst = (0...1000).map { F.message(sid, seq: $0, atMs: t, text: "needle \($0)") }
        try db.transaction { try store.upsertMessages(sessionID: session, burst) }
        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 1001, atMs: t + 1, text: "needle later")])

        let ids = try messageIDs(db, session: session)
        XCTAssertEqual(ids[999], t * 1000 + 999)
        XCTAssertEqual(ids[1000], (t + 1) * 1000, "the 1001st row spills into the next millisecond")
        XCTAssertEqual(ids[1001], (t + 1) * 1000 + 1)

        let ftsOrder = try F.ftsRowIDs(db, matching: "needle")
        XCTAssertEqual(ftsOrder.count, 1002)
        let ats = try ftsOrder.map { try XCTUnwrap(db.scalarInt64("SELECT at FROM messages WHERE id = ?", [.integer($0)])) }
        XCTAssertEqual(ats, ats.sorted(by: >), "rowid order is time order")
    }

    func test_backfilled_older_session_sorts_before_newer_by_rowid() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let newer = try store.upsertSession(sourceID: sourceID, unitKey: "new", F.session("new"))
        try store.upsertMessages(sessionID: newer, [F.message("new", seq: 0, atMs: t + 60_000, text: "deploy newer")])
        let older = try store.upsertSession(sourceID: sourceID, unitKey: "old", F.session("old"))
        try store.upsertMessages(sessionID: older, [F.message("old", seq: 0, atMs: t, text: "deploy older")])

        let newerID = try XCTUnwrap(messageIDs(db, session: newer).first)
        let olderID = try XCTUnwrap(messageIDs(db, session: older).first)
        XCTAssertLessThan(olderID, newerID)
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "deploy"), [newerID, olderID])
    }

    func test_upsert_same_seq_keeps_id_and_does_not_duplicate_fts() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, atMs: t, text: "alpha bravo")])
        let id = try XCTUnwrap(messageIDs(db, session: session).first)

        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, atMs: t, text: "alpha bravo")])
        XCTAssertEqual(try messageIDs(db, session: session), [id])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "alpha"), [id])

        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, role: .agent, atMs: t, text: "charlie delta")])
        XCTAssertEqual(try messageIDs(db, session: session), [id])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "alpha"), [])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "charlie"), [id])
        XCTAssertEqual(try db.queryOne("SELECT role FROM messages WHERE id = ?", [.integer(id)]) { $0.string(0) }, "agent")
        try db.execute("INSERT INTO messages_fts(messages_fts) VALUES('integrity-check')")
    }

    func test_changed_at_reinserts_with_new_chronological_id() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, atMs: t, text: "moving message")])
        try store.upsertMessages(sessionID: session, [F.message(sid, seq: 0, atMs: t + 5, text: "moving message")])

        let ids = try messageIDs(db, session: session)
        XCTAssertEqual(ids, [(t + 5) * 1000])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "moving"), ids)
        try db.execute("INSERT INTO messages_fts(messages_fts) VALUES('integrity-check')")
    }

    func test_artifacts_dedupe_by_kind_and_value() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let session = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertArtifacts(sessionID: session, [
            F.artifact(sid, seq: 1, kind: .path, value: "src/main.swift", atMs: t),
            F.artifact(sid, seq: 4, kind: .path, value: "src/main.swift", atMs: t + 9),
            F.artifact(sid, seq: 5, kind: .command, value: "src/main.swift", atMs: t + 10),
        ])
        try store.upsertArtifacts(sessionID: session, [F.artifact(sid, seq: 7, kind: .path, value: "src/main.swift", atMs: t + 20)])

        let rows = try db.query("SELECT id, seq, kind FROM artifacts ORDER BY id") { ($0.int64(0), $0.int64(1), $0.string(2)) }
        XCTAssertEqual(rows.map(\.0), [t * 1000, (t + 10) * 1000])
        XCTAssertEqual(rows.map(\.1), [1, 5], "the first sighting wins")
        XCTAssertEqual(rows.map(\.2), ["path", "command"])
        XCTAssertEqual(try F.ftsRowIDs(db, table: "artifacts_fts", matching: "main.swift").count, 2)
    }

    // MARK: - Sessions

    func test_session_upsert_returns_stable_id() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let first = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid, title: "one", updatedAtMs: t))
        let second = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid, title: "two", updatedAtMs: t + 1))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.sessionID(sourceID: sourceID, nativeID: sid), first)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM sessions"), 1)

        let other = try store.upsertSession(sourceID: try index.makeSource(.codex, root: "/c"), unitKey: "u", F.session(sid))
        XCTAssertNotEqual(other, first, "the same native id under another source is another row")
    }

    func test_insert_defaults_fill_title_kind_and_timestamps() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let fromMessages = try store.upsertSession(
            sourceID: sourceID, unitKey: "u", F.session("a"), firstMessageAtMs: t, lastMessageAtMs: t + 50
        )
        let fromClock = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session("b"))
        let read = { (id: Int64) in
            try db.queryOne("SELECT title, title_kind, created_at, updated_at, archived FROM sessions WHERE id = ?",
                            [.integer(id)]) { [$0.value(0), $0.value(1), $0.value(2), $0.value(3), $0.value(4)] }
        }
        XCTAssertEqual(try read(fromMessages), ["", "first_prompt", .integer(t), .integer(t + 50), 0])
        let now = AgentHistorySchema.milliseconds(since1970: AgentHistoryTestIndex.fixedNow)
        XCTAssertEqual(try read(fromClock), ["", "first_prompt", .integer(now), .integer(now), 0])
    }

    func test_merge_table_matches_swift_merge() throws {
        for row in AgentHistoryMergeTable.cases {
            let index = AgentHistoryTestIndex(testCase: self)
            let (store, db, sourceID) = try setUp(index)
            let id = try store.upsertSession(sourceID: sourceID, unitKey: "u", row.existing)
            XCTAssertEqual(try store.upsertSession(sourceID: sourceID, unitKey: nil, row.update), id, row.name)

            let stored = try XCTUnwrap(db.queryOne(
                """
                SELECT native_id, title, title_kind, cwd, repo_root, main_repo_root, branch, model, effort,
                       generation, transcript_path, created_at, updated_at, last_user_at, archived, parent_native_id
                FROM sessions WHERE id = ?
                """, [.integer(id)]
            ) { r -> AgentHistorySessionDraft in
                var d = AgentHistorySessionDraft(nativeID: r.string(0))
                d.title = r.string(1)
                d.titleKind = AgentHistoryTitleKind(rawValue: r.string(2))
                d.cwd = r.optionalString(3)
                d.repoRoot = r.optionalString(4)
                d.mainRepoRoot = r.optionalString(5)
                d.branch = r.optionalString(6)
                d.model = r.optionalString(7)
                d.effort = r.optionalString(8)
                d.generation = r.optionalString(9)
                d.transcriptPath = r.optionalString(10)
                d.createdAtMs = r.int64(11)
                d.updatedAtMs = r.int64(12)
                d.lastUserAtMs = r.optionalInt64(13)
                d.archived = r.bool(14)
                d.parentNativeID = r.optionalString(15)
                return d
            }, row.name)
            XCTAssertEqual(stored, row.expected, row.name)
            XCTAssertEqual(stored, AgentHistorySessionDraft.merged(existing: row.existing, update: row.update), row.name)
        }
    }

    func test_upsert_preserves_opens() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let id = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid, title: "t"))
        XCTAssertTrue(try store.recordOpen(sessionID: id, atMs: t))
        try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid, title: "t2", kind: .custom, updatedAtMs: t + 1))
        let usage = try db.queryOne("SELECT opens, last_opened_at FROM sessions WHERE id = ?", [.integer(id)]) {
            [$0.int64(0), $0.int64(1)]
        }
        XCTAssertEqual(usage, [1, t])
    }

    func test_record_open_increments_and_reports_missing_row() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let id = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        XCTAssertTrue(try store.recordOpen(sessionID: id, atMs: t + 10))
        XCTAssertTrue(try store.recordOpen(sessionID: id, atMs: t))
        let usage = try db.queryOne("SELECT opens, last_opened_at FROM sessions WHERE id = ?", [.integer(id)]) {
            [$0.int64(0), $0.int64(1)]
        }
        XCTAssertEqual(usage, [2, t + 10], "last_opened_at never moves backwards")
        try store.deleteSession(id: id)
        XCTAssertFalse(try store.recordOpen(sessionID: id, atMs: t + 20))
    }

    func test_usage_carryover_applies_on_insert_only() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let insertCarry = "INSERT INTO usage_carryover (agent, native_id, opens, last_opened_at) VALUES (?, ?, ?, ?)"
        try db.run(insertCarry, ["claude", .text(sid), 3, .integer(t)])
        let id = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        let usage = try db.queryOne("SELECT opens, last_opened_at FROM sessions WHERE id = ?", [.integer(id)]) {
            [$0.int64(0), $0.int64(1)]
        }
        XCTAssertEqual(usage, [3, t])
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM usage_carryover"), 0)

        try db.run(insertCarry, ["claude", .text(sid), 9, .integer(t + 1)])
        try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid, title: "update"))
        XCTAssertEqual(try db.scalarInt64("SELECT opens FROM sessions WHERE id = ?", [.integer(id)]), 3)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM usage_carryover"), 1, "an update leaves carry-over alone")
    }

    func test_turn_count_counts_user_messages() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        let id = try store.upsertSession(sourceID: sourceID, unitKey: "u", F.session(sid))
        try store.upsertMessages(sessionID: id, [
            F.message(sid, seq: 0, role: .user, atMs: t, text: "q1"),
            F.message(sid, seq: 1, role: .agent, atMs: t + 1, text: "a1"),
            F.message(sid, seq: 2, role: .user, atMs: t + 2, text: "q2"),
        ])
        try store.refreshTurnCount(sessionID: id)
        XCTAssertEqual(try db.scalarInt64("SELECT turn_count FROM sessions WHERE id = ?", [.integer(id)]), 2)
        try store.deleteSessionContent(sessionID: id)
        XCTAssertEqual(try db.scalarInt64("SELECT turn_count FROM sessions WHERE id = ?", [.integer(id)]), 0)
    }

    func test_delete_session_content_then_reingest_swaps_atomically() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, db, sourceID) = try setUp(index)
        try store.apply(F.batch(sourceID: sourceID, unitKey: "u", sessions: [F.session(sid)],
                                messages: [F.message(sid, seq: 0, atMs: t, text: "original words")]),
                        sourceID: sourceID, unitKey: "u")
        let readTexts = {
            try index.storage.readers.withReader { reader in
                try reader.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }
            }
        }

        try db.transaction {
            try store.deleteSessionContent(sourceID: sourceID, unitKey: "u")
            try store.apply(F.batch(sourceID: sourceID, unitKey: "u", sessions: [F.session(sid)],
                                    messages: [F.message(sid, seq: 0, atMs: t, text: "rewritten words"),
                                               F.message(sid, seq: 1, atMs: t + 1, text: "more words")]),
                            sourceID: sourceID, unitKey: "u")
            XCTAssertEqual(try readTexts(), ["original words"], "readers never see the half-done swap")
        }
        XCTAssertEqual(try readTexts(), ["rewritten words", "more words"])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "original"), [])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "words").count, 2)
    }

    func test_delete_sessions_under_folder_respects_path_boundary() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, _, sourceID) = try setUp(index)
        let cwds: [String: String?] = ["a": "/a/foo", "b": "/a/foo/bar", "c": "/a/foobar", "d": "/a/fo", "e": nil]
        var ids: [String: Int64] = [:]
        for (name, cwd) in cwds {
            ids[name] = try store.upsertSession(sourceID: sourceID, unitKey: name, F.session(name, cwd: cwd))
        }
        let removed = try store.deleteSessions(underFolders: ["/a/foo"])
        XCTAssertEqual(Set(removed.map(\.rowID)), [ids["a"]!, ids["b"]!])
        XCTAssertEqual(Set(removed.compactMap(\.unitKey)), ["a", "b"])
        XCTAssertTrue(removed.allSatisfy { $0.sourceID == sourceID })
        XCTAssertEqual(try store.indexedNativeIDs(sourceID: sourceID), ["c", "d", "e"])

        let matcher = AgentHistoryExclusionMatcher(folders: ["/a/foo"])
        for (_, cwd) in cwds where cwd != nil {
            XCTAssertEqual(matcher.excludesCanonical(cwd), ["/a/foo", "/a/foo/bar"].contains(cwd!), "SQL and Swift agree")
        }

        let all = try store.deleteSessions(underFolders: ["/"])
        XCTAssertEqual(Set(all.map(\.rowID)), [ids["c"]!, ids["d"]!], "nil cwd never matches")
    }

    func test_tombstone_deletes_rows_and_is_reported() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, _, claudeA) = try setUp(index)
        let claudeB = try index.makeSource(.claude, root: "/other/claude")
        let codex = try index.makeSource(.codex, root: "/fixtures/codex")
        let a = try store.upsertSession(sourceID: claudeA, unitKey: "u", F.session(sid))
        let b = try store.upsertSession(sourceID: claudeB, unitKey: "u", F.session(sid))
        try store.upsertSession(sourceID: codex, unitKey: "u", F.session(sid))

        let key = AgentHistorySessionKey(agent: .claude, nativeID: sid)
        XCTAssertEqual(Set(try store.addTombstone(key, removedAtMs: t)), [a, b])
        XCTAssertEqual(try store.tombstones(), [key])
        XCTAssertEqual(try store.tombstoneCount(), 1)
        XCTAssertEqual(try store.indexedNativeIDs(sourceID: codex), [sid], "other agents keep the id")
        XCTAssertEqual(try store.addTombstone(key, removedAtMs: t + 1), [])
        XCTAssertEqual(try store.tombstoneCount(), 1)
    }

    func test_remove_all_tombstones() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, _, _) = try setUp(index)
        try store.addTombstone(AgentHistorySessionKey(agent: .claude, nativeID: "a"), removedAtMs: t)
        try store.addTombstone(AgentHistorySessionKey(agent: .grok, nativeID: "b"), removedAtMs: t)
        XCTAssertEqual(try store.removeAllTombstones(), 2)
        XCTAssertEqual(try store.tombstoneCount(), 0)
        XCTAssertEqual(try store.tombstones(), [])
    }

    func test_unit_key_repoints_on_rename() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let (store, _, sourceID) = try setUp(index)
        try store.upsertSession(sourceID: sourceID, unitKey: "s.jsonl", F.session(sid))
        try store.upsertSession(sourceID: sourceID, unitKey: "s.jsonl.zst", F.session(sid))
        XCTAssertFalse(try store.hasSessions(sourceID: sourceID, unitKey: "s.jsonl"))
        XCTAssertTrue(try store.hasSessions(sourceID: sourceID, unitKey: "s.jsonl.zst"))
        try store.upsertSession(sourceID: sourceID, unitKey: nil, F.session(sid))
        XCTAssertTrue(try store.hasSessions(sourceID: sourceID, unitKey: "s.jsonl.zst"), "nil keeps the stored key")
    }
}
