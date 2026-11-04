import Foundation
import XCTest
@testable import Zentty

/// Zentty instances of one flavor share `state.json`. A change saved by one instance is never
/// undone by another one's stale copy, and an indexer that takes over the index honours what
/// the file says now, not what it read when it started.
final class AgentHistoryStateSharingTests: XCTestCase {
    private static let consentedAt = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: - Two stores on one file

    func test_two_stores_never_undo_each_others_agent_choices() throws {
        let fileURL = makeStateFileURL()
        let first = AgentHistoryStateStore(fileURL: fileURL)
        try first.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        // Loaded while Claude is still on: this is the stale copy of a second instance.
        let second = AgentHistoryStateStore(fileURL: fileURL)

        try first.update { $0.setSource(.claude, enabled: false) }
        try second.update { $0.setSource(.codex, enabled: false) }

        let onDisk = AgentHistoryStateStore(fileURL: fileURL).current
        XCTAssertFalse(onDisk.isSourceEnabled(.claude), "the second instance wrote Claude back on")
        XCTAssertFalse(onDisk.isSourceEnabled(.codex))
        XCTAssertTrue(onDisk.enabled)
        XCTAssertEqual(onDisk.consentedAt, Self.consentedAt)
        XCTAssertFalse(second.current.isSourceEnabled(.claude), "an update adopts the saved state")
    }

    func test_turning_history_off_in_one_store_survives_a_change_in_another() throws {
        let fileURL = makeStateFileURL()
        let first = AgentHistoryStateStore(fileURL: fileURL)
        try first.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        let second = AgentHistoryStateStore(fileURL: fileURL)

        try first.update { $0.enabled = false }
        try second.update { $0.setSource(.grok, enabled: false) }

        let onDisk = AgentHistoryStateStore(fileURL: fileURL).current
        XCTAssertFalse(onDisk.enabled, "the second instance turned History back on")
        XCTAssertFalse(onDisk.isSourceEnabled(.grok))
    }

    func test_reload_shows_another_stores_change_and_notifies() throws {
        let fileURL = makeStateFileURL()
        let first = AgentHistoryStateStore(fileURL: fileURL)
        try first.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        let second = AgentHistoryStateStore(fileURL: fileURL)
        try first.update { $0.setSource(.claude, enabled: false) }
        XCTAssertTrue(second.current.isSourceEnabled(.claude), "no re-read yet")

        let notified = expectation(description: "observer sees the other store's change")
        second.addObserver { state in
            if !state.isSourceEnabled(.claude) {
                notified.fulfill()
            }
        }
        XCTAssertFalse(second.reload().isSourceEnabled(.claude))
        XCTAssertFalse(second.current.isSourceEnabled(.claude))
        wait(for: [notified], timeout: 2)
    }

    /// Delete Index in another instance removes the file: consent is gone here too.
    func test_reload_of_a_removed_file_reads_as_the_disabled_default() throws {
        let fileURL = makeStateFileURL()
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        try FileManager.default.removeItem(at: fileURL)

        XCTAssertEqual(store.reload(), AgentHistoryState())
    }

    func test_reload_of_a_corrupt_file_keeps_the_last_known_state() throws {
        let fileURL = makeStateFileURL()
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { $0.enabled = true; $0.consentedAt = Self.consentedAt; $0.setSource(.codex, enabled: false) }
        try Data("{ not json".utf8).write(to: fileURL)

        let reloaded = store.reload()
        XCTAssertTrue(reloaded.enabled)
        XCTAssertFalse(reloaded.isSourceEnabled(.codex), "never falls back to everything on")
    }

    /// A revocation that couldn't be saved holds over every re-read until a write succeeds.
    func test_unsaved_revocation_survives_reload_and_is_saved_by_the_next_write() throws {
        let fileURL = makeStateFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        let store = AgentHistoryStateStore(fileURL: fileURL)
        try store.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryURL.path)
        XCTAssertThrowsError(try store.update { $0.setSource(.claude, enabled: false) })
        XCTAssertFalse(store.reload().isSourceEnabled(.claude), "the file still says on")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        try store.update { $0.setSource(.grok, enabled: false) }

