import Foundation
import XCTest
@testable import Zentty

/// Removed sessions stay removed when the index file is lost outside a running indexer: a
/// cold-start quarantine of an unusable index, and a Rebuild cut off between deleting the old
/// file and writing its removals into the new one.
final class AgentHistoryIndexerRemovalLedgerTests: XCTestCase {
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

    /// Indexes s1 and s2, removes s2, stops.
    private func indexAndRemoveS2(_ harness: AgentHistoryIndexerHarness) throws {
        harness.source.setUnits([.single("s1", mtimeNs: 2), .single("s2", mtimeNs: 1)])
        let first = harness.makeIndexer()
        first.start()
        first.drainSynchronouslyForTesting()
        remove("s2", from: first)
        XCTAssertEqual(try nativeIDs(harness), ["s1"])
        first.stop(timeout: 5)
    }

    private func startAgain(_ harness: AgentHistoryIndexerHarness) -> AgentHistoryIndexer {
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        return indexer
    }

    private func assertS2StaysRemoved(_ harness: AgentHistoryIndexerHarness, _ indexer: AgentHistoryIndexer,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(indexer.currentStatus.state, .watching, file: file, line: line)
        XCTAssertEqual(try nativeIDs(harness), ["s1"], "the removed session is not read again", file: file, line: line)
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["s1"], file: file, line: line)
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 1, file: file, line: line)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones WHERE native_id = 's2'"), 1,
                       file: file, line: line)
    }

    func test_cold_start_quarantine_keeps_removed_sessions_removed() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try indexAndRemoveS2(harness)
        // Not a SQLite header any more: the next open moves the file aside and starts empty.
        let handle = try FileHandle(forWritingTo: harness.index.paths.databaseURL)
        try handle.write(contentsOf: Data("not an index....".utf8))
        try handle.close()

        let indexer = startAgain(harness)

        let names = try FileManager.default.contentsOfDirectory(atPath: harness.index.paths.directoryURL.path)
        XCTAssertEqual(names.filter(AgentHistoryPaths.isCorruptCopyName).count, 1, "the unusable index was moved aside")
        try assertS2StaysRemoved(harness, indexer)
    }

    func test_rebuild_cut_off_after_the_index_files_went_keeps_removed_sessions_removed() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try indexAndRemoveS2(harness)
        // What Rebuild has done when the app dies before the new index holds the removals.
        try harness.index.storage.removeIndexFiles()

        let indexer = startAgain(harness)

        try assertS2StaysRemoved(harness, indexer)
    }

    func test_removals_list_is_private_and_lists_the_removed_session() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try indexAndRemoveS2(harness)

        let url = harness.index.paths.removalsURL
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try AgentHistoryRemovalLedger(fileURL: url).tombstones().map(\.key),
                       [AgentHistorySessionKey(agent: .claude, nativeID: "s2")])
    }

    func test_an_unreadable_removals_list_fails_closed() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", mtimeNs: 2), .single("s2", mtimeNs: 1)])
        try FileManager.default.createDirectory(at: harness.index.paths.directoryURL, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: harness.index.paths.removalsURL)

        let failed = harness.recorder.expectStatus(self, "failed") { $0.state == .failed(.removalsUnreadable) }
        let indexer = harness.makeIndexer()
        indexer.start()
        wait(for: [failed], timeout: 5)

        XCTAssertTrue(harness.source.ingestedKeys.isEmpty, "nothing is read while the removals are unknown")
        XCTAssertTrue(indexer.currentSnapshot.sessions.isEmpty)

        indexer.rebuild()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentStatus.state, .failed(.removalsUnreadable), "Rebuild can't overwrite the list")
        XCTAssertTrue(harness.source.ingestedKeys.isEmpty)
        XCTAssertEqual(try Data(contentsOf: harness.index.paths.removalsURL), Data("{ not json".utf8))
    }

    func test_restore_all_clears_the_removals_list() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", mtimeNs: 2), .single("s2", mtimeNs: 1)])
        let first = harness.makeIndexer()
        first.start()
        first.drainSynchronouslyForTesting()
        remove("s2", from: first)
        first.restoreAllRemovedSessions()
        first.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.index.paths.removalsURL.path))
        first.stop(timeout: 5)
        try harness.index.storage.removeIndexFiles()

        let indexer = startAgain(harness)

        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"], "a restored session isn't removed again")
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 0)
    }

    func test_removals_only_the_index_holds_are_added_to_the_list_at_start() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try indexAndRemoveS2(harness)
        // An index written before the list existed.
        try FileManager.default.removeItem(at: harness.index.paths.removalsURL)

        let second = startAgain(harness)
        XCTAssertEqual(try AgentHistoryRemovalLedger(fileURL: harness.index.paths.removalsURL).tombstones().map(\.key),
                       [AgentHistorySessionKey(agent: .claude, nativeID: "s2")])
        second.stop(timeout: 5)
        try harness.index.storage.removeIndexFiles()

        let indexer = startAgain(harness)

        try assertS2StaysRemoved(harness, indexer)
    }

    func test_the_list_keeps_entries_of_unknown_agents_and_first_removal_times() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let ledger = AgentHistoryRemovalLedger(fileURL: harness.index.paths.removalsURL)
        try AgentHistoryPrivateFile.write(Data("""
            {"version": 1, "removed": [{"agent": "future-agent", "nativeID": "x", "removedAt": 5},
                                       {"agent": "claude", "nativeID": "a", "removedAt": 10}]}
            """.utf8), to: ledger.fileURL)

        try ledger.record([.init(key: AgentHistorySessionKey(agent: .claude, nativeID: "a"), removedAtMs: 99),
                           .init(key: AgentHistorySessionKey(agent: .codex, nativeID: "b"), removedAtMs: 20)])

        XCTAssertEqual(try ledger.entries(), [
            .init(agent: "claude", nativeID: "a", removedAt: 10),
            .init(agent: "codex", nativeID: "b", removedAt: 20),
            .init(agent: "future-agent", nativeID: "x", removedAt: 5),
        ])
        XCTAssertEqual(try ledger.tombstones().map(\.key.nativeID), ["a", "b"])
    }
}
