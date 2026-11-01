import Foundation
import XCTest
@testable import Zentty

/// Change detection when opencode deletes its newest rows or the file is replaced.
final class OpenCodeHistorySourceDetectionTests: OpenCodeHistorySourceTestCase {
    func test_deleting_newest_rows_reconciles_without_full_pass() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let clock = Clock(Self.t0)
        let hot = Self.t0 - 2 * Self.minute
        let cold = Self.t0 - Self.day
        for id in ["ses_colda", "ses_coldb"] {
            try fixture.addSession(id, createdMs: cold, updatedMs: cold)
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: cold)
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt \(id)", createdMs: cold)
        }
        try fixture.addSession("ses_hot", createdMs: hot, updatedMs: hot)
        try fixture.addMessage("msg_h", session: "ses_hot", role: "user", createdMs: hot)
        try fixture.addTextPart("prt_h", message: "msg_h", session: "ses_hot", text: "keep", createdMs: hot)
        try fixture.addMessage("msg_r", session: "ses_hot", role: "assistant", createdMs: hot + 1)
        try fixture.addTextPart("prt_r1", message: "msg_r", session: "ses_hot", text: "reverted one", createdMs: hot + 1)
        try fixture.addTextPart("prt_r2", message: "msg_r", session: "ses_hot", text: "reverted two", createdMs: hot + 2)
        let source = makeSource(fixture, clock: clock)
        let (_, afterPass) = try drain(source)
        let stored = try XCTUnwrap(state(afterPass).watermarks)

        // /undo cleanup drops the hot session's newest rows; one new part lands on a cold
        // session at a rowid below the stored mark.
        try fixture.deletePart("prt_r1")
        try fixture.deletePart("prt_r2")
        try fixture.addTextPart("prt_zlate", message: "msg_ses_coldb", session: "ses_coldb", text: "late",
                                createdMs: Self.t0)
        clock.nowMs = Self.t0 + Self.minute

        let (batches, cursor) = try drain(source, cursor: afterPass)
        XCTAssertEqual(batches.count, 1, "no multi-call full pass")
        XCTAssertEqual(Set(batches.flatMap(\.sessions).map(\.nativeID)), ["ses_hot", "ses_coldb"],
                       "only the hot session and what the reconcile found")
        XCTAssertEqual(texts(batches, "ses_hot"), ["keep"])
        XCTAssertEqual(texts(batches, "ses_coldb"), ["prompt ses_coldb\n\nlate"])
        let after = state(cursor)
        XCTAssertNil(after.backfill)
        XCTAssertEqual(after.lastReconcileAtMs, clock.nowMs, "the reconcile ran at once")
        XCTAssertLessThan(try XCTUnwrap(after.watermarks).partRowID, stored.partRowID)

        // The next poll is quiet again.
        let idle = try drain(source, cursor: cursor)
        XCTAssertTrue(idle.batches.flatMap(\.sessions).isEmpty)
    }

    func test_v2_incremental_rowid_hot_update_reconcile_and_deleted_tail() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let clock = Clock(Self.t0)
        let hot = Self.t0 - 2 * Self.minute
        let cold = Self.t0 - Self.day
        func reply(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
        try fixture.addSession("ses_live", in: .v2, version: "2.0.0", createdMs: hot, updatedMs: hot)
        try fixture.addSessionMessage("msg_lu", session: "ses_live", type: "user", seq: 1,
                                      data: ["text": "question"], createdMs: hot)
        try fixture.addSessionMessage("msg_la", session: "ses_live", type: "assistant", seq: 2,
                                      data: reply("partial"), createdMs: hot + 1)
        try fixture.addSession("ses_idle", in: .v2, version: "2.0.0", createdMs: cold, updatedMs: cold)
        try fixture.addSessionMessage("msg_iu", session: "ses_idle", type: "user", seq: 1,
                                      data: ["text": "old question"], createdMs: cold)
        let source = makeSource(fixture, clock: clock)
        let (_, afterPass) = try drain(source)

        // A new session_message row on the cold session: found by its rowid.
        try fixture.addSessionMessage("msg_ia", session: "ses_idle", type: "assistant", seq: 2,
                                      data: reply("old answer"), createdMs: cold + 1)
        let inserted = try drain(source, cursor: afterPass)
        XCTAssertEqual(inserted.batches.flatMap(\.sessions).map(\.nativeID), ["ses_idle"])
        XCTAssertEqual(texts(inserted.batches, "ses_idle"), ["old question", "old answer"])

        // The live assistant row streams in place (same rowid): only the hot set sees it.
        try fixture.updateSessionMessage("msg_la", data: reply("complete answer"), updatedMs: Self.t0)
        let streamed = try drain(source, cursor: inserted.cursor)
        XCTAssertEqual(streamed.batches.flatMap(\.sessions).map(\.nativeID), ["ses_live"])
        XCTAssertEqual(texts(streamed.batches, "ses_live"), ["question", "complete answer"])

        // Outside the hot window an in-place edit waits for the reconcile.
        clock.nowMs = Self.t0 + 11 * Self.minute
        try fixture.updateSessionMessage("msg_ia", data: reply("edited answer"), updatedMs: clock.nowMs)
        let quiet = try drain(source, cursor: streamed.cursor)
        XCTAssertTrue(quiet.batches.flatMap(\.sessions).isEmpty)
        clock.nowMs = Self.t0 + 16 * Self.minute
        let reconciled = try drain(source, cursor: quiet.cursor)
        XCTAssertEqual(reconciled.batches.flatMap(\.sessions).map(\.nativeID), ["ses_idle"])
        XCTAssertEqual(texts(reconciled.batches, "ses_idle"), ["old question", "edited answer"])

        // A new row on the live session, then /undo deletes it (the top session_message rowid).
        clock.nowMs = Self.t0 + 17 * Self.minute
        try fixture.addSessionMessage("msg_lu2", session: "ses_live", type: "user", seq: 3,
                                      data: ["text": "follow-up"], createdMs: clock.nowMs)
        let followUp = try drain(source, cursor: reconciled.cursor)
        XCTAssertEqual(texts(followUp.batches, "ses_live"), ["question", "complete answer", "follow-up"])
        let before = try XCTUnwrap(state(followUp.cursor).watermarks)

        clock.nowMs = Self.t0 + 18 * Self.minute
        try fixture.deleteSessionMessage("msg_lu2")
        let undone = try drain(source, cursor: followUp.cursor)
        XCTAssertEqual(undone.batches.count, 1, "no full pass")
        XCTAssertEqual(Set(undone.batches.flatMap(\.sessions).map(\.nativeID)), ["ses_live", "ses_idle"],
                       "every hot session is re-read (ses_idle changed at +11 minutes)")
        XCTAssertEqual(texts(undone.batches, "ses_live"), ["question", "complete answer"])
        let after = state(undone.cursor)
        XCTAssertNil(after.backfill)
        XCTAssertEqual(after.lastReconcileAtMs, clock.nowMs, "the reconcile ran at once")
        XCTAssertLessThan(try XCTUnwrap(after.watermarks).sessionMessageRowID, before.sessionMessageRowID)
    }

    func test_deleting_newest_session_removes_it_without_full_pass() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0 - Self.day
        for (index, id) in ["ses_old", "ses_new"].enumerated() {
            try fixture.addSession(id, createdMs: t, updatedMs: t + Int64(index))
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: t + Int64(index))
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt", createdMs: t + Int64(index))
        }
        let source = makeSource(fixture)
        let (_, afterPass) = try drain(source)

        try fixture.write { db in
            try db.run("DELETE FROM part WHERE session_id = 'ses_new'")
            try db.run("DELETE FROM message WHERE session_id = 'ses_new'")
        }
        try fixture.deleteSession("ses_new")

        let (batches, cursor) = try drain(source, cursor: afterPass)
        XCTAssertTrue(batches.flatMap(\.sessions).isEmpty, "ses_old is not read again")
        XCTAssertEqual(batches.flatMap(\.removedNativeIDs), ["ses_new"])
        XCTAssertNil(state(cursor).backfill)
        XCTAssertNil(state(cursor).lastChange["ses_new"])
    }

    /// opencode's delete-message/delete-part API removes rows without touching the session row,
    /// and a row below the table maximum moves no watermark. Session B owns every maximum.
    func test_deleting_non_newest_rows_of_cold_session_is_found_by_reconcile() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let clock = Clock(Self.t0)
        let cold = Self.t0 - Self.day
        try fixture.addSession("ses_a", createdMs: cold, updatedMs: cold)
        try fixture.addMessage("msg_a1", session: "ses_a", role: "user", createdMs: cold)
        try fixture.addTextPart("prt_a1", message: "msg_a1", session: "ses_a", text: "keep this", createdMs: cold)
        try fixture.addMessage("msg_a2", session: "ses_a", role: "user", createdMs: cold + 1)
        try fixture.addTextPart("prt_a2", message: "msg_a2", session: "ses_a", text: "secret to delete", createdMs: cold + 1)
        try fixture.addMessage("msg_a3", session: "ses_a", role: "user", createdMs: cold + 2)
        try fixture.addTextPart("prt_a3", message: "msg_a3", session: "ses_a", text: "keep that", createdMs: cold + 2)
        try fixture.addSession("ses_b", createdMs: cold, updatedMs: cold + 10)
        try fixture.addMessage("msg_b", session: "ses_b", role: "user", createdMs: cold + 10)
        try fixture.addTextPart("prt_b", message: "msg_b", session: "ses_b", text: "prompt b", createdMs: cold + 10)
        let source = makeSource(fixture, clock: clock)
        let (_, afterPass) = try drain(source)
        let stored = try XCTUnwrap(state(afterPass).watermarks)

        try fixture.deletePart("prt_a2")
        try fixture.write { try $0.run("DELETE FROM message WHERE id = 'msg_a2'") }
        clock.nowMs = Self.t0 + Self.minute
        let polled = try drain(source, cursor: afterPass)
        XCTAssertEqual(try XCTUnwrap(state(polled.cursor).watermarks), stored, "no watermark moved")

        clock.nowMs = Self.t0 + 16 * Self.minute
        let reconciled = try drain(source, cursor: polled.cursor)
        XCTAssertEqual(reconciled.batches.flatMap(\.sessions).map(\.nativeID), ["ses_a"])
        XCTAssertEqual(texts(reconciled.batches, "ses_a"), ["keep this", "keep that"])

        // The signature the reconcile computes matches the one recorded at ingest: no re-read loop.
        clock.nowMs = Self.t0 + 32 * Self.minute
        let next = try drain(source, cursor: reconciled.cursor)
        XCTAssertTrue(next.batches.flatMap(\.sessions).isEmpty)
    }

    /// The same deletion in a hot v2 session (a non-newest `session_message` row) is found by
    /// the next poll, without waiting for the reconcile.
    func test_deleting_non_newest_v2_row_of_hot_session_is_found_by_poll() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let clock = Clock(Self.t0)
        let hot = Self.t0 - 2 * Self.minute
        func reply(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
        try fixture.addSession("ses_a", in: .v2, version: "2.0.0", createdMs: hot, updatedMs: hot)
        try fixture.addSessionMessage("msg_a1", session: "ses_a", type: "user", seq: 1,
                                      data: ["text": "secret question"], createdMs: hot)
        try fixture.addSessionMessage("msg_a2", session: "ses_a", type: "assistant", seq: 2,
                                      data: reply("answer"), createdMs: hot + 1)
        try fixture.addSession("ses_b", in: .v2, version: "2.0.0", createdMs: hot, updatedMs: hot + 5)
        try fixture.addSessionMessage("msg_b1", session: "ses_b", type: "user", seq: 1,
                                      data: ["text": "prompt b"], createdMs: hot + 5)
        let source = makeSource(fixture, clock: clock)
        let (_, afterPass) = try drain(source)

        try fixture.deleteSessionMessage("msg_a1")
        clock.nowMs = Self.t0 + Self.minute
        let polled = try drain(source, cursor: afterPass)
        XCTAssertEqual(polled.batches.flatMap(\.sessions).map(\.nativeID), ["ses_a"])
        XCTAssertEqual(texts(polled.batches, "ses_a"), ["answer"])
        XCTAssertEqual(state(polled.cursor).lastReconcileAtMs, Self.t0, "found by the poll, not the reconcile")

        let idle = try drain(source, cursor: polled.cursor)
        XCTAssertTrue(idle.batches.flatMap(\.sessions).isEmpty)
    }

    func test_replaced_database_file_forces_full_pass() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0 - Self.day
        for id in ["ses_a", "ses_b"] {
            try fixture.addSession(id, createdMs: t, updatedMs: t)
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: t)
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt \(id)", createdMs: t)
        }
        let source = makeSource(fixture)
        let (_, afterPass) = try drain(source)

        // Same content under a new inode (a restored backup).
        fixture.close()
        let copy = fixture.rootURL.appendingPathComponent("copy.db")
        try FileManager.default.copyItem(at: fixture.databaseURL, to: copy)
        try FileManager.default.removeItem(at: fixture.databaseURL)
        try FileManager.default.moveItem(at: copy, to: fixture.databaseURL)

        let (batches, cursor) = try drain(source, cursor: afterPass)
        XCTAssertEqual(Set(batches.flatMap(\.sessions).map(\.nativeID)), ["ses_a", "ses_b"])
        XCTAssertNil(state(cursor).backfill, "the pass completed")
    }

    // MARK: - v2 schema drift

    /// A v2 table that exists but lacks a column read here is not the same as no v2 tables:
    /// reading on as v1 would drop every v2 session and report it deleted upstream.
    func test_v2_tables_with_unknown_layout_are_unsupported() throws {
        let cases: [(String, String)] = [
            ("session_message without data", "ALTER TABLE session_message RENAME COLUMN data TO payload"),
            ("session_v2 without parent_id", "ALTER TABLE session_v2 RENAME COLUMN parent_id TO parent"),
            ("session_v2 without session_message", "DROP TABLE session_message"),
            ("session_message without session_v2", "DROP TABLE session_v2"),
        ]
        for (name, change) in cases {
            let fixture = try OpenCodeHistoryFixture(testCase: self)
            try fixture.write { db in
                try db.execute(change)
                guard case .unsupported = try OpenCodeHistorySchema.probe(db) else {
                    return XCTFail("\(name): expected unsupported")
                }
            }
        }
        let v1Only = try OpenCodeHistoryFixture(testCase: self, v2: false)
        try v1Only.write { db in
            guard case let .supported(schema) = try OpenCodeHistorySchema.probe(db) else {
                return XCTFail("no v2 tables at all is a plain v1 database")
            }
            XCTAssertFalse(schema.hasV2)
        }
    }

    /// An opencode upgrade that reshapes `session_message` after v2 sessions were indexed must
    /// pause the source and say why, not remove the v2 sessions it can no longer read.
    func test_v2_layout_change_after_indexing_reports_schema_and_removes_nothing() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let clock = Clock(Self.t0)
        let t = Self.t0 - Self.day
        try fixture.addSession("ses_v1", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_v1", session: "ses_v1", role: "user", createdMs: t)
        try fixture.addTextPart("prt_v1", message: "msg_v1", session: "ses_v1", text: "v1 prompt", createdMs: t)
        try fixture.addSession("ses_v2", in: .v2, version: "2.0.0", createdMs: t, updatedMs: t)
        try fixture.addSessionMessage("msg_v2", session: "ses_v2", type: "user", seq: 1,
                                      data: ["text": "v2 prompt"], createdMs: t)
        let source = makeSource(fixture, clock: clock)
        let (indexed, afterPass) = try drain(source)
        XCTAssertEqual(texts(indexed, "ses_v2"), ["v2 prompt"])
        XCTAssertEqual(try source.existingNativeIDs(), ["ses_v1", "ses_v2"])

        try fixture.write { db in
            try db.execute("ALTER TABLE session_message RENAME COLUMN data TO payload")
        }
        clock.nowMs = Self.t0 + 16 * Self.minute
        let batch = try ingest(source, cursor: afterPass)
        guard case .unsupportedSchema? = batch.problem else {
            return XCTFail("expected unsupportedSchema, got \(String(describing: batch.problem))")
        }
        XCTAssertTrue(batch.removedNativeIDs.isEmpty, "nothing is inferred deleted while v2 is unreadable")
        XCTAssertTrue(batch.sessions.isEmpty, "no v1-only rewrite of merged sessions")
        XCTAssertFalse(batch.hasMore)
        XCTAssertNil(try source.existingNativeIDs(), "the indexer skips deletion inference too")
    }

    func test_identity_replacement_compares_device_and_inode_only() {
        let base = AgentHistoryFileIdentity(dev: 1, ino: 2, size: 10, mtimeNs: 5)
        XCTAssertFalse(OpenCodeHistorySource.isReplacement(of: base, by: AgentHistoryFileIdentity(dev: 1, ino: 2, size: 99, mtimeNs: 9)))
        XCTAssertTrue(OpenCodeHistorySource.isReplacement(of: base, by: AgentHistoryFileIdentity(dev: 1, ino: 3, size: 10, mtimeNs: 5)))
        XCTAssertFalse(OpenCodeHistorySource.isReplacement(of: nil, by: base))
    }
}
