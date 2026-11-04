import Foundation
import XCTest
@testable import Zentty

/// Grok holds back sessions without a usable folder while any folder is excluded. The live
/// index must match a fresh one: such a session indexed before the first exclusion goes when
/// that exclusion is added, and comes back once no folder is excluded.
final class AgentHistoryIndexerGrokExclusionTests: XCTestCase {
    private let sessionID = "01a07283-b64e-77b3-b235-8cc132de66ed"
    private let placedSessionID = "01a09b96-0000-7000-8000-000000000001"

    func test_session_without_folder_is_purged_when_the_first_exclusion_is_added() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let root = harness.makeRoot("grok-home")
        let project = harness.makeRoot("project")
        var summary = AgentHistoryFixtures.grokSummary(id: sessionID, cwd: "relative-project")
        summary["info"] = ["id": sessionID, "cwd": "relative-project"]
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: "relative-project", summary: summary, chat: [
            try AgentHistoryFixtures.grokChat("user", text: "where am I", promptIndex: 0),
        ])
        try AgentHistoryFixtures.writeGrokSession(root: root, id: placedSessionID, cwd: project.path, chat: [
            try AgentHistoryFixtures.grokChat("user", text: "placed", promptIndex: 0),
        ])
        let grok = AgentHistoryFixtures.grokSource(root: root)
        let indexer = AgentHistoryIndexer(
            storage: harness.index.storage,
            stateStore: harness.stateStore,
            makeSources: { [grok] },
            configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.grok], excludedFolders: []),
            systemConditions: FakeSystemConditions(),
            onStatusChange: { _ in },
            onSnapshotChange: { _ in }
        )
        addTeardownBlock { indexer.stop(timeout: 2) }
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        func stored() throws -> Set<String> {
            Set(try harness.read { try $0.query("SELECT native_id FROM sessions") { $0.string(0) } })
        }
        XCTAssertEqual(try stored(), [sessionID, placedSessionID])

        indexer.update(configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.grok], excludedFolders: ["/elsewhere"]))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try stored(), [placedSessionID], "a fresh index would hold it back too")
        XCTAssertEqual(indexer.currentSnapshot.sessions.map(\.nativeID), [placedSessionID])
        XCTAssertEqual(try harness.count("SELECT count(*) FROM cursors WHERE rejected = 1"), 1, "its unit is rejected")
        indexer.requestReconcile()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try stored(), [placedSessionID], "a reconcile does not read it back")

        indexer.update(configuration: AgentHistoryIndexerConfiguration(enabledAgents: [.grok], excludedFolders: []))
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try stored(), [sessionID, placedSessionID], "back once nothing is excluded")
    }
}
