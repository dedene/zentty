import Foundation
import XCTest
@testable import Zentty

/// One indexer owns the index at a time (`AgentHistoryWriterLock`); a second instance of the
/// same flavor stands by read-only and takes over when the owner stops.
final class AgentHistoryIndexerOwnershipTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// A second "process": its own storage (own reader pool and lock descriptors) on the same
    /// directory, its own recorder.
    private func makeSecondInstance(
        _ harness: AgentHistoryIndexerHarness,
        recorder: AgentHistoryPublishedRecorder
    ) -> AgentHistoryIndexer {
        let source = harness.source
        let clock = harness.clock
        let indexer = AgentHistoryIndexer(
            storage: AgentHistoryStorage(paths: harness.index.paths),
            stateStore: harness.stateStore,
            makeSources: { [source] },
            configuration: AgentHistoryIndexerConfiguration(
                enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: []
            ),
            systemConditions: FakeSystemConditions(),
            now: { clock.now },
            onStatusChange: { recorder.record($0) },
            onSnapshotChange: { recorder.record($0) }
        )
        indexer.writerLockWait = 0.05
        indexer.standbyRetryInterval = 0.1
        addTeardownBlock { indexer.stop(timeout: 2) }
        return indexer
    }

    private static func isStandingBy(_ status: AgentHistoryStatus) -> Bool {
        if case .paused(.anotherInstance, _) = status.state {
            return true
        }
        return false
    }

    func test_second_instance_stands_by_until_the_owner_stops() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", mtimeNs: 2), .single("s2", mtimeNs: 1)])
        let owner = harness.makeIndexer()
        owner.start()
        owner.drainSynchronouslyForTesting()

        let recorder = AgentHistoryPublishedRecorder()
        let standingBy = recorder.expectStatus(self, "standing by") { Self.isStandingBy($0) }
        let second = makeSecondInstance(harness, recorder: recorder)
        second.start()
        wait(for: [standingBy], timeout: 5)

        XCTAssertFalse(second.isWriterOpenForTesting)
        XCTAssertEqual(Set(second.currentSnapshot.sessions.map(\.nativeID)), ["s1", "s2"], "the stored sessions show read-only")
        XCTAssertTrue(second.currentSnapshot.isComplete)

        // The owner may still replace its files: nobody else writes them.
        owner.rebuild()
        owner.drainSynchronouslyForTesting()
        XCTAssertEqual(owner.currentStatus.state, .watching)
        XCTAssertTrue(Self.isStandingBy(second.currentStatus))

        let tookOver = recorder.expectStatus(self, "took over") { $0.state == .watching }
        owner.stop(timeout: 5)
        wait(for: [tookOver], timeout: 5)

        XCTAssertTrue(second.isWriterOpenForTesting)
        harness.source.setUnits([.single("s3", mtimeNs: 3)])
        second.requestReconcile()
        second.drainSynchronouslyForTesting()
        XCTAssertEqual(Set(second.currentSnapshot.sessions.map(\.nativeID)), ["s1", "s2", "s3"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 3)
    }

    func test_standby_instance_ignores_rebuild() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1")])
        let owner = harness.makeIndexer()
        owner.start()
        owner.drainSynchronouslyForTesting()
        let marker = try AgentHistoryDatabase(url: harness.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try marker.run("INSERT INTO meta (key, value) VALUES ('owner_marker', '1')")
        marker.close()

        let recorder = AgentHistoryPublishedRecorder()
        let standingBy = recorder.expectStatus(self, "standing by") { Self.isStandingBy($0) }
        let second = makeSecondInstance(harness, recorder: recorder)
        second.start()
        wait(for: [standingBy], timeout: 5)

        second.rebuild()
        second.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM meta WHERE key = 'owner_marker'"), 1, "the owner's index is untouched")
        XCTAssertTrue(owner.isWriterOpenForTesting)
    }

    /// A standby instance never purges, and the owner may not purge for a long time; the
    /// standby snapshot drops an agent turned off at once and keeps it out on every retry.
    func test_standby_snapshot_drops_an_agent_turned_off_before_the_owner_purges() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1")])
        let owner = harness.makeIndexer()
        owner.start()
        owner.drainSynchronouslyForTesting()

        let recorder = AgentHistoryPublishedRecorder()
        let standingBy = recorder.expectStatus(self, "standing by") { Self.isStandingBy($0) }
        let second = makeSecondInstance(harness, recorder: recorder)
        second.start()
        wait(for: [standingBy], timeout: 5)
        XCTAssertEqual(second.currentSnapshot.sessions.map(\.nativeID), ["s1"])

        let agent = harness.source.agent
        let hidden = recorder.expectSnapshot(self, "turned-off agent hidden") { $0.sessions.isEmpty }
        second.purgeSource(agent: agent)
        wait(for: [hidden], timeout: 5)

        // Standby retries re-read the owner's rows, which still hold the agent's sessions.
        let reappeared = recorder.expectSnapshot(self, "turned-off agent reappeared") { !$0.sessions.isEmpty }
        reappeared.isInverted = true
        wait(for: [reappeared], timeout: 0.5)
        XCTAssertTrue(Self.isStandingBy(second.currentStatus))
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 1, "the owner has not purged")

        let shown = recorder.expectSnapshot(self, "turned back on") { $0.sessions.map(\.nativeID) == ["s1"] }
        second.update(configuration: AgentHistoryIndexerConfiguration(
            enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: []))
        wait(for: [shown], timeout: 5)
    }

    func test_busy_batch_is_retried_instead_of_dropped() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("a", mtimeNs: 2), .single("b", mtimeNs: 1)])
        let indexer = harness.makeIndexer()
        let busyOnce = Flag(true)
        let busy = AgentHistoryDatabaseError(kind: .busy, code: 5, extendedCode: 5, message: "injected")
        indexer.beforeCursorSaveForTesting = { ref in
            if ref.unitKey == "a", busyOnce.value {
                busyOnce.value = false
                throw busy
            }
        }
        let indexedA = harness.recorder.expectSnapshot(self, "a indexed after the retry") {
            $0.sessions.contains { $0.nativeID == "a" }
        }

        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["b"])

        wait(for: [indexedA], timeout: 5)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 2)
    }

    // MARK: - Lock files outside the index directory

    /// Delete Index removes the whole directory. A writer lock kept inside it would go with it,
    /// and the next instance would lock a fresh inode while the owner still writes.
    func test_writer_lock_survives_removal_of_the_index_directory() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        index.closeWriter()
        let owner = try index.storage.acquireWriterLock(timeout: 0)
        defer { owner.release() }

        try FileManager.default.removeItem(at: index.paths.directoryURL)

        let other = AgentHistoryStorage(paths: index.paths)
        XCTAssertThrowsError(try other.acquireWriterLock(timeout: 0), "the owner still holds the index") { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
        }
    }

    func test_exclusive_ownership_is_refused_while_another_instance_is_present() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        index.closeWriter()
        let standby = try index.storage.acquirePresenceLock(timeout: 0)
        let other = AgentHistoryStorage(paths: index.paths)

        var ran = false
        XCTAssertThrowsError(try other.withExclusiveOwnership(timeout: 0) { ran = true }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
        }
        XCTAssertFalse(ran)

        standby.release()
        try other.withExclusiveOwnership(timeout: 0) {
            try other.removeEverything()
            XCTAssertThrowsError(try index.storage.acquirePresenceLock(timeout: 0),
                                 "no indexer starts while the delete owns the index")
            XCTAssertThrowsError(try index.storage.acquireWriterLock(timeout: 0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.paths.directoryURL.path),
                       "taking ownership never recreates the directory")
        XCTAssertNoThrow(try index.storage.acquirePresenceLock(timeout: 0).release())
    }
}
