import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryStoreIngestTests: XCTestCase {
    private typealias F = AgentHistoryFixtures
    private let t: Int64 = 1_790_000_000_000

    private func turnCount(_ db: AgentHistoryDatabase, _ id: Int64) throws -> Int64? {
        try db.scalarInt64("SELECT turn_count FROM sessions WHERE id = ?", [.integer(id)])
    }

    // MARK: - apply

    func test_apply_batch_replace_content_removed_and_turn_counts() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let db = store.database
        let sourceID = try index.makeSource()

        try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u",
            sessions: [F.session("a", title: "first ask"), F.session("b", title: "other")],
            messages: [
                F.message("a", seq: 0, atMs: t, text: "first ask"),
                F.message("a", seq: 1, role: .agent, atMs: t + 1, text: "answer"),
                F.message("b", seq: 0, atMs: t + 2, text: "other ask"),
                F.message("ghost", seq: 0, atMs: t + 3, text: "no session row"),
            ],
            artifacts: [F.artifact("a", seq: 1, value: "README.md", atMs: t + 1)]
        ), sourceID: sourceID, unitKey: "u")

        let a = try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: "a"))
        let b = try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: "b"))
        XCTAssertEqual(try turnCount(db, a), 1)
        XCTAssertEqual(try turnCount(db, b), 1)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM messages"), 3, "rows without a session are dropped")
        XCTAssertEqual(try db.scalarInt64("SELECT created_at FROM sessions WHERE id = ?", [.integer(a)]), t,
                       "created_at falls back to the first message")
        XCTAssertEqual(try db.scalarInt64("SELECT updated_at FROM sessions WHERE id = ?", [.integer(a)]), t + 1)

        // Rewrite "a" (two user turns now), remove "b" in the same batch.
        try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u",
            messages: [
                F.message("a", seq: 0, atMs: t, text: "rewritten ask"),
                F.message("a", seq: 1, atMs: t + 5, text: "second ask"),
            ],
            replaceContentOf: ["a"],
            removedNativeIDs: ["b"]
        ), sourceID: sourceID, unitKey: "u")

        XCTAssertEqual(try turnCount(db, a), 2)
        XCTAssertNil(try store.sessionID(sourceID: sourceID, nativeID: "b"))
        XCTAssertEqual(try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }, ["rewritten ask", "second ask"])
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM artifacts"), 0, "replaceContentOf clears artifacts too")
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "first"), [])
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "other"), [])
        try db.execute("INSERT INTO messages_fts(messages_fts) VALUES('integrity-check')")
        try db.execute("INSERT INTO artifacts_fts(artifacts_fts) VALUES('integrity-check')")
    }

    func test_apply_returns_touched_and_removed_ids() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource()

        let first = try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u",
            sessions: [F.session("a"), F.session("b")],
            messages: [F.message("a", seq: 0, atMs: t, text: "hi")]
        ), sourceID: sourceID, unitKey: "u")
        let a = try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: "a"))
        let b = try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: "b"))
        XCTAssertEqual(first, AgentHistoryApplyResult(touchedSessionIDs: [a, b], removedSessionIDs: []))

        let second = try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u",
            messages: [F.message("a", seq: 1, atMs: t + 1, text: "again")],
            removedNativeIDs: ["b", "never-stored"]
        ), sourceID: sourceID, unitKey: "u")
        XCTAssertEqual(second, AgentHistoryApplyResult(touchedSessionIDs: [a], removedSessionIDs: [b]))

        let third = try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u", sessions: [F.session("a", title: "x")], removedNativeIDs: ["a"]
        ), sourceID: sourceID, unitKey: "u")
        XCTAssertEqual(third, AgentHistoryApplyResult(touchedSessionIDs: [], removedSessionIDs: [a]),
                       "a removed session is not reported as touched")
    }

    func test_apply_rolls_back_whole_batch_on_failure() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let db = store.database
        let sourceID = try index.makeSource()
        try db.execute("CREATE TEMP TRIGGER fail_on_boom BEFORE INSERT ON messages WHEN new.text = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END")

        XCTAssertThrowsError(try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u", sessions: [F.session("a")],
            messages: [F.message("a", seq: 0, atMs: t, text: "fine"), F.message("a", seq: 1, atMs: t + 1, text: "boom")]
        ), sourceID: sourceID, unitKey: "u"))
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM sessions"), 0)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM messages"), 0)
    }

    // MARK: - Unit purges and counts

    func test_unit_purges_and_counts() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let db = store.database
        let sourceID = try index.makeSource()
        let other = try index.makeSource(.grok, root: "/fixtures/grok")
        for (unit, ids) in [("u1", ["a", "b"]), ("u2", ["c"])] {
            try store.apply(F.batch(
                sourceID: sourceID, unitKey: unit, sessions: ids.map { F.session($0) },
                messages: ids.enumerated().map { F.message($1, seq: 0, atMs: t + Int64($0), text: "text \($1)") }
            ), sourceID: sourceID, unitKey: unit)
        }
        try store.apply(F.batch(sourceID: other, unitKey: "g", sessions: [F.session("z")],
                                messages: [F.message("z", seq: 0, role: .agent, atMs: t, text: "agent only")]),
                        sourceID: other, unitKey: "g")

        XCTAssertEqual(try store.sessionCount(sourceID: sourceID), 3)
        XCTAssertEqual(try store.sessionCount(sourceID: other), 1)
        XCTAssertEqual(try store.visibleSessionCount(), 3, "zero-turn sessions are not visible")
        XCTAssertTrue(try store.hasSessions(sourceID: sourceID, unitKey: "u1"))

        try store.deleteSessionContent(sourceID: sourceID, unitKey: "u1")
        XCTAssertEqual(try store.sessionCount(sourceID: sourceID), 3)
        XCTAssertEqual(try store.visibleSessionCount(), 1)

        let removed = try store.deleteSessions(sourceID: sourceID, unitKey: "u1")
        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(try store.hasSessions(sourceID: sourceID, unitKey: "u1"))
        XCTAssertEqual(try store.indexedNativeIDs(sourceID: sourceID), ["c"])

        XCTAssertEqual(try store.deleteSessions(sourceID: sourceID, nativeIDs: ["c", "nope"]).count, 1)
        XCTAssertEqual(try store.deleteSessions(sourceID: other).count, 1)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM sessions"), 0)
        XCTAssertEqual(try F.count(db, "SELECT count(*) FROM messages"), 0)
    }

    // MARK: - Summaries

    func test_visible_summaries_hide_children_and_zero_turn_sessions() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource(.codex, root: "/fixtures/codex")
        try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u",
            sessions: [
                F.session("visible", title: "Fix Café Login", kind: .generated, cwd: "/work/zentty/sub",
                          repoRoot: "/work/zentty", branch: "Feat/Login", createdAtMs: t, updatedAtMs: t + 9),
                F.session("child", title: "child", parentNativeID: "visible"),
                F.session("quiet", title: "quiet"),
                F.session("older", title: "older", updatedAtMs: t - 100),
            ],
            messages: [
                F.message("visible", seq: 0, atMs: t, text: "fix login"),
                F.message("child", seq: 0, atMs: t, text: "child ask"),
                F.message("quiet", seq: 0, role: .agent, atMs: t, text: "no user turn"),
                F.message("older", seq: 0, atMs: t - 100, text: "old"),
            ]
        ), sourceID: sourceID, unitKey: "u")

        let all = try store.allVisibleSessionSummaries()
        XCTAssertEqual(all.map(\.nativeID), ["visible", "older"], "updated_at descending")

        let visible = try XCTUnwrap(all.first)
        XCTAssertEqual(visible.agent, .codex)
        XCTAssertEqual(visible.sourceRoot, "/fixtures/codex")
        XCTAssertEqual(visible.titleKind, .generated)
        XCTAssertEqual(visible.turnCount, 1)
        XCTAssertEqual(visible.createdAt, Date(timeIntervalSince1970: TimeInterval(t) / 1000))
        XCTAssertEqual(visible.updatedAtMs, t + 9)
        XCTAssertEqual(visible.key, AgentHistorySessionKey(agent: .codex, nativeID: "visible"))
        XCTAssertEqual(visible.repoName, "zentty")
        XCTAssertEqual(visible.folderName, "sub")
        XCTAssertEqual(visible.titleKey, "fix cafe login")
        XCTAssertEqual(visible.branchKey, "feat/login")
        XCTAssertEqual(visible.repoKey, "zentty")
        XCTAssertEqual(visible.folderKey, "sub")
        XCTAssertNil(visible.lastOpenedAt)

        let ids = try ["older", "child", "quiet", "visible", "older"].map {
            try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: $0))
        }
        XCTAssertEqual(try store.sessionSummaries(rowIDs: ids).map(\.nativeID), ["older", "visible"],
                       "input order, deduplicated, visible only")
        XCTAssertEqual(try store.sessionSummaries(rowIDs: []), [])
    }

    func test_summary_reads_every_column_into_its_own_field() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource(.grok, root: "/fixtures/grok")
        var draft = AgentHistorySessionDraft(nativeID: "every-column")
        draft.title = "Distinct title"
        draft.titleKind = .custom
        draft.cwd = "/work/cwd-folder"
        draft.repoRoot = "/work/linked-root"
        draft.mainRepoRoot = "/work/main-root"
        draft.branch = "distinct-branch"
        draft.model = "distinct-model"
        draft.effort = "distinct-effort"
        draft.generation = "distinct-generation"
        draft.transcriptPath = "/transcripts/distinct.jsonl"
        draft.createdAtMs = t
        draft.updatedAtMs = t + 9
        draft.lastUserAtMs = t + 5
        draft.archived = true
        try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u", sessions: [draft],
            messages: [F.message("every-column", seq: 0, atMs: t + 5, text: "ask")]
        ), sourceID: sourceID, unitKey: "u")
        let id = try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: "every-column"))
        XCTAssertTrue(try store.recordOpen(sessionID: id, atMs: t + 20))
        XCTAssertTrue(try store.recordOpen(sessionID: id, atMs: t + 30))

        let summary = try XCTUnwrap(store.allVisibleSessionSummaries().first)
        XCTAssertEqual(try store.sessionSummaries(rowIDs: [id]), [summary])
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.sourceID, sourceID)
        XCTAssertEqual(summary.sourceRoot, "/fixtures/grok")
        XCTAssertEqual(summary.agent, .grok)
        XCTAssertEqual(summary.nativeID, "every-column")
        XCTAssertEqual(summary.title, "Distinct title")
        XCTAssertEqual(summary.titleKind, .custom)
        XCTAssertEqual(summary.cwd, "/work/cwd-folder")
        XCTAssertEqual(summary.repoRoot, "/work/linked-root")
        XCTAssertEqual(summary.mainRepoRoot, "/work/main-root")
        XCTAssertEqual(summary.branch, "distinct-branch")
        XCTAssertEqual(summary.model, "distinct-model")
        XCTAssertEqual(summary.effort, "distinct-effort")
        XCTAssertEqual(summary.generation, "distinct-generation")
        XCTAssertEqual(summary.transcriptPath, "/transcripts/distinct.jsonl")
        XCTAssertEqual(summary.createdAtMs, t)
        XCTAssertEqual(summary.updatedAtMs, t + 9)
        XCTAssertEqual(summary.lastUserAtMs, t + 5)
        XCTAssertEqual(summary.turnCount, 1)
        XCTAssertTrue(summary.isArchived)
        XCTAssertEqual(summary.opens, 2)
        XCTAssertEqual(summary.lastOpenedAtMs, t + 30)
        XCTAssertEqual(summary.repoName, "main-root", "repo name comes from main_repo_root")
        XCTAssertEqual(summary.folderName, "cwd-folder")
    }

    func test_session_summaries_span_multiple_chunks() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource()
        let count = AgentHistoryStore.summaryChunkSize * 2 + 5
        let names = (0..<count).map { "s\($0)" }
        try store.apply(F.batch(
            sourceID: sourceID, unitKey: "u", sessions: names.map { F.session($0) },
            messages: names.enumerated().map { F.message($1, seq: 0, atMs: t + Int64($0), text: "ask") }
        ), sourceID: sourceID, unitKey: "u")
        let ids = try names.reversed().map { try XCTUnwrap(store.sessionID(sourceID: sourceID, nativeID: $0)) }
        XCTAssertEqual(try store.sessionSummaries(rowIDs: ids).map(\.nativeID), names.reversed())
    }

    // MARK: - Bookkeeping

    func test_cursor_round_trip_with_fingerprint_rejected_and_adapter_state() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource()
        let full = AgentHistoryCursor(
            sourceID: sourceID, unitKey: "p/a.jsonl",
            identity: AgentHistoryFileIdentity(dev: 16_777_234, ino: Int64.max, size: 4_096, mtimeNs: 1_790_000_000_123_456_789),
            byteOffset: 4_000, nextSeq: 12, watermark: t, fingerprint: -42,
            isRejected: true, adapterState: Data([0, 1, 2, 255])
        )
        let bare = AgentHistoryCursor(sourceID: sourceID, unitKey: "db")
        try store.saveCursor(full)
        try store.saveCursor(bare)
        XCTAssertEqual(try store.cursors(sourceID: sourceID), ["p/a.jsonl": full, "db": bare])

        var moved = full
        moved.byteOffset = 5_000
        moved.isRejected = false
        moved.adapterState = nil
        try store.saveCursor(moved)
        XCTAssertEqual(try store.cursors(sourceID: sourceID)["p/a.jsonl"], moved)

        try store.markCursorsRejected(sourceID: sourceID, unitKeys: ["p/a.jsonl", "new-unit"])
        let rejected = try store.cursors(sourceID: sourceID)
        XCTAssertEqual(rejected["p/a.jsonl"]?.isRejected, true)
        XCTAssertEqual(rejected["p/a.jsonl"]?.byteOffset, 5_000)
        XCTAssertEqual(rejected["new-unit"], AgentHistoryCursor(sourceID: sourceID, unitKey: "new-unit", isRejected: true))

        try store.clearRejectedCursors()
        XCTAssertEqual(Set(try store.cursors(sourceID: sourceID).keys), ["db"])
        try store.deleteCursor(sourceID: sourceID, unitKey: "db")
        XCTAssertEqual(try store.cursors(sourceID: sourceID), [:])
        try store.saveCursor(bare)
        try store.deleteCursors(sourceID: sourceID)
        XCTAssertEqual(try store.cursors(sourceID: sourceID), [:])
    }

    func test_source_upsert_unique_per_agent_and_root_and_keeps_adapter_version() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let first = try store.upsertSource(agent: .claude, root: "/r", currentAdapterVersion: 1)
        let again = try store.upsertSource(agent: .claude, root: "/r", currentAdapterVersion: 2)
        XCTAssertEqual(again, first)
        XCTAssertEqual(again.adapterVersion, 1, "upsert never overwrites the stored adapter version")
        XCTAssertTrue(first.enabled)

        try store.setAdapterVersion(sourceID: first.id, 2)
        XCTAssertEqual(try store.upsertSource(agent: .claude, root: "/r", currentAdapterVersion: 3).adapterVersion, 2)
        let otherRoot = try store.upsertSource(agent: .claude, root: "/r2", currentAdapterVersion: 1)
        let otherAgent = try store.upsertSource(agent: .codex, root: "/r", currentAdapterVersion: 1)
        XCTAssertEqual(Set([first.id, otherRoot.id, otherAgent.id]).count, 3)
        XCTAssertEqual(try store.sources().map(\.id), [first.id, otherRoot.id, otherAgent.id])
    }

    func test_source_health_update() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let id = try index.makeSource()
        try store.updateSourceHealth(id: id, discovered: 10, indexed: 8, skipped: 2, lastScanAt: t, lastError: "busy")
        try store.setSourceEnabled(id: id, false)
        let row = try XCTUnwrap(store.sources().first)
        XCTAssertEqual(row, AgentHistorySourceRow(id: id, agent: .claude, root: "/fixtures/claude", adapterVersion: 1,
                                                  enabled: false, discovered: 10, indexed: 8, skipped: 2,
                                                  lastScanAt: t, lastError: "busy"))
        try store.updateSourceHealth(id: id, discovered: 10, indexed: 10, skipped: 0, lastScanAt: t + 1, lastError: nil)
        XCTAssertNil(try store.sources().first?.lastError)
    }

    func test_deleting_source_cascades_sessions_messages_fts() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let db = store.database
        let sourceID = try index.makeSource()
        try store.apply(F.batch(sourceID: sourceID, unitKey: "u", sessions: [F.session("a")],
                                messages: [F.message("a", seq: 0, atMs: t, text: "cascade check")],
                                artifacts: [F.artifact("a", seq: 0, value: "cascade.txt", atMs: t)]),
                        sourceID: sourceID, unitKey: "u")
        try store.saveCursor(AgentHistoryCursor(sourceID: sourceID, unitKey: "u"))

        try db.run("DELETE FROM sources WHERE id = ?", [.integer(sourceID)])
        for table in ["sessions", "messages", "artifacts", "cursors"] {
            XCTAssertEqual(try F.count(db, "SELECT count(*) FROM \(table)"), 0, table)
        }
        XCTAssertEqual(try F.ftsRowIDs(db, matching: "cascade"), [])
        XCTAssertEqual(try F.ftsRowIDs(db, table: "artifacts_fts", matching: "cascade"), [])
    }

    func test_meta_and_optimize() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        XCTAssertNil(try store.meta("backfill_complete"))
        try store.setMeta("backfill_complete", "1")
        try store.setMeta("backfill_complete", "2")
        XCTAssertEqual(try store.meta("backfill_complete"), "2")
        XCTAssertEqual(try store.meta(AgentHistorySchema.MetaKey.appVersion), "test")
        XCTAssertNoThrow(try store.optimize())
    }
}
