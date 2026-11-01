import Foundation
import XCTest
@testable import Zentty

/// The app-level owner of the indexer (I9): launch gating, consent, config pushes, disable and
/// per-agent purge. Every test injects temp paths, fake sources and a fake indexer factory.
@MainActor
final class AgentHistoryControllerTests: XCTestCase {
    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [AgentHistoryIndexer] = []
        private var configurations: [AgentHistoryIndexerConfiguration] = []

        var count: Int { lock.lock(); defer { lock.unlock() }; return made.count }
        var last: AgentHistoryIndexer? { lock.lock(); defer { lock.unlock() }; return made.last }
        var lastConfiguration: AgentHistoryIndexerConfiguration? {
            lock.lock(); defer { lock.unlock() }; return configurations.last
        }

        func record(_ indexer: AgentHistoryIndexer, _ configuration: AgentHistoryIndexerConfiguration) {
            lock.lock()
            made.append(indexer)
            configurations.append(configuration)
            lock.unlock()
        }
    }

    private struct Fixture {
        let controller: AgentHistoryController
        let paths: AgentHistoryPaths
        let configStore: AppConfigStore
        let claude: FakeHistorySource
        let codex: FakeHistorySource
        let factory: FactoryLog
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
        claude.setUnits([
            .single("claude-outside", cwd: "/work/project"),
            .single("claude-inside", cwd: "/work/secret/app"),
        ])
        codex.setUnits([.single("codex-one", cwd: "/work/project")])

        let factory = FactoryLog()
        let sources: [any AgentHistorySource] = [claude, codex]
        let controller = AgentHistoryController(
            launchDelay: 0,
            makeSources: { sources },
            makeIndexer: { storage, stateStore, configuration, callbacks in
                let indexer = AgentHistoryIndexer(
                    storage: storage,
                    stateStore: stateStore,
                    makeSources: { sources },
                    configuration: configuration,
                    systemConditions: FakeSystemConditions(),
                    onStatusChange: callbacks.onStatusChange,
                    onSnapshotChange: callbacks.onSnapshotChange
                )
                factory.record(indexer, configuration)
                return indexer
            }
        )
        let configStore = AppConfigStore(fileURL: base.appendingPathComponent("config.toml", isDirectory: false))
        controller.configure(configStore: configStore, paths: paths)
        addTeardownBlock { @MainActor in
            controller.stop()
            try? FileManager.default.removeItem(at: base)
        }
        return Fixture(controller: controller, paths: paths, configStore: configStore,
                       claude: claude, codex: codex, factory: factory)
    }

    private func writeState(_ paths: AgentHistoryPaths, _ mutate: (inout AgentHistoryState) -> Void) throws {
        try AgentHistoryStateStore(fileURL: paths.stateURL).update(mutate)
    }

    private func persistedState(_ paths: AgentHistoryPaths) -> AgentHistoryState {
        AgentHistoryStateStore(fileURL: paths.stateURL).current
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

    private func waitForSnapshot(
        _ controller: AgentHistoryController,
        _ description: String,
        where predicate: @escaping (Set<String>) -> Bool
    ) {
        let ids = { (snapshot: AgentHistoryMetadataSnapshot) in Set(snapshot.sessions.map(\.nativeID)) }
        if predicate(ids(controller.metadataSnapshot)) {
            return
        }
        let reached = expectation(description: description)
        var fulfilled = false
        let id = controller.addSnapshotObserver { snapshot in
            if !fulfilled, predicate(ids(snapshot)) {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: 10)
        controller.removeObserver(id)
    }

    private static let allSessions: Set<String> = ["claude-outside", "claude-inside", "codex-one"]

    // MARK: - Launch

    func test_does_not_start_when_disabled_or_not_consented() throws {
        let fresh = makeFixture()
        XCTAssertFalse(launch(fresh.controller), "no state file")

        let notConsented = makeFixture()
        try writeState(notConsented.paths) { $0.enabled = true }
        XCTAssertFalse(launch(notConsented.controller), "enabled without consent")

        let turnedOff = makeFixture()
        try writeState(turnedOff.paths) { $0.enabled = false; $0.consentedAt = Date() }
        XCTAssertFalse(launch(turnedOff.controller), "consented but off")

        let noAgents = makeFixture()
        try writeState(noAgents.paths) { state in
            state.enabled = true
            state.consentedAt = Date()
            AgentHistoryAgent.allCases.forEach { state.setSource($0, enabled: false) }
        }
        XCTAssertFalse(launch(noAgents.controller), "every agent off")

        for fixture in [fresh, notConsented, turnedOff, noAgents] {
            XCTAssertEqual(fixture.factory.count, 0)
            XCTAssertEqual(fixture.controller.status.state, .off)
            XCTAssertNil(fixture.controller.storage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path))
        }
        XCTAssertTrue(notConsented.controller.status.isEnabled)
        XCTAssertFalse(notConsented.controller.status.hasConsented)
    }

    func test_starts_after_launch_delay_when_enabled() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertEqual(fixture.factory.count, 0, "configure alone never starts the indexer")

        XCTAssertTrue(launch(fixture.controller))

        XCTAssertEqual(fixture.factory.count, 1)
        XCTAssertEqual(fixture.factory.lastConfiguration?.enabledAgents, Set(AgentHistoryAgent.allCases))
        XCTAssertNotNil(fixture.controller.storage)
        waitForSnapshot(fixture.controller, "sessions indexed") { $0 == Self.allSessions }
        waitForStatus(fixture.controller, "watching") { $0.state == .watching }
        XCTAssertEqual(fixture.controller.threadSafeStatus, fixture.controller.status)
        XCTAssertEqual(Set(fixture.controller.threadSafeSnapshot.sessions.map(\.nativeID)), Self.allSessions)
    }

    func test_enable_starts_immediately_and_stamps_consent() throws {
        let fixture = makeFixture()
        XCTAssertFalse(launch(fixture.controller))

        fixture.controller.enable(agents: [.claude])

        waitForStatus(fixture.controller, "running with consent") { $0.hasConsented && $0.state != .off }
        XCTAssertEqual(fixture.factory.count, 1)
        XCTAssertEqual(fixture.factory.lastConfiguration?.enabledAgents, [.claude])
        let state = persistedState(fixture.paths)
        XCTAssertTrue(state.enabled)
        XCTAssertNotNil(state.consentedAt)
        XCTAssertTrue(state.isSourceEnabled(.claude))
        XCTAssertFalse(state.isSourceEnabled(.codex))
        waitForSnapshot(fixture.controller, "claude only") { $0 == ["claude-outside", "claude-inside"] }
    }

    /// Settings opened before the launch read: a refresh reads the saved consent for the
    /// status but starts nothing (the launch delay still decides that).
    func test_refresh_before_launch_reads_saved_consent_without_starting() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertFalse(fixture.controller.status.isStateLoaded)

        fixture.controller.refreshStatus()

        waitForStatus(fixture.controller, "state read") { $0.isStateLoaded }
        XCTAssertTrue(fixture.controller.status.hasConsented)
        XCTAssertTrue(fixture.controller.status.isEnabled)
        XCTAssertEqual(fixture.controller.status.state, .off)
        XCTAssertEqual(fixture.factory.count, 0)
    }

    /// A caller that saw the placeholder status (before the launch read) asks for consent
    /// again; the saved per-agent choices and the consent date win.
    func test_enable_over_saved_consent_keeps_the_saved_agent_choices() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { state in
            state.enabled = false
            state.consentedAt = Date(timeIntervalSince1970: 1_700_000_000)
            state.setSource(.codex, enabled: false)
        }
        XCTAssertFalse(fixture.controller.status.hasConsented, "not read yet")

        fixture.controller.enable(agents: Set(AgentHistoryAgent.allCases))

        waitForStatus(fixture.controller, "running") { $0.isEnabled && $0.state != .off }
        let state = persistedState(fixture.paths)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.consentedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
        XCTAssertFalse(state.isSourceEnabled(.codex), "a purged agent stays off")
        XCTAssertTrue(state.isSourceEnabled(.claude))
        XCTAssertEqual(fixture.factory.lastConfiguration?.enabledAgents.contains(.codex), false)
    }

    // MARK: - Config

    func test_config_change_pushes_excluded_folders_and_mirrors_flags() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForSnapshot(fixture.controller, "all indexed") { $0 == Self.allSessions }
        XCTAssertFalse(fixture.controller.allowsAgentsAllProjects)
        XCTAssertFalse(fixture.controller.exclusions.excludes("/work/secret/app"))

        try fixture.configStore.update { config in
            config.agentHistory.excludedFolders = ["/work/secret"]
            config.agentHistory.allowAgentsAllProjects = true
        }

        waitForSnapshot(fixture.controller, "excluded session purged") { !$0.contains("claude-inside") }
        XCTAssertEqual(
            Set(fixture.controller.metadataSnapshot.sessions.map(\.nativeID)),
            ["claude-outside", "codex-one"]
        )
        XCTAssertTrue(fixture.controller.allowsAgentsAllProjects)
        XCTAssertTrue(fixture.controller.exclusions.excludes("/work/secret/app"))
        XCTAssertFalse(fixture.controller.exclusions.excludes("/work/project"))
    }

    // MARK: - Disable

    func test_disable_with_delete_removes_directory_and_consent() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "watching") { $0.state == .watching }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path))

        let done = expectation(description: "disabled")
        var outcome: AgentHistoryDisableOutcome?
        fixture.controller.disable(deleteIndex: true) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.directoryURL.path))
        XCTAssertEqual(fixture.controller.status.state, .off)
        XCTAssertFalse(fixture.controller.status.isEnabled)
        XCTAssertFalse(fixture.controller.status.hasConsented)
        XCTAssertTrue(fixture.controller.metadataSnapshot.sessions.isEmpty)
        XCTAssertNil(fixture.controller.storage)
        let state = persistedState(fixture.paths)
        XCTAssertNil(state.consentedAt)
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.directoryURL.path),
                       "reading the reset state never recreates the directory")
    }

    // MARK: - Off status

    /// Builds an index with one removed session, then turns History off (index kept).
    private func buildIndexAndTurnOff(_ fixture: Fixture) throws {
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForSnapshot(fixture.controller, "all indexed") { $0 == Self.allSessions }
        fixture.controller.removeSession(AgentHistorySessionKey(agent: .codex, nativeID: "codex-one"))
        waitForStatus(fixture.controller, "one removed") { $0.removedSessionCount == 1 }

        fixture.controller.setEnabled(false)
        waitForStatus(fixture.controller, "off") { !$0.isEnabled && $0.state == .off }
        fixture.controller.drainControlQueueForTesting()
    }

    func test_turning_history_off_still_reports_the_kept_index() throws {
        let fixture = makeFixture()
        try buildIndexAndTurnOff(fixture)

        fixture.controller.refreshStatus()
        fixture.controller.drainControlQueueForTesting()
        let recounted = expectation(description: "recount delivered")
        DispatchQueue.main.async { recounted.fulfill() }
        wait(for: [recounted], timeout: 5)

        let status = fixture.controller.status
        XCTAssertTrue(status.indexExists, "Delete Index stays available while History is off")
        XCTAssertGreaterThan(status.indexSizeBytes, 0)
        XCTAssertEqual(status.removedSessionCount, 1)
        XCTAssertTrue(status.hasConsented)
        XCTAssertNil(fixture.controller.storage, "nothing reopened the index")
    }

    /// A launch with History off never starts an indexer, so only the recount can tell the
    /// index is still on disk.
    func test_launch_with_history_off_reports_the_index_on_disk_until_deleted() throws {
        let fixture = makeFixture()
        try buildIndexAndTurnOff(fixture)
        fixture.controller.stop()

        let relaunched = AgentHistoryController(launchDelay: 0, makeSources: { [] })
        relaunched.configure(configStore: fixture.configStore, paths: fixture.paths)
        addTeardownBlock { @MainActor in relaunched.stop() }
        XCTAssertFalse(launch(relaunched))
        waitForStatus(relaunched, "index on disk") { status in
            status.indexExists && status.indexSizeBytes > 0 && status.removedSessionCount == 1
        }
        XCTAssertFalse(relaunched.status.isEnabled)
        XCTAssertTrue(relaunched.status.hasConsented)
        XCTAssertNil(relaunched.indexer)

        let done = expectation(description: "deleted")
        relaunched.disable(deleteIndex: true) { outcome in
            XCTAssertEqual(outcome, .deleted)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        waitForStatus(relaunched, "index gone") { status in
            !status.indexExists && status.indexSizeBytes == 0 && status.removedSessionCount == 0 && !status.hasConsented
        }
    }

    /// Another "process" on the same directory: its own storage (reader pool, lock descriptors)
    /// and indexer, as a second Zentty of the same flavor would have.
    private func startOtherInstance(_ fixture: Fixture) -> AgentHistoryIndexer {
        let sources: [any AgentHistorySource] = [fixture.claude, fixture.codex]
        let other = AgentHistoryIndexer(
            storage: AgentHistoryStorage(paths: fixture.paths),
            stateStore: AgentHistoryStateStore(fileURL: fixture.paths.stateURL),
            makeSources: { sources },
            configuration: AgentHistoryIndexerConfiguration(
                enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: []
            ),
            systemConditions: FakeSystemConditions(),
            onStatusChange: { _ in },
            onSnapshotChange: { _ in }
        )
        other.writerLockWait = 0.05
        other.standbyRetryInterval = 0.1
        addTeardownBlock { other.stop(timeout: 2) }
        other.start()
        return other
    }

    private static func isStandingBy(_ status: AgentHistoryStatus) -> Bool {
        if case .paused(.anotherInstance, _) = status.state { return true }
        return false
    }

    func test_delete_refuses_while_another_instance_owns_the_index() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        let other = startOtherInstance(fixture)
        other.drainSynchronouslyForTesting()
        XCTAssertTrue(other.isWriterOpenForTesting)
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "standing by") { Self.isStandingBy($0) }

        let done = expectation(description: "disable answered")
        var outcome: AgentHistoryDisableOutcome?
        fixture.controller.disable(deleteIndex: true) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .refusedAnotherInstance)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path),
                      "the owner's index is never deleted under it")
        XCTAssertTrue(other.isWriterOpenForTesting)
        XCTAssertNotNil(persistedState(fixture.paths).consentedAt, "a refused delete keeps consent")
        XCTAssertTrue(fixture.controller.status.hasConsented)
    }

    func test_delete_refuses_while_another_instance_stands_by() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "watching") { $0.state == .watching }
        let other = startOtherInstance(fixture)
        other.drainSynchronouslyForTesting()
        XCTAssertTrue(Self.isStandingBy(other.currentStatus))

        let done = expectation(description: "disable answered")
        var outcome: AgentHistoryDisableOutcome?
        fixture.controller.disable(deleteIndex: true) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .refusedAnotherInstance)

        // The standby instance would take over the moment the lock frees and rebuild the index
        // with its own consent, so the delete would not stick.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path))
        XCTAssertNotNil(persistedState(fixture.paths).consentedAt)
        XCTAssertTrue(fixture.controller.status.hasConsented)
    }

    // MARK: - Observers

    func test_status_observers_receive_updates() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        var first: [AgentHistoryStatus] = []
        var second: [AgentHistoryStatus] = []
        let firstID = fixture.controller.addStatusObserver { first.append($0) }
        fixture.controller.addStatusObserver { second.append($0) }

        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "watching") { $0.state == .watching }
        XCTAssertTrue(first.contains { $0.state == .watching })
        XCTAssertTrue(second.contains { $0.state == .watching })
        XCTAssertEqual(first.map(\.revision), first.map(\.revision).sorted(), "revisions only grow")

        fixture.controller.removeObserver(firstID)
        let firstCount = first.count
        fixture.controller.setEnabled(false)
        waitForStatus(fixture.controller, "off") { $0.state == .off && !$0.isEnabled }

        XCTAssertEqual(first.count, firstCount, "a removed observer hears nothing")
        XCTAssertEqual(second.last?.state, .off)
        XCTAssertFalse(second.last?.isEnabled ?? true)
        XCTAssertTrue(second.last?.hasConsented ?? false, "turning off keeps consent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path), "turning off keeps data")
    }

    // MARK: - Per-agent purge

    func test_set_agent_disabled_purges() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForSnapshot(fixture.controller, "all indexed") { $0 == Self.allSessions }

        fixture.controller.setAgentEnabled(.codex, false)

        waitForSnapshot(fixture.controller, "codex purged") { !$0.contains("codex-one") }
        waitForStatus(fixture.controller, "codex off") { !$0.enabledAgents.contains(.codex) }
        XCTAssertFalse(persistedState(fixture.paths).isSourceEnabled(.codex))
        let storage = try XCTUnwrap(fixture.controller.storage)
        let codexRows = try storage.readers.withReader { db in
            try AgentHistoryFixtures.count(db, "SELECT count(*) FROM sessions WHERE native_id = ?", [.text("codex-one")])
        }
        XCTAssertEqual(codexRows, 0)
        XCTAssertTrue(fixture.controller.status.sources.allSatisfy { $0.agent != .codex })
    }

    private func storedNativeIDs(_ paths: AgentHistoryPaths) throws -> Set<String> {
        let db = try AgentHistoryDatabase(url: paths.databaseURL, mode: .readOnly, busyTimeoutMilliseconds: 2_000)
        defer { db.close() }
        return Set(try db.query("SELECT native_id FROM sessions") { $0.string(0) })
    }

    func test_turning_off_the_last_agent_purges_it_before_stopping() throws {
        let fixture = makeFixture()
        XCTAssertFalse(launch(fixture.controller))
        fixture.controller.enable(agents: [.claude])
        waitForSnapshot(fixture.controller, "claude indexed") { $0 == ["claude-outside", "claude-inside"] }

        fixture.controller.setAgentEnabled(.claude, false)
        waitForStatus(fixture.controller, "off without agents") { $0.state == .off && $0.enabledAgents.isEmpty }
        fixture.controller.drainControlQueueForTesting()

        XCTAssertNil(fixture.controller.storage)
        XCTAssertEqual(try storedNativeIDs(fixture.paths), [], "turning the agent off purged its rows (D4)")
    }

    func test_turning_an_agent_off_while_history_is_off_purges_it() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForSnapshot(fixture.controller, "all indexed") { $0 == Self.allSessions }
        fixture.controller.setEnabled(false)
        waitForStatus(fixture.controller, "off") { $0.state == .off && !$0.isEnabled }

        fixture.controller.setAgentEnabled(.codex, false)
        waitForStatus(fixture.controller, "codex off") { !$0.enabledAgents.contains(.codex) }
        fixture.controller.drainControlQueueForTesting()

        XCTAssertEqual(try storedNativeIDs(fixture.paths), ["claude-outside", "claude-inside"])
        XCTAssertEqual(fixture.factory.count, 1, "no indexer was started for the purge")
    }

    func test_turning_history_off_and_on_starts_the_new_indexer_after_the_old_one_stopped() throws {
        let fixture = makeFixture()
        try writeState(fixture.paths) { $0.enabled = true; $0.consentedAt = Date() }
        XCTAssertTrue(launch(fixture.controller))
        waitForStatus(fixture.controller, "watching") { $0.state == .watching }
        let first = try XCTUnwrap(fixture.factory.last)

        // The old indexer is stuck in a batch longer than the writer-lock wait and ignores
        // cancellation meanwhile.
        let entered = expectation(description: "slow batch entered")
        let blocked = Flag()
        fixture.claude.setIngestHook { unitKey, _, _ in
            guard unitKey == "claude-slow", !blocked.value else {
                return
            }
            blocked.value = true
            entered.fulfill()
            Thread.sleep(forTimeInterval: 2.5)
            throw CancellationError()
        }
        fixture.claude.setUnits([.single("claude-slow", mtimeNs: 9)])
        first.requestReconcile()
        wait(for: [entered], timeout: 5)

        var seen: [AgentHistoryIndexerState] = []
        let observer = fixture.controller.addStatusObserver { seen.append($0.state) }
        fixture.controller.setEnabled(false)
        fixture.controller.setEnabled(true)
        waitForStatus(fixture.controller, "second indexer watching") { [factory = fixture.factory] status in
            factory.count == 2 && status.state == .watching
        }
        fixture.controller.removeObserver(observer)

        XCTAssertFalse(seen.contains { state in
            if case .paused(.anotherInstance, _) = state { return true }
            return false
        }, "the new indexer never found the old one still owning the index")
        XCTAssertFalse(first.isWriterOpenForTesting)
        XCTAssertTrue(try XCTUnwrap(fixture.factory.last).isWriterOpenForTesting)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
