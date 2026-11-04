import Foundation
import XCTest
@testable import Zentty

/// Turning an agent off (D4): it stops being read at once, and its rows go even when the first
/// delete fails or no indexer ran at the time.
final class AgentHistoryIndexerSourcePurgeTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func nativeIDs(_ harness: AgentHistoryIndexerHarness) throws -> [String] {
        try harness.read { db in try db.query("SELECT native_id FROM sessions ORDER BY native_id") { $0.string(0) } }
    }

    private func makeCodex(_ harness: AgentHistoryIndexerHarness) -> FakeHistorySource {
        let codex = FakeHistorySource(agent: .codex, rootPath: harness.makeRoot("codex").path)
        codex.setUnits([.single("codex-1")])
        return codex
    }

    func test_failed_purge_stops_reading_the_agent_and_is_retried() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let codex = makeCodex(harness)
        let indexer = harness.makeIndexer(extraSources: [codex])
        let purgeFails = Flag(true)
        let busy = AgentHistoryDatabaseError(kind: .busy, code: 5, extendedCode: 5, message: "injected")
        indexer.beforeSourcePurgeForTesting = { _ in
            if purgeFails.value {
                throw busy
            }
        }
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "codex-1"])

        indexer.purgeSource(agent: .codex)
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "codex-1"], "the delete failed")
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["claude-1"], "hidden at once")
        XCTAssertFalse(indexer.currentStatus.sources.contains { $0.agent == .codex })
        let ingested = codex.ingestedKeys.count
        codex.setUnits([.single("codex-2", mtimeNs: 5)])
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(codex.ingestedKeys.count, ingested, "a turned-off agent is not read again")

        // A later configuration push with the same agents must not forget the pending purge.
        indexer.update(configuration: AgentHistoryIndexerConfiguration(
            enabledAgents: Set(AgentHistoryAgent.allCases).subtracting([.codex]), excludedFolders: []
        ))
        purgeFails.value = false
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])
        XCTAssertEqual(try harness.count("SELECT enabled FROM sources WHERE agent = 'codex'"), 0)
        XCTAssertEqual(try harness.count(
            "SELECT count(*) FROM cursors c JOIN sources s ON s.id = c.source_id WHERE s.agent = 'codex'"
        ), 0)
        XCTAssertEqual(codex.ingestedKeys.count, ingested)
    }

    func test_start_purges_agents_turned_off_while_no_indexer_ran() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let codex = makeCodex(harness)
        let first = harness.makeIndexer(extraSources: [codex])
        first.start()
        first.drainSynchronouslyForTesting()
        first.stop(timeout: 5)

        let claude = harness.source
        let indexer = AgentHistoryIndexer(
            storage: harness.index.storage,
            stateStore: harness.stateStore,
            makeSources: { [claude, codex] },
            configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: []),
            systemConditions: FakeSystemConditions(),
            onStatusChange: { _ in },
            onSnapshotChange: { _ in }
        )
        addTeardownBlock { indexer.stop(timeout: 2) }
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["claude-1"])
        XCTAssertEqual(try harness.count("SELECT enabled FROM sources WHERE agent = 'codex'"), 0)
    }

    func test_configuration_dropping_an_agent_purges_its_rows() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let indexer = harness.makeIndexer(extraSources: [makeCodex(harness)])
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        indexer.update(configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.claude], excludedFolders: []))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["claude-1"])
    }
}
