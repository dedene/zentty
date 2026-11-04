import Foundation
import XCTest
@testable import Zentty

/// Roots that appear while the indexer runs, and stored roots the locator no longer reports.
final class AgentHistoryIndexerRootsTests: XCTestCase {
    private func reconcile(_ indexer: AgentHistoryIndexer) {
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
    }

    private func nativeIDs(_ harness: AgentHistoryIndexerHarness) throws -> Set<String> {
        Set(try harness.read { try $0.query("SELECT native_id FROM sessions") { $0.string(0) } })
    }

    private func makeGrokSource(_ harness: AgentHistoryIndexerHarness) -> FakeHistorySource {
        let source = FakeHistorySource(agent: .grok, rootPath: harness.makeRoot("grok-root").path)
        source.setUnits([.single("grok-1")])
        return source
    }

    func test_root_appearing_after_start_is_indexed_on_the_next_full_reconcile() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let list = FakeHistorySourceList([harness.source])
        let indexer = harness.makeIndexer(sourceList: list)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])

        let grok = makeGrokSource(harness)
        list.sources = [harness.source, grok]
        // An event-driven reconcile of the known source does not look for new roots.
        indexer.requestReconcile(sourceID: try XCTUnwrap(indexer.sourceIDsForTesting.first))
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])

        reconcile(indexer)

        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "grok-1"])
        XCTAssertEqual(indexer.sourceIDsForTesting.count, 2)
        XCTAssertEqual(Set(indexer.currentStatus.sources.map(\.agent)), [.claude, .grok])
        XCTAssertTrue(indexer.watchedPathsForTesting.contains(FileEventStream.canonicalPath(grok.root.path)))

        // Already active roots are not registered twice.
        reconcile(indexer)
        XCTAssertEqual(indexer.sourceIDsForTesting.count, 2)
    }

    func test_stored_root_no_longer_located_is_purged_after_the_grace_period() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let grok = makeGrokSource(harness)
        let first = harness.makeIndexer(sourceList: FakeHistorySourceList([harness.source, grok]))
        first.start()
        first.drainSynchronouslyForTesting()
        first.stop(timeout: 5)
        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "grok-1"])

        // Next launch: the locator no longer reports the Grok root (deleted, or its env var unset).
        let indexer = harness.makeIndexer(sourceList: FakeHistorySourceList([harness.source]))
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        let inactive = try XCTUnwrap(indexer.currentStatus.sources.first { $0.agent == .grok })
        XCTAssertEqual(inactive.problem, .rootMissing)
        XCTAssertEqual(inactive.indexed, 1)
        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "grok-1"], "never purged on the first sighting")

        harness.clock.advance(by: 14 * 60)
        reconcile(indexer)
        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "grok-1"])

        harness.clock.advance(by: 60)
        reconcile(indexer)

        XCTAssertEqual(try nativeIDs(harness), ["claude-1"])
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), ["claude-1"])
        XCTAssertEqual(indexer.currentStatus.sources.map(\.agent), [.claude])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sources WHERE agent = 'grok' AND enabled = 1"), 0)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM cursors WHERE source_id NOT IN (SELECT id FROM sources WHERE agent = 'claude')"), 0)
    }

    func test_stored_root_located_again_before_the_purge_keeps_its_sessions() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([.single("claude-1")])
        let grok = makeGrokSource(harness)
        let first = harness.makeIndexer(sourceList: FakeHistorySourceList([harness.source, grok]))
        first.start()
        first.drainSynchronouslyForTesting()
        first.stop(timeout: 5)

        let list = FakeHistorySourceList([harness.source])
        let indexer = harness.makeIndexer(sourceList: list)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(indexer.currentStatus.sources.first { $0.agent == .grok }?.problem, .rootMissing)

        list.sources = [harness.source, grok]
        harness.clock.advance(by: 16 * 60)
        reconcile(indexer)
        harness.clock.advance(by: 16 * 60)
        reconcile(indexer)

        XCTAssertEqual(try nativeIDs(harness), ["claude-1", "grok-1"])
        XCTAssertNil(indexer.currentStatus.sources.first { $0.agent == .grok }?.problem)
        XCTAssertEqual(indexer.sourceIDsForTesting.count, 2)
    }

    func test_stored_root_without_sessions_is_disabled_without_a_placeholder() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let empty = FakeHistorySource(agent: .grok, rootPath: harness.makeRoot("grok-empty").path)
        let first = harness.makeIndexer(sourceList: FakeHistorySourceList([harness.source, empty]))
        first.start()
        first.drainSynchronouslyForTesting()
        first.stop(timeout: 5)

        let indexer = harness.makeIndexer(sourceList: FakeHistorySourceList([harness.source]))
        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(indexer.currentStatus.sources.map(\.agent), [.claude])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sources WHERE agent = 'grok' AND enabled = 1"), 0)
    }
}
