import Foundation
import XCTest
@testable import Zentty

/// Turning Agent History or a source off is the privacy switch: it takes effect in memory even
/// when `state.json` can't be written (full disk, a locked or read-only directory), and the
/// caller hears that the change wasn't saved. Turning something on that couldn't be saved
/// changes nothing. The AgentHistory directory is made read-only after launch, so the state
/// store (already loaded) fails every write while the open index keeps working.
@MainActor
final class AgentHistoryControllerStateWriteFailureTests: XCTestCase {
    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return made }
        func record() { lock.lock(); made += 1; lock.unlock() }
    }

    private struct Fixture {
        let controller: AgentHistoryController
        let paths: AgentHistoryPaths
        let factory: FactoryLog
    }

    private static let allSessions: Set<String> = ["claude-outside", "codex-one"]

    private func makeFixture() -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-write-failure-\(UUID().uuidString)", isDirectory: true)
        let paths = AgentHistoryPaths(directoryURL: base.appendingPathComponent("AgentHistory", isDirectory: true))
        let claudeRoot = base.appendingPathComponent("claude-root", isDirectory: true)
        let codexRoot = base.appendingPathComponent("codex-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let claude = FakeHistorySource(agent: .claude, rootPath: claudeRoot.path)
        let codex = FakeHistorySource(agent: .codex, rootPath: codexRoot.path)
        claude.setUnits([.single("claude-outside", cwd: "/work/project")])
        codex.setUnits([.single("codex-one", cwd: "/work/project")])

        let factory = FactoryLog()
        let sources: [any AgentHistorySource] = [claude, codex]
        let controller = AgentHistoryController(
            launchDelay: 0,
            makeSources: { sources },
            makeIndexer: { storage, stateStore, configuration, callbacks in
                factory.record()
                return AgentHistoryIndexer(
                    storage: storage,
                    stateStore: stateStore,
                    makeSources: { sources },
                    configuration: configuration,
                    systemConditions: FakeSystemConditions(),
                    onStatusChange: callbacks.onStatusChange,
                    onSnapshotChange: callbacks.onSnapshotChange
                )
            }
        )
        let configStore = AppConfigStore(fileURL: base.appendingPathComponent("config.toml", isDirectory: false))
        controller.configure(configStore: configStore, paths: paths)
        addTeardownBlock { @MainActor in
            controller.stop()
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directoryURL.path)
            try? FileManager.default.removeItem(at: base)
        }
        return Fixture(controller: controller, paths: paths, factory: factory)
    }

    private func writeState(_ paths: AgentHistoryPaths, _ mutate: (inout AgentHistoryState) -> Void) throws {
        try AgentHistoryStateStore(fileURL: paths.stateURL).update(mutate)
    }

    private func persistedState(_ paths: AgentHistoryPaths) -> AgentHistoryState {
        AgentHistoryStateStore(fileURL: paths.stateURL).current
    }

    /// From here on `state.json` can't be replaced: the temp file it is written through can't
    /// be created in a read-only directory.
    private func makeStateUnwritable(_ paths: AgentHistoryPaths) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.directoryURL.path)
    }

    private func launch(_ controller: AgentHistoryController) -> Bool {
        let decided = expectation(description: "launch decision")
        var started = false
        controller.scheduleStartAfterLaunch { result in
            started = result
            decided.fulfill()
        }
        wait(for: [decided], timeout: 5)
        return started
    }

    private func waitForStatus(
        _ controller: AgentHistoryController,
        _ description: String,
        where predicate: @escaping (AgentHistoryStatus) -> Bool
    ) {
        if predicate(controller.status) {
            return
        }
        let reached = expectation(description: description)
        var fulfilled = false
        let id = controller.addStatusObserver { status in
            if !fulfilled, predicate(status) {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: 10)
        controller.removeObserver(id)
    }

    private func waitForSessions(_ controller: AgentHistoryController, _ expected: Set<String>) {
        let ids = { (snapshot: AgentHistoryMetadataSnapshot) in Set(snapshot.sessions.map(\.nativeID)) }
        if ids(controller.metadataSnapshot) == expected {
            return
        }
        let reached = expectation(description: "sessions \(expected.sorted())")
        var fulfilled = false
        let id = controller.addSnapshotObserver { snapshot in
            if !fulfilled, ids(snapshot) == expected {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: 10)
        controller.removeObserver(id)
    }

    private func launchIndexed(_ fixture: Fixture) throws -> AgentHistoryStorage {
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForSessions(fixture.controller, Self.allSessions)
        return try XCTUnwrap(fixture.controller.storage)
    }

    func test_turn_off_stops_indexing_and_revokes_readers_when_state_cannot_be_saved() throws {
        let fixture = makeFixture()
        let storage = try launchIndexed(fixture)
        try makeStateUnwritable(fixture.paths)

        let answered = expectation(description: "turn off answered")
        var outcome: AgentHistoryStateChangeOutcome?
        fixture.controller.setEnabled(false) {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        fixture.controller.drainControlQueueForTesting()

        XCTAssertEqual(outcome, .appliedButNotSaved)
        XCTAssertNil(fixture.controller.indexer, "indexing stopped")
        XCTAssertNil(fixture.controller.storage, "search has no index to read")
        XCTAssertTrue(storage.readers.isRevoked, "readers handed out earlier read nothing")
        XCTAssertTrue(fixture.controller.metadataSnapshot.sessions.isEmpty)
        XCTAssertEqual(fixture.controller.status.state, .off)
        XCTAssertFalse(fixture.controller.status.isEnabled)
        XCTAssertTrue(persistedState(fixture.paths).enabled, "the file still says on: it wasn't saved")
    }

    func test_turning_a_source_off_hides_and_purges_it_when_state_cannot_be_saved() throws {
        let fixture = makeFixture()
        _ = try launchIndexed(fixture)
        try makeStateUnwritable(fixture.paths)

        let answered = expectation(description: "source off answered")
        var outcome: AgentHistoryStateChangeOutcome?
        fixture.controller.setAgentEnabled(.codex, false) {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)

        XCTAssertEqual(outcome, .appliedButNotSaved)
        XCTAssertFalse(fixture.controller.enabledAgents.contains(.codex), "search hides it at once")
        waitForSessions(fixture.controller, ["claude-outside"])
        waitForStatus(fixture.controller, "codex off") { !$0.enabledAgents.contains(.codex) }
        XCTAssertNotNil(fixture.controller.indexer, "the other source keeps indexing")
        XCTAssertTrue(persistedState(fixture.paths).isSourceEnabled(.codex), "the file still says on")
    }

    func test_turning_on_changes_nothing_when_state_cannot_be_saved() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = false; $0.consentedAt = Date() }
        XCTAssertFalse(launch(fixture.controller))
        waitForStatus(fixture.controller, "state loaded") { $0.isStateLoaded && $0.hasConsented }
        try makeStateUnwritable(fixture.paths)

        let answered = expectation(description: "turn on answered")
        var outcome: AgentHistoryStateChangeOutcome?
        fixture.controller.setEnabled(true) {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        fixture.controller.drainControlQueueForTesting()

        XCTAssertEqual(outcome, .notSaved)
        XCTAssertNil(fixture.controller.indexer, "nothing starts that a restart would undo")
        XCTAssertEqual(fixture.factory.count, 0)
        XCTAssertFalse(fixture.controller.status.isEnabled)
    }

    func test_disable_keeping_the_index_reports_failure_and_stays_off_when_state_cannot_be_saved() throws {
        let fixture = makeFixture()
        let storage = try launchIndexed(fixture)
        try makeStateUnwritable(fixture.paths)

        let answered = expectation(description: "disable answered")
        var outcome: AgentHistoryDisableOutcome?
        fixture.controller.disable(deleteIndex: false) {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        fixture.controller.drainControlQueueForTesting()

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(fixture.controller.indexer, "indexing never restarts")
        XCTAssertEqual(fixture.factory.count, 1)
        XCTAssertNil(fixture.controller.storage)
        XCTAssertTrue(storage.readers.isRevoked)
        XCTAssertFalse(fixture.controller.status.isEnabled)
    }
}
