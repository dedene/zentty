import Foundation
import XCTest
@testable import Zentty

/// Excluded and removed opencode sessions come back when the rules relax.
final class OpenCodeHistorySourceAdmissionTests: OpenCodeHistorySourceTestCase {
    /// Counts reads per session and how many messages each read decoded.
    private final class RecordingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [String: [Int]] = [:]

        func reads(_ id: String) -> [Int] {
            lock.withLock { reads[id] ?? [] }
        }

        var loader: OpenCodeHistorySource.SessionLoader {
            { [self] db, schema, id, admits in
                let content = try OpenCodeHistoryQueries.loadSession(db, schema: schema, sessionID: id, admits: admits)
                lock.withLock { reads[id, default: []].append(content.map { $0.v1Messages.count + $0.v2Messages.count } ?? -1) }
                return content
            }
        }
    }

    private let secretFolder = "/work/secret"

    private func excluding(_ folders: [String]) -> AgentHistoryIngestContext {
        AgentHistoryFixtures.context(admission: AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: folders), tombstones: []
        ))
    }

    private func tombstoning(_ ids: [String]) -> AgentHistoryIngestContext {
        AgentHistoryFixtures.context(admission: AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            tombstones: Set(ids.map { AgentHistorySessionKey(agent: .opencode, nativeID: $0) })
        ))
    }

    private func makeFixture() throws -> OpenCodeHistoryFixture {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0 - Self.day
        for (id, directory) in [("ses_secret", "/work/secret/app"), ("ses_kept", "/work/project")] {
            try fixture.addSession(id, directory: directory, createdMs: t, updatedMs: t)
            try fixture.addMessage("msg_\(id)", session: id, role: "user", createdMs: t)
            try fixture.addTextPart("prt_\(id)", message: "msg_\(id)", session: id, text: "prompt \(id)", createdMs: t)
        }
        return fixture
    }

    func test_removing_exclusion_reingests() throws {
        let fixture = try makeFixture()
        let recording = RecordingLoader()
        let source = makeSource(fixture, loadSession: recording.loader)

        let excluded = try drain(source, context: excluding([secretFolder]))
        XCTAssertEqual(excluded.batches.flatMap(\.sessions).map(\.nativeID), ["ses_kept"])
        XCTAssertEqual(excluded.batches.last?.rejected, ["ses_secret": .excludedFolder])
        XCTAssertEqual(recording.reads("ses_secret"), [0], "no message of an excluded session is decoded")
        XCTAssertNotNil(state(excluded.cursor).rejected["ses_secret"])
        XCTAssertNil(state(excluded.cursor).lastChange["ses_secret"])

        // Same rules: nothing is read again.
        let same = try drain(source, cursor: excluded.cursor, context: excluding([secretFolder]))
        XCTAssertTrue(same.batches.flatMap(\.sessions).isEmpty)
        XCTAssertEqual(recording.reads("ses_secret").count, 1)

        // The exclusion is lifted.
        let lifted = try drain(source, cursor: same.cursor, context: excluding([]))
        XCTAssertEqual(lifted.batches.flatMap(\.sessions).map(\.nativeID), ["ses_secret"])
        XCTAssertEqual(texts(lifted.batches, "ses_secret"), ["prompt ses_secret"])
        XCTAssertTrue(state(lifted.cursor).rejected.isEmpty)
        XCTAssertNotNil(state(lifted.cursor).lastChange["ses_secret"])
    }

    func test_restore_all_reingests() throws {
        let fixture = try makeFixture()
        let source = makeSource(fixture)
        let (_, afterPass) = try drain(source)

        // The session is removed from Agent History (the indexer deletes its rows).
        let removed = try drain(source, cursor: afterPass, context: tombstoning(["ses_kept"]))
        XCTAssertEqual(removed.batches.flatMap(\.removedNativeIDs), ["ses_kept"])
        XCTAssertEqual(removed.batches.last?.rejected, ["ses_kept": .tombstoned])
        XCTAssertNotNil(state(removed.cursor).rejected["ses_kept"])

        // Restore all.
        let restored = try drain(source, cursor: removed.cursor, context: tombstoning([]))
        XCTAssertEqual(restored.batches.flatMap(\.sessions).map(\.nativeID), ["ses_kept"])
        XCTAssertEqual(texts(restored.batches, "ses_kept"), ["prompt ses_kept"])
    }

    func test_adding_then_removing_exclusion_round_trips() throws {
        let fixture = try makeFixture()
        let source = makeSource(fixture)
        let (_, afterPass) = try drain(source, context: excluding([]))

        let added = try drain(source, cursor: afterPass, context: excluding([secretFolder]))
        XCTAssertTrue(added.batches.flatMap(\.sessions).isEmpty)
        XCTAssertEqual(added.batches.flatMap(\.removedNativeIDs), ["ses_secret"])
        XCTAssertNotNil(state(added.cursor).rejected["ses_secret"])
        XCTAssertNotNil(state(added.cursor).lastChange["ses_kept"], "an unaffected session stays admitted")

        let removed = try drain(source, cursor: added.cursor, context: excluding([]))
        XCTAssertEqual(removed.batches.flatMap(\.sessions).map(\.nativeID), ["ses_secret"])
    }

    func test_rejected_session_change_is_rechecked_cheaply() throws {
        let fixture = try makeFixture()
        let recording = RecordingLoader()
        let source = makeSource(fixture, loadSession: recording.loader)
        let (_, afterPass) = try drain(source, context: excluding([secretFolder]))

        try fixture.addTextPart("prt_more", message: "msg_ses_secret", session: "ses_secret", text: "more",
                                createdMs: Self.t0)
        let (batches, cursor) = try drain(source, cursor: afterPass, context: excluding([secretFolder]))
        XCTAssertTrue(batches.flatMap(\.sessions).isEmpty)
        XCTAssertEqual(recording.reads("ses_secret"), [0, 0])
        XCTAssertEqual(state(cursor).rejected["ses_secret"], Self.t0)
    }

    func test_admission_signature_is_stable_and_order_free() {
        let a = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/a", "/b"]),
            tombstones: [AgentHistorySessionKey(agent: .opencode, nativeID: "ses_x"),
                         AgentHistorySessionKey(agent: .claude, nativeID: "other")]
        )
        let b = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/b", "/a"]),
            tombstones: [AgentHistorySessionKey(agent: .opencode, nativeID: "ses_x")]
        )
        XCTAssertEqual(OpenCodeHistorySource.admissionSignature(a), OpenCodeHistorySource.admissionSignature(b),
                       "folder order and other agents' tombstones do not matter")
        XCTAssertNotEqual(OpenCodeHistorySource.admissionSignature(a), OpenCodeHistorySource.admissionSignature(.admitAll))
    }
}
