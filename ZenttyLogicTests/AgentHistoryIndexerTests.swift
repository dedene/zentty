import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryIndexerTests: XCTestCase {
    private struct InjectedFailure: Error {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Backfill

    func test_start_backfills_newest_units_first() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([
            .single("old", mtimeNs: 100),
            .single("newest", mtimeNs: 300),
            .single("middle", mtimeNs: 200),
        ])
        let indexer = harness.makeIndexer()

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(harness.source.ingestedKeys, ["newest", "middle", "old"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 3)
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["newest", "middle", "old"])
        XCTAssertTrue(indexer.currentSnapshot.isComplete)
    }

    func test_each_batch_commits_rows_and_cursor_together() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c", "d", "e"])])
        let observed = Box<[String]>([])
        let reader = harness.index.storage.readers
        harness.source.setIngestHook { unitKey, _, _ in
            // Before every batch, the stored rows and the stored cursor must agree.
            let (rows, offset) = try reader.withReader { db -> (Int, Int64?) in
                (try AgentHistoryFixtures.count(db, "SELECT count(*) FROM messages"),
                 try db.scalarInt64("SELECT byte_offset FROM cursors WHERE unit_key = ?", [.text(unitKey)]))
            }
            observed.value.append("\(rows)/\(offset.map(String.init) ?? "-")")
        }
        let indexer = harness.makeIndexer(messageLimit: 2)

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(observed.value, ["0/-", "2/2", "4/4"])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 5)
        let cursor = try harness.read { db in
            try db.queryOne("SELECT source_id, byte_offset, next_seq FROM cursors WHERE unit_key = 's1'") {
                ($0.int64(0), $0.int64(1), $0.int64(2))
            }
        }
        let sourceID = try XCTUnwrap(indexer.sourceIDsForTesting.first)
        XCTAssertEqual(cursor?.0, sourceID, "the indexer stamps the real source id on adapter cursors")
        XCTAssertEqual(cursor?.1, 5)
        XCTAssertEqual(cursor?.2, 5)
    }

    func test_failure_before_commit_loses_nothing_and_retry_has_no_duplicates() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c", "d", "e"])])
        let first = harness.makeIndexer(messageLimit: 2)
        let commits = Counter()
        first.beforeCursorSaveForTesting = { _ in
            if commits.next() == 2 {
                throw InjectedFailure()
            }
        }

        first.start()
        first.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 2, "the failed batch rolled back")
        XCTAssertEqual(try harness.count("SELECT byte_offset FROM cursors WHERE unit_key = 's1'"), 2)
        first.stop()

        let second = harness.makeIndexer(messageLimit: 2)
        second.start()
        second.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 5)
        XCTAssertEqual(try harness.count("SELECT count(DISTINCT seq) FROM messages"), 5)
        XCTAssertEqual(try harness.count("SELECT turn_count FROM sessions WHERE native_id = 's1'"), 3)
    }

    func test_state_goes_starting_backfilling_watching() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1"), .single("s2", mtimeNs: 2)])
        let watching = harness.recorder.expectStatus(self, "watching") { $0.state == .watching }
        let indexer = harness.makeIndexer()

        indexer.start()
        wait(for: [watching], timeout: 10)

        var names: [String] = []
        for status in harness.recorder.statuses where names.last != status.state.logName {
            names.append(status.state.logName)
        }
        XCTAssertEqual(names, ["starting", "backfilling", "watching"])
        let final = try XCTUnwrap(harness.recorder.statuses.last)
        XCTAssertEqual(final.indexedSessions, 2)
        XCTAssertTrue(final.isBackfillComplete)
        XCTAssertTrue(final.indexExists)
        XCTAssertNotNil(final.tokenizer)
        XCTAssertEqual(final.sources.map(\.agent), [.claude])
        let revisions = harness.recorder.statuses.map(\.revision)
        XCTAssertEqual(revisions, revisions.sorted())
    }

    func test_snapshot_published_after_first_50_sessions_and_excludes_children() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        var units = (0..<60).map { FakeHistoryUnit.single(String(format: "s%02d", $0), mtimeNs: Int64(100 + $0)) }
        units.append(.single("child-a", parent: "s00", mtimeNs: 1_000))
        units.append(.single("child-b", parent: "s01", mtimeNs: 1_001))
        harness.source.setUnits(units)
        let complete = harness.recorder.expectSnapshot(self, "complete snapshot") { $0.isComplete }
        let indexer = harness.makeIndexer()

        indexer.start()
        wait(for: [complete], timeout: 15)

        let snapshots = harness.recorder.snapshots
        XCTAssertTrue(
            snapshots.contains { !$0.isComplete && $0.sessions.count == 50 },
            "a snapshot is published as soon as 50 sessions are visible; got \(snapshots.map(\.sessions.count))"
        )
        let final = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(final.sessions.count, 60)
        XCTAssertFalse(final.sessions.contains { $0.nativeID.hasPrefix("child") })
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE parent_native_id IS NOT NULL"), 2)
        let generations = snapshots.map(\.generation)
        XCTAssertEqual(generations, generations.sorted())
        XCTAssertEqual(indexer.currentSnapshot.generation, final.generation)
    }

    // MARK: - Counters and health

    func test_counters_discovered_indexed_skipped_are_persisted() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        var broken = FakeHistoryUnit.single("broken")
        broken.sessions[0].skipReason = .unreadable("summary.json")
        harness.source.setUnits([
            .single("a"), .single("b"), .single("c"),
            broken,
            .single("private", cwd: "/secret/client"),
        ])
        let indexer = harness.makeIndexer(excludedFolders: ["/secret"])

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        let row = try XCTUnwrap(try harness.read { db in
            try db.queryOne("SELECT discovered, indexed, skipped, last_scan_at, last_error FROM sources") {
                ($0.int64(0), $0.int64(1), $0.int64(2), $0.optionalInt64(3), $0.optionalString(4))
            }
        })
        XCTAssertEqual(row.0, 5)
        XCTAssertEqual(row.1, 3)
        XCTAssertEqual(row.2, 1, "user-chosen exclusions are not counted as skipped")
        XCTAssertEqual(row.3, Int64(AgentHistoryTestIndex.fixedNow.timeIntervalSince1970 * 1_000))
        XCTAssertNil(row.4)

        let health = try XCTUnwrap(indexer.currentStatus.sources.first)
        XCTAssertEqual(health.discovered, 5)
        XCTAssertEqual(health.indexed, 3)
        XCTAssertEqual(health.skipped, 1)
        XCTAssertEqual(health.lastScanAt, AgentHistoryTestIndex.fixedNow)
        XCTAssertEqual(
            try harness.count("SELECT rejected FROM cursors WHERE unit_key = 'private'"), 1,
            "an excluded single-session unit is marked rejected"
        )
    }

    func test_database_unit_rejections_and_problems_stay_per_session() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([FakeHistoryUnit(
            key: "db",
            kind: .database,
            sessions: [
                FakeHistorySession(nativeID: "kept", title: "Kept", cwd: "/work/a", messages: ["hello"]),
                FakeHistorySession(nativeID: "hidden", title: "Hidden", cwd: "/secret/b", messages: ["psst"]),
            ],
            problem: .busy
        )])
        let indexer = harness.makeIndexer(excludedFolders: ["/secret"])

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 1, "partial results are kept")
        XCTAssertEqual(try harness.count("SELECT rejected FROM cursors WHERE unit_key = 'db'"), 0,
                       "a rejected session never rejects the shared database cursor")
        let health = try XCTUnwrap(indexer.currentStatus.sources.first)
        XCTAssertEqual(health.problem, .busy)
        XCTAssertEqual(health.lastError, "Database busy")
    }

    // MARK: - Failures and sanitizing

    func test_open_failure_newer_schema_reports_failed() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try harness.index.openWriter()
        harness.index.closeWriter()
        let bump = try AgentHistoryDatabase(url: harness.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try bump.setUserVersion(AgentHistorySchema.currentVersion + 1)
        bump.close()
        harness.source.setUnits([.single("s1")])
        let failed = harness.recorder.expectStatus(self, "failed") {
            $0.state == .failed(.newerSchema(found: AgentHistorySchema.currentVersion + 1))
        }
        let indexer = harness.makeIndexer()

        indexer.start()
        wait(for: [failed], timeout: 5)

        XCTAssertEqual(indexer.currentStatus.state, .failed(.newerSchema(found: AgentHistorySchema.currentVersion + 1)))
        XCTAssertFalse(indexer.isWriterOpenForTesting)
        XCTAssertTrue(harness.source.ingestedKeys.isEmpty)
    }

    func test_titles_sanitized_before_apply() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let key = "sk" + "-ant-api03-" + String(repeating: "A1b2C3d4", count: 5)
        harness.source.setUnits([.single("s1", title: "Rotate \(key) today")])
        let indexer = harness.makeIndexer()

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        let title = try XCTUnwrap(try harness.read { db in
            try db.queryOne("SELECT title FROM sessions WHERE native_id = 's1'") { $0.string(0) }
        })
        XCTAssertFalse(title.contains(key))
        XCTAssertTrue(title.contains(AgentHistoryRedactor.replacement))
        XCTAssertFalse(indexer.currentSnapshot.sessions.contains { $0.title.contains(key) })
    }

    func test_identity_only_change_writes_no_rows() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c"], ino: 7)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let rowIDs = try harness.read { db in try db.query("SELECT id FROM messages ORDER BY id") { $0.int64(0) } }
        XCTAssertEqual(rowIDs.count, 3)

        // The plain file was replaced by a compressed one with the same content.
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c"], ino: 8)])
        harness.source.overrideChange("s1", .identityOnly)
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(harness.source.ingestedKeys, ["s1"], "identity-only changes never re-read the unit")
        XCTAssertEqual(try harness.read { db in try db.query("SELECT id FROM messages ORDER BY id") { $0.int64(0) } }, rowIDs)
        XCTAssertEqual(try harness.count("SELECT ino FROM cursors WHERE unit_key = 's1'"), 8)
        XCTAssertEqual(try harness.count("SELECT byte_offset FROM cursors WHERE unit_key = 's1'"), 3)
    }

    func test_rewrite_replaces_unit_content_in_one_swap() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["old one", "old two", "old three"], ino: 1)])
        let indexer = harness.makeIndexer(messageLimit: 1)
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        harness.source.setUnits([.single("s1", messages: ["new one", "new two"], ino: 2)])
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        let texts = try harness.read { db in try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) } }
        XCTAssertEqual(texts, ["new one", "new two"])
        XCTAssertEqual(try harness.count("SELECT byte_offset FROM cursors WHERE unit_key = 's1'"), 2)
        XCTAssertEqual(try harness.count("SELECT turn_count FROM sessions WHERE native_id = 's1'"), 1)
        XCTAssertEqual(indexer.currentSnapshot.sessions.first?.turnCount, 1)
    }

    func test_real_claude_source_appends_without_duplicates() throws {
        typealias F = AgentHistoryFixtures
        let index = AgentHistoryTestIndex(testCase: self)
        let root = index.directoryURL.appendingPathComponent("claude", isDirectory: true)
        let folder = root.appendingPathComponent("projects/\(F.claudeProjectDirectoryName(F.claudeCwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("\(F.claudeSessionID).jsonl")
        try F.writeJSONL([
            try F.claudeUser("Fix the login bug", atMs: F.claudeBaseMs),
            try F.claudeAssistant([F.claudeTextPart("Looking at auth.swift")], atMs: F.claudeBaseMs + 1_000),
        ], to: transcript)
        let source = ClaudeHistorySource(root: AgentHistorySourceRoot(
            agent: .claude, path: AgentHistoryPath.canonical(root.path), isDefault: false
        ))
        let indexer = AgentHistoryIndexer(
            storage: index.storage,
            stateStore: AgentHistoryStateStore(fileURL: index.paths.stateURL),
            makeSources: { [source] },
            configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: []),
            systemConditions: FakeSystemConditions(),
            onStatusChange: { _ in },
            onSnapshotChange: { _ in }
        )
        addTeardownBlock { indexer.stop(timeout: 2) }

        indexer.start()
        indexer.drainSynchronouslyForTesting()
        func messages() throws -> [String] {
            try index.storage.readers.withReader { db in
                try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }
            }
        }
        XCTAssertEqual(try messages(), ["Fix the login bug", "Looking at auth.swift"])

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try F.claudeUser("Now add a test", atMs: F.claudeBaseMs + 5_000) + "\n").utf8))
        try handle.close()
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try messages(), ["Fix the login bug", "Looking at auth.swift", "Now add a test"])
        let session = try XCTUnwrap(indexer.currentSnapshot.sessions.first)
        XCTAssertEqual(session.nativeID, F.claudeSessionID)
        XCTAssertEqual(session.turnCount, 2)
        XCTAssertEqual(session.cwd, F.claudeCwd)
    }

    // MARK: - Stop

    func test_stop_returns_within_timeout_during_slow_rewrite() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c", "d", "e"], ino: 1)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 5)

        let entered = DispatchSemaphore(value: 0)
        harness.source.setIngestHook { _, _, context in
            entered.signal()
            let deadline = Date().addingTimeInterval(10)
            while !context.isCancelled(), Date() < deadline {
                usleep(5_000)
            }
            throw CancellationError()
        }
        harness.source.setUnits([.single("s1", messages: ["x", "y"], ino: 2)])
        indexer.requestReconcile()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let started = Date()
        indexer.stop(timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        XCTAssertEqual(try harness.count("SELECT count(*) FROM messages"), 5, "the cancelled rewrite rolled back")
        XCTAssertEqual(try harness.count("SELECT turn_count FROM sessions WHERE native_id = 's1'"), 3)
        XCTAssertEqual(try harness.count("SELECT ino FROM cursors WHERE unit_key = 's1'"), 1)
    }

    func test_stop_closes_writer_and_ignores_later_events() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1")])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertTrue(indexer.isWriterOpenForTesting)

        indexer.stop()

        XCTAssertFalse(indexer.isWriterOpenForTesting)
        XCTAssertEqual(indexer.currentStatus.state, .off)
        let discoveries = harness.source.discoverCount
        harness.source.setUnits([.single("s2", mtimeNs: 9)])
        indexer.requestReconcile()
        indexer.update(configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: []))
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(harness.source.discoverCount, discoveries)
        XCTAssertEqual(harness.source.ingestedKeys, ["s1"])
        XCTAssertFalse(indexer.isWriterOpenForTesting)
    }
}