        let onDisk = AgentHistoryStateStore(fileURL: fileURL).current
        XCTAssertFalse(onDisk.isSourceEnabled(.claude))
        XCTAssertFalse(onDisk.isSourceEnabled(.grok))
        XCTAssertTrue(onDisk.enabled)
    }

    // MARK: - Indexer takeover

    /// The standby instance started while History was on. It was turned off since; when the
    /// owner quits, the standby must not take the index over and start reading again.
    func test_standby_does_not_take_over_after_history_was_turned_off() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try harness.stateStore.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        harness.source.setUnits([.single("s1")])
        let owner = harness.makeIndexer()
        owner.start()
        owner.drainSynchronouslyForTesting()

        let recorder = AgentHistoryPublishedRecorder()
        let standingBy = recorder.expectStatus(self, "standing by") { Self.isStandingBy($0) }
        let second = makeSecondInstance(harness, recorder: recorder)
        second.start()
        wait(for: [standingBy], timeout: 5)

        // Another instance turns History off.
        try AgentHistoryStateStore(fileURL: harness.index.paths.stateURL).update { $0.enabled = false }

        let tookOver = recorder.expectStatus(self, "took over") { $0.state == .watching }
        tookOver.isInverted = true
        owner.stop(timeout: 5)
        wait(for: [tookOver], timeout: 1)
        XCTAssertFalse(second.isWriterOpenForTesting, "History is off on disk: nothing may index")
    }

    /// Claude was turned off (and purged) by another instance after this standby started; the
    /// takeover purges what is left and never reads Claude again.
    func test_standby_takeover_leaves_out_an_agent_turned_off_since_it_started() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        try harness.stateStore.update { $0.enabled = true; $0.consentedAt = Self.consentedAt }
        harness.source.setUnits([.single("s1")])
        let owner = harness.makeIndexer()
        owner.start()
        owner.drainSynchronouslyForTesting()

        let recorder = AgentHistoryPublishedRecorder()
        let standingBy = recorder.expectStatus(self, "standing by") { Self.isStandingBy($0) }
        let second = makeSecondInstance(harness, recorder: recorder)
        second.start()
        wait(for: [standingBy], timeout: 5)

        let agent = harness.source.agent
        try AgentHistoryStateStore(fileURL: harness.index.paths.stateURL).update { $0.setSource(agent, enabled: false) }

        let tookOver = recorder.expectStatus(self, "took over") { $0.state == .watching }
        owner.stop(timeout: 5)
        wait(for: [tookOver], timeout: 5)
        second.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 0, "the turned-off agent's rows are purged")
        XCTAssertTrue(second.currentSnapshot.sessions.isEmpty)
    }

    // MARK: - Helpers

    private static func isStandingBy(_ status: AgentHistoryStatus) -> Bool {
        if case .paused(.anotherInstance, _) = status.state {
            return true
        }
        return false
    }

    private func makeStateFileURL() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("state.json", isDirectory: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: AgentHistoryStateStore.lockURL(forStateFileAt: fileURL))
        }
        return fileURL
    }

    /// A second "process": its own storage, its own state store (read now, so it goes stale),
    /// its own recorder, all agents on as its controller saw them at start.
    private func makeSecondInstance(
        _ harness: AgentHistoryIndexerHarness,
        recorder: AgentHistoryPublishedRecorder
    ) -> AgentHistoryIndexer {
        let source = harness.source
        let clock = harness.clock
        let indexer = AgentHistoryIndexer(
            storage: AgentHistoryStorage(paths: harness.index.paths),
            stateStore: AgentHistoryStateStore(fileURL: harness.index.paths.stateURL),
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
}

/// The controller re-reads `state.json`, so a change another instance saved applies here.
@MainActor
final class AgentHistoryControllerStateSharingTests: XCTestCase {
    private struct Fixture {
        let controller: AgentHistoryController
        let paths: AgentHistoryPaths
    }

    private func makeFixture() -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        let paths = AgentHistoryPaths(directoryURL: base.appendingPathComponent("AgentHistory", isDirectory: true))
        let claudeRoot = base.appendingPathComponent("claude-root", isDirectory: true)
        let codexRoot = base.appendingPathComponent("codex-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let claude = FakeHistorySource(agent: .claude, rootPath: claudeRoot.path)
        let codex = FakeHistorySource(agent: .codex, rootPath: codexRoot.path)
        claude.setUnits([.single("claude-one", cwd: "/work/project")])
        codex.setUnits([.single("codex-one", cwd: "/work/project")])
        let sources: [any AgentHistorySource] = [claude, codex]
        let controller = AgentHistoryController(
            launchDelay: 0,
            stateRefreshInterval: 0.1,
            makeSources: { sources },
            makeIndexer: { storage, stateStore, configuration, callbacks in
                AgentHistoryIndexer(
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
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: AgentHistoryStateStore.lockURL(forStateFileAt: paths.stateURL))
        }
        return Fixture(controller: controller, paths: paths)
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

    private func otherInstanceUpdates(_ paths: AgentHistoryPaths, _ mutate: (inout AgentHistoryState) -> Void) throws {
        try AgentHistoryStateStore(fileURL: paths.stateURL).update(mutate)
    }

    func test_history_turned_off_in_another_instance_stops_the_indexer_here() throws {
        let fixture = makeFixture()
        try otherInstanceUpdates(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "indexing") { $0.state == .watching }

        try otherInstanceUpdates(fixture.paths) { $0.enabled = false }

        waitForStatus(fixture.controller, "turned off") { !$0.isEnabled && $0.state == .off }
        XCTAssertNil(fixture.controller.indexer)
    }

    func test_agent_turned_off_in_another_instance_is_purged_here() throws {
        let fixture = makeFixture()
        try otherInstanceUpdates(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "indexing") { $0.state == .watching && $0.indexedSessions == 2 }

        try otherInstanceUpdates(fixture.paths) { $0.setSource(.claude, enabled: false) }

        waitForStatus(fixture.controller, "Claude gone") { !$0.enabledAgents.contains(.claude) && $0.indexedSessions == 1 }
        XCTAssertFalse(fixture.controller.enabledAgents.contains(.claude))
        XCTAssertEqual(fixture.controller.metadataSnapshot.sessions.map(\.nativeID), ["codex-one"])

        // A change made here afterwards keeps Claude off on disk.
        let saved = expectation(description: "saved")
        fixture.controller.setAgentEnabled(.codex, false) { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)
        let onDisk = AgentHistoryStateStore(fileURL: fixture.paths.stateURL).current
        XCTAssertFalse(onDisk.isSourceEnabled(.claude))
        XCTAssertFalse(onDisk.isSourceEnabled(.codex))
    }
}
