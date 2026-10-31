import Foundation
import XCTest
@testable import Zentty

/// Exclusions, tombstones, opens, rebuild and source purge routed through the indexer (I8).
final class AgentHistoryIndexerPolicyTests: XCTestCase {
    private static let secretFolder = "/work/secret"

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentHistoryCursor?] = []
        var values: [AgentHistoryCursor?] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ cursor: AgentHistoryCursor?) { lock.lock(); stored.append(cursor); lock.unlock() }
        func reset() { lock.lock(); stored = []; lock.unlock() }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func configuration(excluding folders: [String]) -> AgentHistoryIndexerConfiguration {
        AgentHistoryIndexerConfiguration(enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: folders)
    }

    private func nativeIDs(_ harness: AgentHistoryIndexerHarness) throws -> [String] {
        try harness.read { db in try db.query("SELECT native_id FROM sessions ORDER BY native_id") { $0.string(0) } }
    }

    private func messages(_ harness: AgentHistoryIndexerHarness, of nativeID: String) throws -> [String] {
        try harness.read { db in
            try db.query(
                "SELECT m.text FROM messages m JOIN sessions s ON s.id = m.session_id WHERE s.native_id = ? ORDER BY m.seq",
                [.text(nativeID)]
            ) { $0.string(0) }
        }
    }

    private func isRejected(_ harness: AgentHistoryIndexerHarness, unitKey: String) throws -> Bool? {
        try harness.read { db in
            try db.scalarInt64("SELECT rejected FROM cursors WHERE unit_key = ?", [.text(unitKey)])
        }.map { $0 != 0 }
    }

    private func snapshotIDs(_ indexer: AgentHistoryIndexer) -> Set<String> {
        Set(indexer.currentSnapshot.sessions.map(\.nativeID))
    }

    private func remove(_ key: AgentHistorySessionKey, from indexer: AgentHistoryIndexer) -> Bool {
        let done = expectation(description: "removed")
        let removed = Flag()
        indexer.removeSession(key) { ok in
            removed.value = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        indexer.drainSynchronouslyForTesting()
        return removed.value
    }

    private func reconcile(_ indexer: AgentHistoryIndexer) {
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
    }

    // MARK: - Exclusions

    func test_excluded_folder_stores_zero_rows_and_marks_unit_rejected() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([
            .single("inside", messages: ["secret plan", "ok"], cwd: Self.secretFolder + "/app"),
            .single("outside", cwd: "/work/project"),
        ])
        let indexer = harness.makeIndexer(excludedFolders: [Self.secretFolder])

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["outside"])
        XCTAssertEqual(try messages(harness, of: "inside"), [])
        XCTAssertEqual(try isRejected(harness, unitKey: "inside"), true)
        XCTAssertEqual(try isRejected(harness, unitKey: "outside"), false)
        XCTAssertEqual(snapshotIDs(indexer), ["outside"])

        let ingestedBefore = harness.source.ingestedKeys.count
        reconcile(indexer)
        XCTAssertEqual(harness.source.ingestedKeys.count, ingestedBefore, "a rejected unit is not read again")
    }

    func test_adding_exclusion_purges_existing_sessions_immediately() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([
            .single("inside", cwd: Self.secretFolder + "/app"),
            .single("outside", cwd: "/work/project"),
        ])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["inside", "outside"])
        let ingestedBefore = harness.source.ingestedKeys.count

        indexer.update(configuration: configuration(excluding: [Self.secretFolder]))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["outside"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 2)
        XCTAssertEqual(try isRejected(harness, unitKey: "inside"), true)
        XCTAssertEqual(snapshotIDs(indexer), ["outside"])
        XCTAssertEqual(harness.source.ingestedKeys.count, ingestedBefore, "the purge needs no re-read")
    }

    func test_removing_exclusion_reingests() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let messages = ["first", "second", "third", "fourth", "fifth"]
        harness.source.setUnits([
            .single("inside", messages: messages, cwd: Self.secretFolder + "/app"),
            .single("outside", cwd: "/work/project"),
        ])
        let indexer = harness.makeIndexer(messageLimit: 2)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try self.messages(harness, of: "inside"), messages)

        indexer.update(configuration: configuration(excluding: [Self.secretFolder]))
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["outside"])

        indexer.update(configuration: configuration(excluding: []))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["inside", "outside"])
        XCTAssertEqual(try self.messages(harness, of: "inside"), messages, "re-read from byte 0, nothing lost")
        XCTAssertEqual(try isRejected(harness, unitKey: "inside"), false)
        XCTAssertEqual(snapshotIDs(indexer), ["inside", "outside"])
    }

    func test_exclusion_lifted_while_indexer_was_off_reingests_on_next_start() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("inside", messages: ["x", "y"], cwd: Self.secretFolder + "/app")])
        let first = harness.makeIndexer(excludedFolders: [Self.secretFolder])
        first.start()
        first.drainSynchronouslyForTesting()
        XCTAssertEqual(try isRejected(harness, unitKey: "inside"), true)
        first.stop(timeout: 2)

        let second = harness.makeIndexer()
        second.start()
        second.drainSynchronouslyForTesting()

        XCTAssertEqual(try messages(harness, of: "inside"), ["x", "y"])
        XCTAssertEqual(snapshotIDs(second), ["inside"])
    }

    func test_lifting_one_exclusion_keeps_others_in_force() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([
            .single("a", cwd: "/work/a"),
            .single("b", cwd: "/work/b"),
        ])
        let indexer = harness.makeIndexer(excludedFolders: ["/work/a", "/work/b"])
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), [])

        indexer.update(configuration: configuration(excluding: ["/work/b"]))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["a"])
        XCTAssertEqual(try isRejected(harness, unitKey: "b"), true)
    }

    func test_database_unit_restarts_from_scratch_when_rules_relax_before_a_clean_read() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: [
            FakeHistorySession(nativeID: "ses_in", title: "In", cwd: Self.secretFolder + "/app", messages: ["a", "b"]),
            FakeHistorySession(nativeID: "ses_out", title: "Out", cwd: "/work/project", messages: ["c", "d"]),
        ])])
        let failing = Flag()
        let cursors = Recorder()
        harness.source.setIngestHook { _, cursor, _ in
            cursors.append(cursor)
            if failing.value {
                throw POSIXError(.EBUSY)
            }
        }
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        // Tighten, and the immediate poll fails: the adapter never saw the stricter rules.
        failing.value = true
        indexer.update(configuration: configuration(excluding: [Self.secretFolder]))
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["ses_out"])

        failing.value = false
        cursors.reset()
        indexer.update(configuration: configuration(excluding: []))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(cursors.values.first.map { $0 == nil }, true, "read again from the start")
        XCTAssertEqual(try nativeIDs(harness), ["ses_in", "ses_out"])

        // A clean poll after tightening keeps the cursor on the next relax.
        indexer.update(configuration: configuration(excluding: [Self.secretFolder]))
        indexer.drainSynchronouslyForTesting()
        cursors.reset()
        indexer.update(configuration: configuration(excluding: []))
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(cursors.values.first.map { $0 != nil }, true)
        XCTAssertEqual(try nativeIDs(harness), ["ses_in", "ses_out"])
    }

    // MARK: - Tombstones

    func test_tombstone_removes_and_blocks_reingest() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b"]), .single("s2")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertTrue(remove(AgentHistorySessionKey(agent: .claude, nativeID: "s1"), from: indexer))

        XCTAssertEqual(try nativeIDs(harness), ["s2"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones WHERE native_id = 's1'"), 1)
        XCTAssertEqual(try isRejected(harness, unitKey: "s1"), true)
        XCTAssertEqual(snapshotIDs(indexer), ["s2"])
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 1)

        // The agent keeps writing to the same file: still skipped.
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c", "d"], mtimeNs: 9)])
        reconcile(indexer)
        XCTAssertEqual(try nativeIDs(harness), ["s2"])

        // A replaced file is read again but the tombstone still rejects it.
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c", "d"], mtimeNs: 10, ino: 7)])
        reconcile(indexer)
        XCTAssertEqual(try nativeIDs(harness), ["s2"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages WHERE session_id NOT IN (SELECT id FROM sessions)"), 0)
        XCTAssertEqual(snapshotIDs(indexer), ["s2"])
    }

    func test_restore_all_reingests() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let messages = ["one", "two", "three"]
        harness.source.setUnits([.single("s1", messages: messages), .single("s2")])
        let indexer = harness.makeIndexer(messageLimit: 2)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertTrue(remove(AgentHistorySessionKey(agent: .claude, nativeID: "s1"), from: indexer))
        XCTAssertEqual(try nativeIDs(harness), ["s2"])

        indexer.restoreAllRemovedSessions()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"])
        XCTAssertEqual(try self.messages(harness, of: "s1"), messages)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones"), 0)
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 0)
        XCTAssertEqual(snapshotIDs(indexer), ["s1", "s2"])
    }

    func test_removing_database_session_never_rejects_the_shared_unit() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let database = FakeHistoryUnit(key: "db", kind: .database, sessions: [
            FakeHistorySession(nativeID: "ses_one", title: "One", cwd: "/work/project", messages: ["a", "b"]),
            FakeHistorySession(nativeID: "ses_two", title: "Two", cwd: "/work/project", messages: ["c", "d"]),
        ])
        harness.source.setUnits([database])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["ses_one", "ses_two"])

        XCTAssertTrue(remove(AgentHistorySessionKey(agent: .claude, nativeID: "ses_one"), from: indexer))
        XCTAssertEqual(try nativeIDs(harness), ["ses_two"])
        XCTAssertEqual(try isRejected(harness, unitKey: "db"), false)

        reconcile(indexer)
        XCTAssertEqual(try nativeIDs(harness), ["ses_two"], "the tombstone keeps the session out on later polls")

        indexer.restoreAllRemovedSessions()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["ses_one", "ses_two"])
    }

    // MARK: - Opens

    func test_record_open_updates_store_and_snapshot() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let rowID = try XCTUnwrap(try harness.sessionRowID("s1"))

        indexer.recordOpen(sessionRowID: rowID, atMs: 1_793_000_500_000)
        indexer.recordOpen(sessionRowID: rowID, atMs: 1_793_000_400_000)
        indexer.recordOpen(sessionRowID: 999_999, atMs: 1_793_000_600_000)
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE id = ?", [.integer(rowID)]), 2)
        XCTAssertEqual(
            try harness.read { try $0.scalarInt64("SELECT last_opened_at FROM sessions WHERE id = ?", [.integer(rowID)]) },
            1_793_000_500_000
        )
        let summary = try XCTUnwrap(indexer.currentSnapshot.sessions.first { $0.id == rowID })
        XCTAssertEqual(summary.opens, 2)
        XCTAssertEqual(summary.lastOpenedAtMs, 1_793_000_500_000)
    }

    // MARK: - Rebuild

    func test_rebuild_keeps_tombstones_and_usage() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1"), .single("s2"), .single("s3")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        try harness.setOpens(3, nativeID: "s2")
        XCTAssertTrue(remove(AgentHistorySessionKey(agent: .claude, nativeID: "s3"), from: indexer))
        let marker = try AgentHistoryDatabase(url: harness.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try marker.run("INSERT INTO meta (key, value) VALUES ('rebuild_marker', '1')")
        marker.close()

        indexer.rebuild()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM meta WHERE key = 'rebuild_marker'"), 0, "a fresh index file")
        XCTAssertEqual(try nativeIDs(harness), ["s1", "s2"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM tombstones WHERE agent = 'claude' AND native_id = 's3'"), 1)
        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE native_id = 's2'"), 3)
        XCTAssertEqual(
            try harness.read { try $0.scalarInt64("SELECT last_opened_at FROM sessions WHERE native_id = 's2'") },
            1_793_000_000_000
        )
        XCTAssertEqual(try harness.count("SELECT count(*) FROM usage_carryover"), 0, "carry-over moved onto the new rows")
        XCTAssertEqual(snapshotIDs(indexer), ["s1", "s2"])
        XCTAssertEqual(indexer.currentStatus.removedSessionCount, 1)
        XCTAssertEqual(indexer.currentStatus.state, .watching)
    }

    func test_rebuild_recovers_an_index_with_a_newer_schema() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try harness.index.openWriter()
        harness.index.closeWriter()
        let bump = try AgentHistoryDatabase(url: harness.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try bump.setUserVersion(AgentHistorySchema.currentVersion + 1)
        bump.close()
        harness.source.setUnits([.single("s1")])
        let failed = harness.recorder.expectStatus(self, "failed") {
            if case .failed = $0.state { return true }
            return false
        }
        let indexer = harness.makeIndexer()
        indexer.start()
        wait(for: [failed], timeout: 5)

        indexer.rebuild()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(indexer.currentStatus.state, .watching)
        XCTAssertEqual(try nativeIDs(harness), ["s1"])
    }

    // MARK: - Source purge

    func test_disabling_source_purges_rows_and_snapshot() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1"), .single("claude-2")])
        let codex = FakeHistorySource(agent: .codex, rootPath: harness.makeRoot("codex").path)
        codex.setUnits([.single("codex-1")])
        let indexer = harness.makeIndexer(extraSources: [codex])
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "claude-2", "codex-1"])

        indexer.purgeSource(agent: .claude)
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["codex-1"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 2)
        XCTAssertEqual(try harness.count(
            "SELECT count(*) FROM cursors c JOIN sources s ON s.id = c.source_id WHERE s.agent = 'claude'"
        ), 0)
        XCTAssertEqual(try harness.count("SELECT enabled FROM sources WHERE agent = 'claude'"), 0)
        XCTAssertEqual(snapshotIDs(indexer), ["codex-1"])
        XCTAssertFalse(indexer.currentStatus.enabledAgents.contains(.claude))
        XCTAssertFalse(indexer.currentStatus.sources.contains { $0.agent == .claude })

        let ingestedBefore = harness.source.ingestedKeys.count
        reconcile(indexer)
        XCTAssertEqual(harness.source.ingestedKeys.count, ingestedBefore, "a purged source is not read again")
        XCTAssertEqual(try nativeIDs(harness), ["codex-1"])
    }
}
