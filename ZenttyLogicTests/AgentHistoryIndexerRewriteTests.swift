import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryIndexerRewriteTests: XCTestCase {
    private typealias F = AgentHistoryFixtures

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Forwards to a real source and runs a hook before every `ingest`.
    private final class HookedHistorySource: AgentHistorySource, @unchecked Sendable {
        let inner: any AgentHistorySource
        private let lock = NSLock()
        private var hook: (@Sendable () throws -> Void)?

        init(_ inner: any AgentHistorySource) {
            self.inner = inner
        }

        func setHook(_ hook: (@Sendable () throws -> Void)?) {
            lock.lock()
            self.hook = hook
            lock.unlock()
        }

        var agent: AgentHistoryAgent { inner.agent }
        var root: AgentHistorySourceRoot { inner.root }
        var adapterVersion: Int { inner.adapterVersion }
        var watchPaths: [String] { inner.watchPaths }

        func discoverUnits() throws -> [AgentHistoryUnit] { try inner.discoverUnits() }
        func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? { inner.eventTarget(forCanonicalPath: path) }
        func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit { inner.refreshUnit(unit) }
        func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
            inner.classifyChange(unit: unit, cursor: cursor)
        }
        func existingNativeIDs() throws -> Set<String>? { try inner.existingNativeIDs() }
        func estimatedSessionCount() -> Int? { inner.estimatedSessionCount() }

        func ingest(
            unit: AgentHistoryUnit,
            cursor: AgentHistoryCursor?,
            mode: AgentHistoryIngestMode,
            context: AgentHistoryIngestContext
        ) throws -> AgentHistoryIngestBatch {
            lock.lock()
            let hook = self.hook
            lock.unlock()
            try hook?()
            return try inner.ingest(unit: unit, cursor: cursor, mode: mode, context: context)
        }
    }

    /// A temp Claude root with one transcript and an indexer over the real Claude adapter.
    private struct ClaudeSetup {
        let index: AgentHistoryTestIndex
        let transcript: URL
        let source: HookedHistorySource
        let indexer: AgentHistoryIndexer

        func messages() throws -> [String] {
            try index.storage.readers.withReader { db in
                try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }
            }
        }
    }

    private func makeClaudeSetup(messageLimit: Int = 500) throws -> ClaudeSetup {
        let index = AgentHistoryTestIndex(testCase: self)
        let root = index.directoryURL.appendingPathComponent("claude", isDirectory: true)
        let folder = root.appendingPathComponent("projects/\(F.claudeProjectDirectoryName(F.claudeCwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("\(F.claudeSessionID).jsonl")
        let source = HookedHistorySource(ClaudeHistorySource(root: AgentHistorySourceRoot(
            agent: .claude, path: AgentHistoryPath.canonical(root.path), isDefault: false
        )))
        var limits = AgentHistoryIngestLimits()
        limits.messages = messageLimit
        let indexer = AgentHistoryIndexer(
            storage: index.storage,
            stateStore: AgentHistoryStateStore(fileURL: index.paths.stateURL),
            makeSources: { [source] },
            configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: [], limits: limits),
            systemConditions: FakeSystemConditions(),
            onStatusChange: { _ in },
            onSnapshotChange: { _ in }
        )
        addTeardownBlock { indexer.stop(timeout: 2) }
        return ClaudeSetup(index: index, transcript: transcript, source: source, indexer: indexer)
    }

    private func inode(_ url: URL) -> Int64? {
        AgentHistoryFileIdentity.stat(path: url.path)?.ino
    }

    // MARK: - Real Claude transcripts

    func test_partial_trailing_line_waits_for_newline() throws {
        let setup = try makeClaudeSetup()
        let first = try F.claudeUser("Fix the login bug", atMs: F.claudeBaseMs)
        let second = try F.claudeAssistant([F.claudeTextPart("Looking at auth.swift")], atMs: F.claudeBaseMs + 1_000)
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        try Data((first + "\n" + second[..<split]).utf8).write(to: setup.transcript)

        setup.indexer.start()
        setup.indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try setup.messages(), ["Fix the login bug"], "a line without its newline is not read yet")
        let offset = try setup.index.storage.readers.withReader { try $0.scalarInt64("SELECT byte_offset FROM cursors") }
        XCTAssertEqual(offset, Int64(first.utf8.count + 1))

        try F.append(String(second[split...]) + "\n", to: setup.transcript)
        setup.indexer.requestReconcile()
        setup.indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try setup.messages(), ["Fix the login bug", "Looking at auth.swift"])
        XCTAssertEqual(setup.indexer.currentSnapshot.sessions.first?.turnCount, 1)
    }

    func test_truncate_and_regrow_reingests_in_one_swap() throws {
        let setup = try makeClaudeSetup(messageLimit: 1)
        try F.writeJSONL([
            try F.claudeUser("Old question", atMs: F.claudeBaseMs),
            try F.claudeAssistant([F.claudeTextPart("Old answer")], atMs: F.claudeBaseMs + 1_000),
            try F.claudeUser("Old follow-up", atMs: F.claudeBaseMs + 2_000),
        ], to: setup.transcript)
        setup.indexer.start()
        setup.indexer.drainSynchronouslyForTesting()
        let old = ["Old question", "Old answer", "Old follow-up"]
        XCTAssertEqual(try setup.messages(), old)
        let originalInode = inode(setup.transcript)

        // Truncated in place and written again, longer: same inode, different bytes.
        let regrown = [
            try F.claudeUser("Brand new question about the parser", atMs: F.claudeBaseMs + 10_000),
            try F.claudeAssistant([F.claudeTextPart("Brand new answer")], atMs: F.claudeBaseMs + 11_000),
            try F.claudeUser("Brand new follow-up", atMs: F.claudeBaseMs + 12_000),
            try F.claudeAssistant([F.claudeTextPart("Brand new closing")], atMs: F.claudeBaseMs + 13_000),
        ].map { $0 + "\n" }.joined()
        let handle = try FileHandle(forWritingTo: setup.transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(regrown.utf8))
        try handle.close()
        XCTAssertEqual(inode(setup.transcript), originalInode)

        let seenMidSwap = Box<[[String]]>([])
        let readers = setup.index.storage.readers
        setup.source.setHook {
            let texts = try readers.withReader { db in
                try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }
            }
            seenMidSwap.value.append(texts)
        }
        setup.indexer.requestReconcile()
        setup.indexer.drainSynchronouslyForTesting()

        XCTAssertGreaterThan(seenMidSwap.value.count, 1, "the rewrite read the unit in several batches")
        XCTAssertTrue(seenMidSwap.value.allSatisfy { $0 == old }, "readers see the old rows until the swap commits")
        XCTAssertEqual(
            try setup.messages(),
            ["Brand new question about the parser", "Brand new answer", "Brand new follow-up", "Brand new closing"]
        )
        XCTAssertEqual(setup.indexer.currentSnapshot.sessions.first?.turnCount, 2)
    }

    // MARK: - Fake units

    func test_inode_replacement_reingests_and_keeps_opens() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["a", "b", "c"], ino: 1)])
        let indexer = harness.makeIndexer()
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let rowID = try XCTUnwrap(try harness.sessionRowID("s1"))
        try harness.setOpens(5, nativeID: "s1")

        harness.source.setUnits([.single("s1", messages: ["x", "y"], ino: 2)])
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.messageTexts(), ["x", "y"])
        XCTAssertEqual(try harness.sessionRowID("s1"), rowID)
        XCTAssertEqual(try harness.count("SELECT opens FROM sessions WHERE native_id = 's1'"), 5)
        XCTAssertEqual(try harness.count("SELECT ino FROM cursors WHERE unit_key = 's1'"), 2)
        XCTAssertEqual(indexer.currentSnapshot.sessions.first?.opens, 5)
    }

    func test_large_rewrite_uses_batched_commits() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("s1", messages: ["o1", "o2", "o3"], ino: 1)])
        let indexer = harness.makeIndexer(messageLimit: 2)
        indexer.wholeUnitReplaceMaxBytes = 3
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.messageTexts(), ["o1", "o2", "o3"])

        let observed = Box<[Int]>([])
        let readers = harness.index.storage.readers
        harness.source.setIngestHook { _, _, _ in
            observed.value.append(try readers.withReader { try AgentHistoryFixtures.count($0, "SELECT count(*) FROM messages") })
        }
        harness.source.setUnits([.single("s1", messages: ["n1", "n2", "n3", "n4", "n5", "n6"], ino: 2)])
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(observed.value, [3, 2, 4], "over the size limit each batch commits on its own")
        XCTAssertEqual(try harness.messageTexts(), ["n1", "n2", "n3", "n4", "n5", "n6"])
        XCTAssertEqual(try harness.count("SELECT byte_offset FROM cursors WHERE unit_key = 's1'"), 6)
        XCTAssertEqual(try harness.count("SELECT turn_count FROM sessions WHERE native_id = 's1'"), 3)
    }
}
