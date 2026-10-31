import Foundation
import XCTest
@testable import Zentty

/// Malformed rows, sessions that cannot be read, cancellation and batch limits.
final class OpenCodeHistorySourceRobustnessTests: OpenCodeHistorySourceTestCase {
    /// Makes chosen sessions fail to load and counts the attempts.
    private final class FailingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var failing: Set<String>
        private var attempts: [String: Int] = [:]

        init(failing: Set<String>) { self.failing = failing }

        func setFailing(_ ids: Set<String>) {
            lock.withLock { failing = ids }
        }

        func attempts(_ id: String) -> Int {
            lock.withLock { attempts[id] ?? 0 }
        }

        var loader: OpenCodeHistorySource.SessionLoader {
            { [self] db, schema, id in
                let fails = lock.withLock { () -> Bool in
                    attempts[id, default: 0] += 1
                    return failing.contains(id)
                }
                if fails {
                    throw AgentHistoryDatabaseError(kind: .other, code: 1, extendedCode: 1, message: "malformed JSON")
                }
                return try OpenCodeHistoryQueries.loadSession(db, schema: schema, sessionID: id)
            }
        }
    }

    // MARK: - Malformed JSON

    func test_non_object_v2_content_items_are_skipped() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_odd", in: .v2, version: "2.0.0", createdMs: t, updatedMs: t)
        try fixture.addSessionMessage("msg_u", session: "ses_odd", type: "user", seq: 1,
                                      data: ["text": "prompt"], createdMs: t + 1)
        try fixture.addRawSessionMessage("msg_a1", session: "ses_odd", type: "assistant", seq: 2,
                                         rawData: #"{"content":["hi",3,null,[1],{"type":"text","text":"kept"}]}"#,
                                         createdMs: t + 2)
        try fixture.addRawSessionMessage("msg_a2", session: "ses_odd", type: "assistant", seq: 3,
                                         rawData: #"{"content":{"type":"text","text":"object content"}}"#, createdMs: t + 3)
        try fixture.addRawSessionMessage("msg_a3", session: "ses_odd", type: "assistant", seq: 4,
                                         rawData: #"{"content":"string content"}"#, createdMs: t + 4)
        try fixture.addRawSessionMessage("msg_a4", session: "ses_odd", type: "assistant", seq: 5,
                                         rawData: "not json", createdMs: t + 5)
        try fixture.addSessionMessage("msg_a5", session: "ses_odd", type: "assistant", seq: 6,
                                      data: ["content": [["type": "text", "text": "after"]]], createdMs: t + 6)
        try fixture.addSession("ses_next", in: .v2, version: "2.0.0", createdMs: t - 1, updatedMs: t - 1)

        let (batches, cursor) = try drain(makeSource(fixture))
        XCTAssertNil(batches.last?.problem)
        XCTAssertEqual(texts(batches, "ses_odd"), ["prompt", "kept", "after"])
        XCTAssertNotNil(session(batches, "ses_next"), "the session behind it is still read")
        XCTAssertTrue(batches.allSatisfy { $0.diagnostics.skippedSessions.isEmpty })
        XCTAssertNotNil(state(cursor).watermarks, "the full pass finished")
    }

    func test_malformed_v1_rows_are_skipped() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0
        try fixture.addSession("ses_a", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_1", session: "ses_a", role: "user", createdMs: t + 1)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_a", text: "good part", createdMs: t + 1)
        try fixture.addRawPart("prt_2", message: "msg_1", session: "ses_a", rawData: "{broken", createdMs: t + 2)
        try fixture.addRawPart("prt_3", message: "msg_1", session: "ses_a", rawData: "[1,2]", createdMs: t + 3)

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertNil(batches.last?.problem)
        XCTAssertEqual(texts(batches, "ses_a"), ["good part"])
    }

    // MARK: - One unreadable session

    func test_unreadable_session_does_not_block_full_pass() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0 - Self.day
        // Newest first: ses_c, ses_bad, ses_a. One session per call puts ses_bad alone on a page.
        for (index, id) in ["ses_a", "ses_bad", "ses_c"].enumerated() {
            try fixture.addSession(id, createdMs: t, updatedMs: t + Int64(index))
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: t + Int64(index))
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt \(id)",
                                    createdMs: t + Int64(index))
        }
        let failing = FailingLoader(failing: ["ses_bad"])
        let source = makeSource(fixture, sessionsPerBatch: 1, loadSession: failing.loader)

        let (batches, cursor) = try drain(source)
        XCTAssertTrue(batches.allSatisfy { $0.problem == nil })
        XCTAssertEqual(batches.flatMap(\.sessions).map(\.nativeID), ["ses_c", "ses_a"])
        guard case .unreadable? = batches.compactMap({ $0.diagnostics.skippedSessions["ses_bad"] }).first else {
            return XCTFail("ses_bad should be reported unreadable")
        }
        XCTAssertNil(state(cursor).backfill)
        XCTAssertNotNil(state(cursor).watermarks, "incremental indexing starts")
        XCTAssertEqual(failing.attempts("ses_bad"), 1)

        // Unchanged, it is not retried.
        let idle = try drain(source, cursor: cursor)
        XCTAssertTrue(idle.batches.flatMap(\.sessions).isEmpty)
        XCTAssertEqual(failing.attempts("ses_bad"), 1)
    }

    func test_unreadable_session_does_not_block_pending_queue() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0 - Self.day
        for id in ["ses_a", "ses_bad", "ses_c"] {
            try fixture.addSession(id, createdMs: t, updatedMs: t)
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: t)
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt \(id)", createdMs: t)
        }
        let failing = FailingLoader(failing: [])
        let source = makeSource(fixture, sessionsPerBatch: 1, loadSession: failing.loader)
        let (_, afterPass) = try drain(source)

        // ses_bad sorts before ses_c in the pending queue and now fails.
        failing.setFailing(["ses_bad"])
        for id in ["ses_bad", "ses_c"] {
            try fixture.addTextPart("prt_\(id)_2", message: "msg_\(id)", session: id, text: "more \(id)", createdMs: t + 1)
        }
        let (batches, cursor) = try drain(source, cursor: afterPass)
        XCTAssertTrue(batches.allSatisfy { $0.problem == nil })
        XCTAssertEqual(batches.flatMap(\.sessions).map(\.nativeID), ["ses_c"])
        XCTAssertEqual(texts(batches, "ses_c"), ["prompt ses_c\n\nmore ses_c"])
        XCTAssertTrue(state(cursor).pending.isEmpty)
        XCTAssertEqual(failing.attempts("ses_bad"), 2)

        // Once it changes again and reads, it is indexed.
        failing.setFailing([])
        try fixture.addTextPart("prt_ses_bad_3", message: "msg_ses_bad", session: "ses_bad", text: "fixed", createdMs: t + 2)
        let (later, _) = try drain(source, cursor: cursor)
        XCTAssertEqual(texts(later, "ses_bad"), ["prompt ses_bad\n\nmore ses_bad\n\nfixed"])
    }

    func test_session_local_error_kinds() {
        func error(_ kind: AgentHistoryDatabaseError.Kind) -> AgentHistoryDatabaseError {
            AgentHistoryDatabaseError(kind: kind, code: 1, extendedCode: 1, message: "")
        }
        XCTAssertTrue(OpenCodeHistorySource.isSessionLocal(error(.other)))
        XCTAssertTrue(OpenCodeHistorySource.isSessionLocal(error(.corrupt)))
        XCTAssertFalse(OpenCodeHistorySource.isSessionLocal(error(.busy)))
        XCTAssertFalse(OpenCodeHistorySource.isSessionLocal(error(.interrupted)))
        XCTAssertFalse(OpenCodeHistorySource.isSessionLocal(error(.cantOpen)))
        XCTAssertFalse(OpenCodeHistorySource.isSessionLocal(error(.notADatabase)))
    }
}
