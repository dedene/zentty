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
