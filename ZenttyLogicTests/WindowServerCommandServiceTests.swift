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

    // MARK: - Helpers

    private func makeService(store: WorklaneStore) -> WindowServerCommandService {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowServerCommandServiceTests-\(UUID().uuidString).toml")
        addTeardownBlock { try? FileManager.default.removeItem(at: configURL) }
        return WindowServerCommandService(
            worklaneStore: store,
            configStore: AppConfigStore(fileURL: configURL),
            serverOpenService: ServerOpenService(),
            serverListenerScanner: ServerListenerScanner(),
            dockerServerDiscovery: DockerServerDiscovery()
        )
    }

    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore()
        store.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneA, title: "server")],
                    focusedPaneID: paneA
                )
            )
        ], activeWorklaneID: worklaneID)
        return store
    }
}
