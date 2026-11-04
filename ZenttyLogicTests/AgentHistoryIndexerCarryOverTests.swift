import Foundation
import XCTest
@testable import Zentty

/// Tombstones and usage survive every way the index file is replaced: a mid-run corruption
/// recovery, a Rebuild out of a failed index, and a carry-over restore that fails.
final class AgentHistoryIndexerCarryOverTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static func databaseError(_ kind: AgentHistoryDatabaseError.Kind, _ code: Int32) -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: kind, code: code, extendedCode: code, message: "injected")
    }

    private func nativeIDs(_ harness: AgentHistoryIndexerHarness) throws -> [String] {
        try harness.read { db in try db.query("SELECT native_id FROM sessions ORDER BY native_id") { $0.string(0) } }
    }

    private func remove(_ nativeID: String, from indexer: AgentHistoryIndexer) {
        let done = expectation(description: "removed \(nativeID)")
        indexer.removeSession(AgentHistorySessionKey(agent: .claude, nativeID: nativeID)) { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        indexer.drainSynchronouslyForTesting()
    }

    private func open(_ nativeID: String, times: Int, in indexer: AgentHistoryIndexer, harness: AgentHistoryIndexerHarness) throws {
        let rowID = try XCTUnwrap(try harness.sessionRowID(nativeID))
        for index in 0..<times {
            indexer.recordOpen(sessionRowID: rowID, atMs: 1_793_000_100_000 + Int64(index))
        }
        indexer.drainSynchronouslyForTesting()
    }

    private func indexThreeSessions(_ harness: AgentHistoryIndexerHarness, _ indexer: AgentHistoryIndexer) throws {
        harness.source.setUnits([.single("s1", mtimeNs: 3), .single("s2", mtimeNs: 2), .single("s3", mtimeNs: 1)])
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        remove("s3", from: indexer)
        try open("s2", times: 2, in: indexer, harness: harness)
        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"])
    }

    private func assertCarriedOver(_ harness: AgentHistoryIndexerHarness, _ indexer: AgentHistoryIndexer,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"], "the removed session stays removed", file: file, line: line)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones WHERE native_id = 's3'"), 1, file: file, line: line)
        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE native_id = 's2'"), 2, file: file, line: line)
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["s1", "s2"], file: file, line: line)
        XCTAssertEqual(indexer.currentSnapshot.sessions.first { $0.nativeID == "s2" }?.opens, 2, file: file, line: line)
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 1, file: file, line: line)
    }

    func test_corruption_mid_run_keeps_tombstones_and_usage() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let indexer = harness.makeIndexer()
        let corruptOnce = Flag(false)
        let corrupt = Self.databaseError(.corrupt, 11)
        indexer.beforeCursorSaveForTesting = { _ in
            if corruptOnce.value {
                corruptOnce.value = false
                throw corrupt
            }
        }
        try indexThreeSessions(harness, indexer)

        corruptOnce.value = true
        harness.source.setUnits([.single("s1", messages: ["hello", "hi there", "more"], mtimeNs: 4)])
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
        indexer.drainSynchronouslyForTesting()

        let names = try FileManager.default.contentsOfDirectory(atPath: harness.index.paths.directoryURL.path)
        XCTAssertEqual(names.filter(AgentHistoryPaths.isCorruptCopyName).count, 1, "the corrupt index was moved aside")
        XCTAssertEqual(indexer.currentStatus.state, .watching)
        try assertCarriedOver(harness, indexer)
    }

    func test_rebuild_from_a_failed_newer_schema_index_keeps_tombstones_and_usage() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let first = harness.makeIndexer()
        try indexThreeSessions(harness, first)
        first.stop(timeout: 5)
        let bump = try AgentHistoryDatabase(url: harness.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try bump.setUserVersion(AgentHistorySchema.currentVersion + 1)
        bump.close()

        let failed = harness.recorder.expectStatus(self, "failed") {
            if case .failed(.newerSchema) = $0.state { return true }
            return false
        }
        let indexer = harness.makeIndexer()
        indexer.start()
        wait(for: [failed], timeout: 5)

        indexer.rebuild()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(indexer.currentStatus.state, .watching)
        try assertCarriedOver(harness, indexer)
    }

    func test_failed_carry_over_restore_keeps_tombstones_in_force_and_is_retried() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let indexer = harness.makeIndexer()
        let restoreFails = Flag(false)
        let busy = Self.databaseError(.busy, 5)
        indexer.beforeCarryOverRestoreForTesting = {
            if restoreFails.value {
                throw busy
            }
        }
        try indexThreeSessions(harness, indexer)

        restoreFails.value = true
        indexer.rebuild()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"], "the unwritten tombstone still holds the session back")
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones"), 0)
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 1)

        restoreFails.value = false
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        try assertCarriedOver(harness, indexer)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM usage_carryover"), 0, "usage moved onto the stored session")
    }

    func test_merge_keeps_first_removal_time_and_largest_usage() {
        let key = AgentHistorySessionKey(agent: .claude, nativeID: "a")
        var carryOver = AgentHistoryRebuildCarryOver(
            tombstones: [.init(key: key, removedAtMs: 10)],
            usage: [.init(key: key, opens: 3, lastOpenedAtMs: nil)]
        )
        carryOver.merge(AgentHistoryRebuildCarryOver(
            tombstones: [.init(key: key, removedAtMs: 99)],
            usage: [.init(key: key, opens: 1, lastOpenedAtMs: 7)]
        ))
        XCTAssertEqual(carryOver.tombstones.map(\.removedAtMs), [10])
        XCTAssertEqual(carryOver.usage.map(\.opens), [3])
        XCTAssertEqual(carryOver.usage.map(\.lastOpenedAtMs), [7])
    }
}
