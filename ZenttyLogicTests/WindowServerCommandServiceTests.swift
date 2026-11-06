import XCTest
@testable import Zentty

@MainActor
final class WindowServerCommandServiceTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-main")
    private let paneA = PaneID("pane-a")

    // MARK: - register / list round-trip

    func test_set_then_list_round_trips_registered_server() throws {
        let store = makeStore()
        let service = makeService(store: store)
        let target = AgentIPCTarget(windowID: nil, worklaneID: worklaneID, paneID: paneA)

        let setResponse = try service.handle(
            .set(rawURL: "http://localhost:3000", pid: nil, json: false),
            target: target
        )
        let setState = try XCTUnwrap(setResponse.serverState)
        XCTAssertEqual(setState.version, 2)
        XCTAssertEqual(setState.servers.count, 1)
        XCTAssertEqual(setState.servers.first?.source, "manual")
        XCTAssertEqual(setState.primaryServerID, setState.servers.first?.id)

        let listResponse = try service.handle(.list(json: false), target: target)
        let listState = try XCTUnwrap(listResponse.serverState)
        XCTAssertEqual(listState.servers.count, 1)
        XCTAssertEqual(listState.servers.first?.id, setState.servers.first?.id)
        XCTAssertTrue(listState.servers.first?.origin.contains("3000") == true)
    }

    // MARK: - wire strings

    func test_tier_wire_strings() {
        XCTAssertEqual(WindowServerCommandService.tierString(.primary), "primary")
        XCTAssertEqual(WindowServerCommandService.tierString(.shown), "shown")
        XCTAssertEqual(WindowServerCommandService.tierString(.hidden), "hidden")
    }

    func test_reason_wire_strings() {
        XCTAssertEqual(WindowServerCommandService.reasonString(.sessionSelected), "session_selected")
        XCTAssertEqual(WindowServerCommandService.reasonString(.ignoredPort(9229)), "ignored_port:9229")
        XCTAssertEqual(WindowServerCommandService.reasonString(.manual), "manual")
        XCTAssertEqual(WindowServerCommandService.reasonString(.runningPane), "running_pane")
        XCTAssertEqual(WindowServerCommandService.reasonString(.focusedPane), "focused_pane")
        XCTAssertEqual(WindowServerCommandService.reasonString(.source(.docker)), "source:docker")
        XCTAssertEqual(WindowServerCommandService.reasonString(.confidence(.pid)), "confidence:pid")
        XCTAssertEqual(WindowServerCommandService.reasonString(.fresh), "fresh")
    }

    func test_date_wire_string_is_iso8601() {
        XCTAssertEqual(
            WindowServerCommandService.formatServerDate(Date(timeIntervalSince1970: 0)),
            "1970-01-01T00:00:00Z"
        )
    }

    // MARK: - kill not-owned no-op

    func test_kill_not_owned_source_is_noop() throws {
        let store = makeStore()
        let service = makeService(store: store)
        let target = AgentIPCTarget(windowID: nil, worklaneID: worklaneID, paneID: paneA)

        // A `.manual` server is never scanner-owned, so the terminator returns
        // `.notOwned` and killServer must leave the registration untouched.
        _ = try service.handle(.set(rawURL: "http://localhost:3000", pid: nil, json: false), target: target)
        let server = try XCTUnwrap(store.activeServerContext.servers.first)
        XCTAssertEqual(server.source, .manual)

        service.killServer(server)

        XCTAssertEqual(store.activeServerContext.servers.map(\.id), [server.id])
    }

    // MARK: - Passive detection scheduling

    func test_unchanged_snapshot_does_not_restart_passive_detection() async throws {
        let inspector = RecordingProcessInspector()
        let store = makeStore(workingDirectory: "/tmp/passive-project")
        let service = makeService(store: store, processInspector: inspector)
        addTeardownBlock { @MainActor in service.cancelPassiveDetection() }

        // Each call lands well inside the 750ms start delay of the one before.
        for _ in 0..<40 where inspector.scanCount == 0 {
            service.schedulePassiveServerDetectionRefresh()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThan(inspector.scanCount, 0, "Repeated identical schedules must not starve the scan")
    }

    func test_changed_context_restarts_passive_detection() async throws {
        let inspector = RecordingProcessInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            cwdByPID: [300: "/Volumes/passive-new"]
        )
        let store = makeStore(workingDirectory: "/Volumes/passive-old")
        let service = makeService(store: store, processInspector: inspector)
        addTeardownBlock { @MainActor in service.cancelPassiveDetection() }

        service.schedulePassiveServerDetectionRefresh()
        replaceWorklanes(in: store, workingDirectory: "/Volumes/passive-new")
        service.schedulePassiveServerDetectionRefresh()

        await waitUntil { !store.activeServerContext.servers.isEmpty }
        XCTAssertEqual(store.activeServerContext.servers.map(\.origin), ["http://localhost:5173"])
    }

    func test_finished_one_shot_scan_lets_a_later_refresh_scan_again() async throws {
        let inspector = RecordingProcessInspector()
        let store = makeStore(workingDirectory: "/tmp/passive-project")
        let service = makeService(store: store, processInspector: inspector)
        addTeardownBlock { @MainActor in service.cancelPassiveDetection() }

        service.schedulePassiveServerDetectionRefresh()
        await waitUntil { inspector.scanCount == 1 && !service.isPassiveDetectionLoopActiveForTesting }
        XCTAssertEqual(inspector.scanCount, 1)

        service.schedulePassiveServerDetectionRefresh()
        await waitUntil { inspector.scanCount == 2 }

        XCTAssertEqual(inspector.scanCount, 2)
    }

    func test_reenabling_detection_after_disabling_it_scans_again() async throws {
        let inspector = RecordingProcessInspector()
        let store = makeStore(workingDirectory: "/tmp/passive-project")
        let (service, configStore) = makeServiceAndConfig(store: store, processInspector: inspector)
        addTeardownBlock { @MainActor in service.cancelPassiveDetection() }

        service.schedulePassiveServerDetectionRefresh()
        try configStore.update { $0.serverDetection.passiveDetectionEnabled = false }
        service.schedulePassiveServerDetectionRefresh()
        try configStore.update { $0.serverDetection.passiveDetectionEnabled = true }
        service.schedulePassiveServerDetectionRefresh()

        await waitUntil { inspector.scanCount > 0 }
        XCTAssertGreaterThan(inspector.scanCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Helpers

    private func makeService(
        store: WorklaneStore,
        processInspector: (any ProcessInspecting)? = nil
    ) -> WindowServerCommandService {
        makeServiceAndConfig(store: store, processInspector: processInspector).service
    }

    private func makeServiceAndConfig(
        store: WorklaneStore,
        processInspector: (any ProcessInspecting)?
    ) -> (service: WindowServerCommandService, config: AppConfigStore) {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowServerCommandServiceTests-\(UUID().uuidString).toml")
        addTeardownBlock { try? FileManager.default.removeItem(at: configURL) }
        let config = AppConfigStore(fileURL: configURL)
        let service = WindowServerCommandService(
            worklaneStore: store,
            configStore: config,
            serverOpenService: ServerOpenService(),
            serverListenerScanner: processInspector.map { ServerListenerScanner(processInspector: $0) }
                ?? ServerListenerScanner(),
            dockerServerDiscovery: DockerServerDiscovery(),
            dockerContainerPoller: DockerContainerPoller(inspector: NoDockerInspector())
        )
        return (service, config)
    }

    private func makeStore(workingDirectory: String? = nil) -> WorklaneStore {
        let store = WorklaneStore()
        replaceWorklanes(in: store, workingDirectory: workingDirectory)
        return store
    }

    private func replaceWorklanes(in store: WorklaneStore, workingDirectory: String?) {
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        if let workingDirectory {
            auxiliaryStateByPaneID[paneA] = PaneAuxiliaryState(
                shellContext: PaneShellContext(
                    scope: .local,
                    path: workingDirectory,
                    home: "/Users/peter",
                    user: "peter",
                    host: nil
                ),
                gitContext: PaneGitContext(
                    workingDirectory: workingDirectory,
                    repositoryRoot: workingDirectory,
                    reference: .branch("main")
                )
            )
        }
        store.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneA, title: "server")],
                    focusedPaneID: paneA
                ),
                auxiliaryStateByPaneID: auxiliaryStateByPaneID
            )
        ], activeWorklaneID: worklaneID)
    }
}

private final class RecordingProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let sockets: [ListeningSocket]
    private let cwdByPID: [pid_t: String]
    private var _scanCount = 0

    init(sockets: [ListeningSocket] = [], cwdByPID: [pid_t: String] = [:]) {
        self.sockets = sockets
        self.cwdByPID = cwdByPID
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _scanCount
    }

    func listeningTCPSockets() -> [ListeningSocket] {
        lock.lock()
        defer { lock.unlock() }
        _scanCount += 1
        return sockets
    }

    func parentPID(of pid: pid_t) -> pid_t? { nil }
    func workingDirectory(of pid: pid_t) -> String? { cwdByPID[pid] }
    func isProcessAlive(_ pid: pid_t) -> Bool { cwdByPID[pid] != nil }
}

private struct NoDockerInspector: DockerInspecting {
    func hasDockerSocket() -> Bool { false }
    func runningContainers() throws -> [DockerContainer] { [] }
}
