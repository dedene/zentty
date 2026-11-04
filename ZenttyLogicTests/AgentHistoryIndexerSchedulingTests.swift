import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryIndexerSchedulingTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiters: [(target: Int, expectation: XCTestExpectation)] = []

        var value: Int { lock.lock(); defer { lock.unlock() }; return count }

        func increment() {
            lock.lock()
            count += 1
            let current = count
            let reached = waiters.filter { $0.target <= current }
            waiters.removeAll { $0.target <= current }
            lock.unlock()
            reached.forEach { $0.expectation.fulfill() }
        }

        func expect(_ testCase: XCTestCase, reaching target: Int) -> XCTestExpectation {
            let expectation = testCase.expectation(description: "count reaches \(target)")
            lock.lock()
            if count >= target {
                lock.unlock()
                expectation.fulfill()
                return expectation
            }
            waiters.append((target, expectation))
            lock.unlock()
            return expectation
        }
    }

    private func canonical(_ url: URL) -> String {
        FileEventStream.canonicalPath(url.path)
    }

    private func fileEvent(_ path: String, _ flags: FileEventFlags = [.itemModified, .itemIsFile]) -> FileEvent {
        FileEvent(path: path, flags: flags, id: 1)
    }

    // MARK: - Unit events

    func test_fs_event_maps_to_unit_and_enqueues_live() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        harness.source.setUnits([.single("a", messages: ["q1", "a1"])])
        let indexer = harness.makeIndexer(conditions: conditions)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.messageTexts(), ["q1", "a1"])
        let discoveries = harness.source.discoverCount

        // Backfill is paused: only the live lane runs, so indexing proves the event went live.
        conditions.setPauseReason(.lowPower)
        harness.source.setUnits([.single("a", messages: ["q1", "a1", "q2", "a2"], mtimeNs: 2)])
        // The source spells its root the way it was configured; FSEvents reports the realpath.
        harness.source.setEventTarget(.unit("a"), forPath: harness.rootURL.path + "/a.jsonl")
        indexer.handleFileEventsForTesting([fileEvent(canonical(harness.rootURL) + "/a.jsonl")])
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.messageTexts(), ["q1", "a1", "q2", "a2"])
        XCTAssertEqual(harness.source.discoverCount, discoveries, "a known unit needs no discovery")
        XCTAssertEqual(indexer.currentSnapshot.sessions.first?.turnCount, 2)
    }

    func test_event_for_undiscovered_unit_discovers_its_source_once() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        harness.source.setUnits([.single("a")])
        let indexer = harness.makeIndexer(conditions: conditions)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        conditions.setPauseReason(.lowPower)
        let root = canonical(harness.rootURL)

        harness.source.setUnits([.single("b", mtimeNs: 5)])
        harness.source.setEventTarget(.unit("b"), forPath: harness.rootURL.path + "/b.jsonl")
        let before = harness.source.discoverCount
        indexer.handleFileEventsForTesting([fileEvent(root + "/b.jsonl", [.itemCreated, .itemIsFile])])
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(harness.source.discoverCount, before + 1)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE native_id = 'b'"), 1,
                       "a new unit is indexed live even while backfill is paused")

        // A key discovery does not list (a child transcript) is not looked up on every event.
        harness.source.setEventTarget(.unit("child"), forPath: harness.rootURL.path + "/child.jsonl")
        indexer.handleFileEventsForTesting([fileEvent(root + "/child.jsonl")])
        indexer.handleFileEventsForTesting([fileEvent(root + "/child.jsonl")])
        XCTAssertEqual(harness.source.discoverCount, before + 2)
        harness.clock.advance(by: AgentHistoryIndexer.unknownUnitRecheckInterval)
        indexer.handleFileEventsForTesting([fileEvent(root + "/child.jsonl")])
        XCTAssertEqual(harness.source.discoverCount, before + 3)
    }

    func test_noise_paths_are_ignored() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("a")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let ingested = harness.source.ingestedKeys
        let discoveries = harness.source.discoverCount
        let root = canonical(harness.rootURL)
        harness.source.setEventTarget(.unit("a"), forPath: "/elsewhere/a.jsonl")
        harness.source.setEventTarget(.unit("a"), forPath: root + "-sibling/a.jsonl")

        indexer.handleFileEventsForTesting([
            fileEvent(root + "/notes.txt"),
            fileEvent(root + "/.DS_Store"),
            fileEvent(root, [.itemInodeMetaMod, .itemIsDir]),
            fileEvent("/elsewhere/a.jsonl"),
            fileEvent(root + "-sibling/a.jsonl"),
        ])
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(harness.source.ingestedKeys, ingested)
        XCTAssertEqual(harness.source.discoverCount, discoveries)
        XCTAssertEqual(indexer.currentStatus.state, .watching)
    }

    // MARK: - Rescans

    func test_must_scan_subdirs_reconciles_owning_source() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let otherRoot = harness.makeRoot("other-root")
        let other = FakeHistorySource(agent: .codex, rootPath: otherRoot.path)
        harness.source.setUnits([.single("a")])
        let indexer = harness.makeIndexer(extraSources: [other])
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let ownerBefore = harness.source.discoverCount
        let otherBefore = other.discoverCount

        indexer.handleFileEventsForTesting([
            fileEvent(canonical(harness.rootURL) + "/projects", [.mustScanSubDirs, .itemIsDir]),
        ])
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(harness.source.discoverCount, ownerBefore + 1)
        XCTAssertEqual(other.discoverCount, otherBefore)
    }

    func test_dropped_events_reconcile_all_sources() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let other = FakeHistorySource(agent: .codex, rootPath: harness.makeRoot("other-root").path)
        let indexer = harness.makeIndexer(extraSources: [other])
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        for flags in [FileEventFlags.kernelDropped, .userDropped, .unmount] {
            let ownerBefore = harness.source.discoverCount
            let otherBefore = other.discoverCount
            indexer.handleFileEventsForTesting([fileEvent(canonical(harness.rootURL), flags)])
            indexer.drainSynchronouslyForTesting()
            XCTAssertEqual(harness.source.discoverCount, ownerBefore + 1, "flags \(flags.rawValue)")
            XCTAssertEqual(other.discoverCount, otherBefore + 1, "flags \(flags.rawValue)")
        }
    }

    func test_root_changed_reconciles_owner_and_watches_only_existing_roots() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let otherRoot = harness.makeRoot("other-root")
        let other = FakeHistorySource(agent: .codex, rootPath: otherRoot.path)
        let missing = FakeHistorySource(agent: .grok, rootPath: harness.index.directoryURL.appendingPathComponent("absent").path)
        let indexer = harness.makeIndexer(extraSources: [other, missing])
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(Set(indexer.watchedPathsForTesting), [canonical(harness.rootURL), canonical(otherRoot)],
                       "a root that does not exist is not watched")

        let otherCanonical = canonical(otherRoot)
        try FileManager.default.removeItem(at: otherRoot)
        let ownerBefore = harness.source.discoverCount
        let otherBefore = other.discoverCount
        indexer.handleFileEventsForTesting([fileEvent(otherCanonical, [.rootChanged])])
        indexer.drainSynchronouslyForTesting()

        // The real stream may report the same removal on its own (NoDefer), so at least once.
        XCTAssertGreaterThan(other.discoverCount, otherBefore)
        XCTAssertEqual(harness.source.discoverCount, ownerBefore)
        XCTAssertEqual(indexer.watchedPathsForTesting, [canonical(harness.rootURL)])
        XCTAssertEqual(indexer.currentStatus.sources.first { $0.agent == .codex }?.problem, .rootMissing)
    }

    // MARK: - Database polling

    func test_database_events_are_throttled_to_one_poll_per_2s() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let session = FakeHistorySession(nativeID: "s1", title: "First", cwd: "/work/project", messages: ["hello", "hi"])
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: [session])])
        let dbPath = harness.rootURL.path + "/state.db"
        harness.source.setEventTarget(.database("db"), forPath: dbPath)
        harness.source.setEventTarget(.database("db"), forPath: dbPath + "-wal")
        let polls = Counter()
        harness.source.setIngestHook { _, _, _ in polls.increment() }
        let indexer = harness.makeIndexer()
        XCTAssertEqual(indexer.schedule.dbPollMinInterval, 2, "production throttle")
        indexer.schedule.dbPollMinInterval = 1
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(polls.value, 1, "backfill reads the database once")
        let walEvent = fileEvent(canonical(harness.rootURL) + "/state.db-wal")

        // Leading edge: the first change polls at once.
        indexer.handleFileEventsForTesting([walEvent, fileEvent(canonical(harness.rootURL) + "/state.db")])
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(polls.value, 2)

        // Inside the window: changes coalesce into one trailing poll.
        let trailing = polls.expect(self, reaching: 3)
        indexer.handleFileEventsForTesting([walEvent])
        indexer.handleFileEventsForTesting([walEvent])
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(polls.value, 2, "no poll inside the window")
        wait(for: [trailing], timeout: 5)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(polls.value, 3)

        // After a quiet window the next change leads again.
        harness.clock.advance(by: 1)
        indexer.handleFileEventsForTesting([walEvent])
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(polls.value, 4)
    }

    // MARK: - Wake

    func test_wake_triggers_reconcile() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        harness.source.setUnits([.single("a")])
        let indexer = harness.makeIndexer(conditions: conditions)
        indexer.schedule.wakeDelay = 0
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentSnapshot.sessions.count, 1)

        harness.source.setUnits([.single("while-asleep", mtimeNs: 9)])
        let found = harness.recorder.expectSnapshot(self, "wake reconcile finds the new session") { $0.sessions.count == 2 }
        conditions.simulateWake()
        wait(for: [found], timeout: 5)
        XCTAssertEqual(indexer.currentSnapshot.sessions.count, 2)
    }
}
