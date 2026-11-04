import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryIndexerReconcileTests: XCTestCase {
    private struct InjectedFailure: Error {}

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func reconcile(_ indexer: AgentHistoryIndexer) {
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
    }

    private func sessionCount(_ harness: AgentHistoryIndexerHarness) throws -> Int {
        try harness.count("SELECT count(*) FROM sessions")
    }

    // MARK: - Missing units

    func test_missing_unit_deleted_only_after_30s_grace() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("keep", mtimeNs: 2), .single("gone", mtimeNs: 1)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 2)

        harness.source.removeUnit("gone")
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 2, "a unit first seen missing is kept")

        harness.clock.advance(by: 29)
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 2, "still inside the grace period")
        XCTAssertEqual(indexer.currentSnapshot.sessions.count, 2)

        harness.clock.advance(by: 1)
        reconcile(indexer)
        XCTAssertEqual(try harness.read { db in try db.query("SELECT native_id FROM sessions") { $0.string(0) } }, ["keep"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM cursors WHERE unit_key = 'gone'"), 0)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 2)
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["keep"])
        XCTAssertEqual(indexer.currentStatus.indexedSessions, 1)
    }

    func test_unit_back_within_grace_is_never_deleted() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let unit = FakeHistoryUnit.single("flaky")
        harness.source.setUnits([unit])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        harness.source.removeUnit("flaky")
        reconcile(indexer)
        harness.clock.advance(by: 10)
        harness.source.setUnits([unit])
        reconcile(indexer)
        harness.source.removeUnit("flaky")
        harness.clock.advance(by: 25)
        reconcile(indexer)

        XCTAssertEqual(try sessionCount(harness), 1, "the grace period restarts once the unit came back")
    }

    func test_renamed_unit_repoints_session_and_keeps_opens() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let session = FakeHistorySession(nativeID: "s1", title: "Renamed", cwd: "/work/project", messages: ["hello", "hi"])
        harness.source.setUnits([FakeHistoryUnit(key: "old-path", ino: 1, sessions: [session])])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let rowID = try XCTUnwrap(try harness.sessionRowID("s1"))
        try harness.setOpens(3, nativeID: "s1")

        harness.source.removeUnit("old-path")
        harness.source.setUnits([FakeHistoryUnit(key: "new-path", ino: 2, mtimeNs: 5, sessions: [session])])
        reconcile(indexer)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE unit_key = 'new-path'"), 1,
                       "the upsert re-points the session to the new unit")

        harness.clock.advance(by: 31)
        reconcile(indexer)

        XCTAssertEqual(try harness.sessionRowID("s1"), rowID)
        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE native_id = 's1'"), 3)
        XCTAssertEqual(try harness.read { db in try db.query("SELECT unit_key FROM cursors") { $0.string(0) } }, ["new-path"])
        XCTAssertEqual(try harness.messageTexts(), ["hello", "hi"])
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["s1"])
    }

    func test_mass_deletion_deferred_until_second_reconcile() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let keys = (0..<30).map { String(format: "u%02d", $0) }
        harness.source.setUnits(keys.enumerated().map { .single($1, mtimeNs: Int64($0 + 1)) })
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 30)

        for key in keys.dropFirst(5) {
            harness.source.removeUnit(key)
        }
        reconcile(indexer)
        harness.clock.advance(by: 31)
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 30, "25 of 30 units at once is held back")
        XCTAssertEqual(indexer.currentSnapshot.sessions.count, 30)

        // A targeted reconcile does not confirm a deferred mass deletion.
        let sourceID = try XCTUnwrap(indexer.sourceIDsForTesting.first)
        indexer.requestReconcile(sourceID: sourceID)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 30)

        harness.clock.advance(by: 15 * 60)
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 5, "still missing on the next full reconcile")
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), Set(keys.prefix(5)))
    }

    // MARK: - Problems never delete

    func test_discovery_error_never_deletes() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("a"), .single("b", mtimeNs: 2)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        harness.source.removeUnit("a")
        harness.source.removeUnit("b")
        harness.source.setDiscoveryError(InjectedFailure())
        for _ in 0..<3 {
            reconcile(indexer)
            harness.clock.advance(by: 20 * 60)
        }
        reconcile(indexer)

        XCTAssertEqual(try sessionCount(harness), 2)
        XCTAssertEqual(indexer.currentSnapshot.sessions.count, 2)
        XCTAssertEqual(indexer.currentStatus.sources.first?.problem, .discoveryFailed)
    }

    func test_root_missing_twice_purges_source() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("a"), .single("b", mtimeNs: 2)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        try FileManager.default.removeItem(at: harness.rootURL)
        reconcile(indexer)
        XCTAssertEqual(indexer.currentStatus.sources.first?.problem, .rootMissing)
        XCTAssertEqual(try sessionCount(harness), 2, "a root missing once may be an unmounted volume")

        harness.clock.advance(by: 14 * 60)
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 2, "the second sighting must be 15 minutes after the first")

        // Targeted reconciles never count as the second full reconcile.
        harness.clock.advance(by: 60)
        let sourceID = try XCTUnwrap(indexer.sourceIDsForTesting.first)
        indexer.requestReconcile(sourceID: sourceID)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 2)

        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 0)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM cursors"), 0)
        XCTAssertTrue(indexer.currentSnapshot.sessions.isEmpty)
    }

    func test_root_back_before_second_reconcile_keeps_sessions() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("a")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        try FileManager.default.removeItem(at: harness.rootURL)
        reconcile(indexer)
        harness.clock.advance(by: 5 * 60)
        try FileManager.default.createDirectory(at: harness.rootURL, withIntermediateDirectories: true)
        reconcile(indexer)
        try FileManager.default.removeItem(at: harness.rootURL)
        harness.clock.advance(by: 11 * 60)
        reconcile(indexer)

        XCTAssertEqual(try sessionCount(harness), 1, "the 15 minutes count from the latest disappearance")
    }

    // MARK: - Database sources

    func test_db_source_deletes_vanished_native_ids() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        func database(_ ids: [String]) -> FakeHistoryUnit {
            FakeHistoryUnit(key: "db", kind: .database, sessions: ids.map {
                FakeHistorySession(nativeID: $0, title: "Session \($0)", cwd: "/work/\($0)", messages: ["hello \($0)"])
            })
        }
        harness.source.setUnits([database(["a", "b", "c"])])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 3)

        harness.source.setUnits([database(["a", "c"])])
        harness.source.setExistingNativeIDs(["a", "c"])
        reconcile(indexer)

        XCTAssertEqual(Set(try harness.read { db in try db.query("SELECT native_id FROM sessions") { $0.string(0) } }), ["a", "c"])
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["a", "c"])
        XCTAssertEqual(try harness.count("SELECT rejected FROM cursors WHERE unit_key = 'db'"), 0)
    }

    func test_db_source_mass_deletion_is_deferred_until_next_full_reconcile() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let ids = (0..<30).map { "s\($0)" }
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: ids.map {
            FakeHistorySession(nativeID: $0, title: $0, cwd: "/work", messages: ["hello"])
        })])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        harness.source.setExistingNativeIDs([])
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: [])])
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 30, "every session vanishing at once is deferred")

        harness.clock.advance(by: 15 * 60)
        reconcile(indexer)
        XCTAssertEqual(try sessionCount(harness), 0)
    }

    // MARK: - Exclusions and adapter versions

    func test_reconcile_purges_sessions_under_excluded_folders() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("public", cwd: "/work/open"), .single("private", cwd: "/work/client", mtimeNs: 2)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try sessionCount(harness), 2)

        indexer.update(configuration: AgentHistoryIndexerConfiguration(
            enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: ["/work/client"]
        ))
        reconcile(indexer)
        reconcile(indexer)

        XCTAssertEqual(try harness.read { db in try db.query("SELECT native_id FROM sessions") { $0.string(0) } }, ["public"])
        XCTAssertEqual(try harness.count("SELECT rejected FROM cursors WHERE unit_key = 'private'"), 1)
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["public"])
        XCTAssertEqual(harness.source.ingestedKeys.filter { $0 == "private" }.count, 1, "a rejected unit is not read again")
    }

    func test_adapter_version_bump_replaces_rows_and_updates_version() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["old question", "old answer"])])
        let first = harness.makeIndexer()
        first.start()
        first.drainSynchronouslyForTesting()
        first.stop()
        let rowID = try XCTUnwrap(try harness.sessionRowID("s1"))
        try harness.setOpens(2, nativeID: "s1")

        // Same file identity: only the version bump makes the unit read again.
        let upgraded = FakeHistorySource(rootPath: harness.rootURL.path, adapterVersion: 2)
        upgraded.setUnits([.single("s1", messages: ["new question", "new answer"])])
        let versionDuringIngest = Box<[Int]>([])
        let reader = harness.index.storage.readers
        upgraded.setIngestHook { _, cursor, _ in
            XCTAssertNil(cursor, "the bump cleared the cursor")
            let version = try reader.withReader { try $0.scalarInt64("SELECT adapter_version FROM sources") }
            versionDuringIngest.value.append(Int(version ?? -1))
        }
        let second = harness.makeIndexer(source: upgraded)
        second.start()
        second.drainSynchronouslyForTesting()

        XCTAssertEqual(versionDuringIngest.value, [1], "the version is stored only after the source drained")
        XCTAssertEqual(try harness.count("SELECT adapter_version FROM sources"), 2)
        XCTAssertEqual(try harness.messageTexts(), ["new question", "new answer"])
        XCTAssertEqual(try harness.sessionRowID("s1"), rowID)
        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE native_id = 's1'"), 2)
        second.stop()

        let third = harness.makeIndexer(source: upgraded)
        third.start()
        third.drainSynchronouslyForTesting()
        XCTAssertEqual(upgraded.ingestedKeys, ["s1"], "an unchanged version does not re-read")
    }
}
