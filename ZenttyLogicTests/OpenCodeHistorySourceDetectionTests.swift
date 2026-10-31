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

    func test_identity_replacement_compares_device_and_inode_only() {
        let base = AgentHistoryFileIdentity(dev: 1, ino: 2, size: 10, mtimeNs: 5)
        XCTAssertFalse(OpenCodeHistorySource.isReplacement(of: base, by: AgentHistoryFileIdentity(dev: 1, ino: 2, size: 99, mtimeNs: 9)))
        XCTAssertTrue(OpenCodeHistorySource.isReplacement(of: base, by: AgentHistoryFileIdentity(dev: 1, ino: 3, size: 10, mtimeNs: 5)))
        XCTAssertFalse(OpenCodeHistorySource.isReplacement(of: nil, by: base))
    }
}
