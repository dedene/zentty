import Foundation
import XCTest
@testable import Zentty

/// Real FSEvents end to end: a change on disk reaches the index through the stream, without a
/// reconcile. Latency 0.1 s; the 5 s budget is the user-facing promise.
final class AgentHistoryIndexerLiveIntegrationTests: XCTestCase {
    private typealias F = AgentHistoryFixtures

    func test_appended_claude_reply_is_indexed_within_5_seconds() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let root = index.directoryURL.appendingPathComponent("claude", isDirectory: true)
        let folder = root.appendingPathComponent("projects/\(F.claudeProjectDirectoryName(F.claudeCwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("\(F.claudeSessionID).jsonl")
        try F.writeJSONL([
            try F.claudeUser("Fix the login bug", atMs: F.claudeBaseMs),
            try F.claudeAssistant([F.claudeTextPart("Looking at auth.swift")], atMs: F.claudeBaseMs + 1_000),
        ], to: transcript)

        let recorder = AgentHistoryPublishedRecorder()
        var configuration = AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: [])
        configuration.fileEventLatency = 0.1
        let source = ClaudeHistorySource(root: AgentHistorySourceRoot(
            agent: .claude, path: AgentHistoryPath.canonical(root.path), isDefault: false
        ))
        let indexer = AgentHistoryIndexer(
            storage: index.storage,
            stateStore: AgentHistoryStateStore(fileURL: index.paths.stateURL),
            makeSources: { [source] },
            configuration: configuration,
            systemConditions: FakeSystemConditions(),
            onStatusChange: { recorder.record($0) },
            onSnapshotChange: { recorder.record($0) }
        )
        addTeardownBlock { indexer.stop(timeout: 2) }
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentSnapshot.sessions.first?.turnCount, 1)
        XCTAssertFalse(indexer.watchedPathsForTesting.isEmpty, "the projects folder is watched")

        let indexed = recorder.expectSnapshot(self, "the follow-up turn is indexed") {
            $0.sessions.first?.turnCount == 2
        }
        let started = Date()
        try F.append(
            try F.claudeUser("Also check logout", atMs: F.claudeBaseMs + 2_000) + "\n"
                + (try F.claudeAssistant([F.claudeTextPart("Logout is fine")], atMs: F.claudeBaseMs + 3_000)) + "\n",
            to: transcript
        )
        wait(for: [indexed], timeout: 5)
        AgentHistoryLog.indexer.info("live claude latency ms=\(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public)")

        let texts = try index.storage.readers.withReader { db in
            try db.query("SELECT text FROM messages ORDER BY seq") { $0.string(0) }
        }
        XCTAssertEqual(texts, ["Fix the login bug", "Looking at auth.swift", "Also check logout", "Logout is fine"])
    }

    func test_database_source_change_is_indexed_within_5_seconds() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let database = harness.rootURL.appendingPathComponent("state.db")
        try Data("v1".utf8).write(to: database)
        let first = FakeHistorySession(nativeID: "s1", title: "First", cwd: "/work/project", messages: ["hello", "hi"])
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: [first])])
        harness.source.setEventTarget(.database("db"), forPath: database.path)
        let indexer = harness.makeIndexer(fileEventLatency: 0.1)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["s1"])
        XCTAssertFalse(indexer.watchedPathsForTesting.isEmpty, "the database folder is watched")

        let second = FakeHistorySession(nativeID: "s2", title: "Second", cwd: "/work/project",
                                        messages: ["next", "sure"], baseAtMs: 1_793_000_100_000)
        harness.source.setUnits([FakeHistoryUnit(key: "db", kind: .database, sessions: [first, second])])
        let indexed = harness.recorder.expectSnapshot(self, "the new database session is indexed") {
            $0.sessions.count == 2
        }
        try F.append("v2", to: database)
        wait(for: [indexed], timeout: 5)
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["s1", "s2"])
    }
}
