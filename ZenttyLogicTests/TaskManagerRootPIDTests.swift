import XCTest
@testable import Zentty

@MainActor
final class TaskManagerRootPIDTests: XCTestCase {
    func test_pane_root_pid_signal_parses_without_agent_tool() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "agent-signal",
                "pane-root-pid",
                "attach",
                "4242",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneRootPID)
        XCTAssertEqual(command.payload.pidEvent, .attach)
        XCTAssertEqual(command.payload.pid, 4242)
        XCTAssertNil(command.payload.toolName)
    }

    func test_pane_root_pid_signal_updates_pane_state_without_agent_status() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneRootPID,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let auxiliaryState = store.activeWorklane?.auxiliaryStateByPaneID[paneID]
        XCTAssertEqual(auxiliaryState?.raw.paneRootPID, 4242)
        XCTAssertNil(auxiliaryState?.agentStatus)
    }

    func test_closing_pane_clears_root_pid_state() throws {
        let store = WorklaneStore()
        store.send(.splitHorizontally)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneRootPID,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.closePane(id: paneID), .closed)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
    }
}
