import XCTest
@testable import Zentty

final class AgentIPCDiscoveryTests: XCTestCase {
    func test_agent_ipc_request_round_trips_discover_payload() throws {
        let request = AgentIPCRequest(
            id: "discover-1",
            kind: .discover,
            arguments: ["--window-id", "window-main"],
            standardInput: nil,
            environment: [:],
            expectsResponse: true,
            subcommand: "panes"
        )

        let decoded = try JSONDecoder().decode(
            AgentIPCRequest.self,
            from: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func test_agent_ipc_response_round_trips_discovery_payloads() throws {
        let response = AgentIPCResponse(
            id: "discover-1",
            ok: true,
            result: AgentIPCResponseResult(
                discoveredWindows: [
                    DiscoveredWindow(
                        id: "wd_main",
                        order: 1,
                        isFocused: true,
                        worklaneCount: 2,
                        paneCount: 4
                    ),
                ],
                discoveredWorklanes: [
                    DiscoveredWorklane(
                        id: "wl_main",
                        windowID: "wd_main",
                        order: 1,
                        title: nil,
                        isFocused: true,
                        paneCount: 2,
                        columnCount: 1,
                        focusedPaneID: "pn_main"
                    ),
                ],
                discoveredPanes: [
                    DiscoveredPane(
                        id: "pn_main",
                        windowID: "wd_main",
                        worklaneID: "wl_main",
                        index: 1,
                        column: 1,
                        title: "shell",
                        workingDirectory: "/tmp/project",
                        isFocused: true,
                        agentTool: "Codex",
                        agentStatus: "running",
                        controlToken: "pane-token"
                    ),
                ]
            )
        )

        let decoded = try JSONDecoder().decode(
            AgentIPCResponse.self,
            from: try JSONEncoder().encode(response)
        )

        XCTAssertEqual(decoded, response)
    }

    func test_agent_ipc_authentication_accepts_discovered_pane_token() {
        let authentication = AgentIPCAuthentication(secret: "unit-test-secret")
        let target = AgentIPCTarget(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main")
        )

        let token = authentication.token(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID
        )

        XCTAssertTrue(authentication.isValid(
            token: token,
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID
        ))
        XCTAssertFalse(authentication.isValid(
            token: token,
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: PaneID("pane-other")
        ))
    }
}
