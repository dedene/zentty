import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreAgentForkTests: XCTestCase {
    private let worklaneID = WorklaneID("main")
    private let sourcePaneID = PaneID("source")
    private let sessionID = "5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"
    private let forkCommand = "claude --resume 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44 --fork-session"

    func test_fork_split_right_inserts_column_after_source_running_fork_command() throws {
        let store = makeStore()

        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].panes.map(\.id), [sourcePaneID])
        let forkedPane = try XCTUnwrap(columns[1].panes.first)
        XCTAssertEqual(forkedPane.id, result.paneID)
        XCTAssertEqual(result.worklaneID, worklaneID)
        XCTAssertEqual(forkedPane.sessionRequest.command, forkCommand)
        XCTAssertEqual(forkedPane.sessionRequest.workingDirectory, "/tmp/project")
        XCTAssertNil(forkedPane.customTitle)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, result.paneID)
    }

    func test_fork_split_down_inserts_pane_below_source_in_same_column() throws {
        let store = makeStore()

        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitDown)

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].panes.map(\.id), [sourcePaneID, result.paneID])
        XCTAssertEqual(columns[0].panes[1].sessionRequest.command, forkCommand)
    }

    func test_fork_new_worklane_creates_and_selects_lane_with_fork_pane() throws {
        let store = makeStore()

        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .newWorklane)

        XCTAssertEqual(store.worklanes.count, 2)
        XCTAssertNotEqual(result.worklaneID, worklaneID)
        XCTAssertEqual(store.activeWorklaneID, result.worklaneID)
        let pane = try XCTUnwrap(store.activeWorklane?.paneStripState.panes.first)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(pane.id, result.paneID)
        XCTAssertEqual(pane.sessionRequest.command, forkCommand)
        XCTAssertFalse(pane.sessionRequest.replaysCommandOnRestore)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp/project")
        XCTAssertEqual(
            store.worklanes.first(where: { $0.id == worklaneID })?.paneStripState.panes.map(\.id),
            [sourcePaneID]
        )
    }

    func test_restoring_closed_fork_pane_without_session_does_not_fork_again() throws {
        let store = makeStore()
        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)

        _ = store.closePane(id: result.paneID)
        let restore = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(
            store.activeWorklane?.paneStripState.panes.first { $0.id == restore.restoredPaneID }
        )
        XCTAssertNil(restored.sessionRequest.command)
        XCTAssertFalse(restored.sessionRequest.prefillText?.contains("--fork-session") ?? false)
    }

    func test_restoring_closed_fork_pane_resumes_the_forks_own_session() throws {
        let store = makeStore()
        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)
        let forkSessionID = "0c6a3a1e-9a1f-4d0e-8f43-2c1b7d5e9a10"
        let worklaneIndex = try XCTUnwrap(store.worklanes.firstIndex { $0.id == worklaneID })
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[result.paneID, default: PaneAuxiliaryState()].agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            workingDirectory: "/tmp/project",
            sessionID: forkSessionID
        )

        _ = store.closePane(id: result.paneID)
        let restore = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(
            store.activeWorklane?.paneStripState.panes.first { $0.id == restore.restoredPaneID }
        )
        let prefill = try XCTUnwrap(restored.sessionRequest.prefillText)
        XCTAssertTrue(prefill.contains("claude --resume \(forkSessionID)"))
        XCTAssertFalse(prefill.contains("--fork-session"))
    }

    func test_fork_carries_custom_title_with_fork_suffix() throws {
        let store = makeStore(customTitle: "API work")

        let result = try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)

        let pane = try XCTUnwrap(store.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID })
        XCTAssertEqual(pane.customTitle, "API work (fork)")
    }

    func test_fork_of_unforkable_agent_throws_reason_and_leaves_layout() {
        let store = makeStore(tool: .copilot)

        XCTAssertThrowsError(try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)) { error in
            XCTAssertEqual(error as? WorklaneStore.AgentForkError, .unavailable("Copilot can't fork a conversation."))
            XCTAssertEqual(error.localizedDescription, "Copilot can't fork a conversation.")
        }
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
    }

    func test_fork_without_agent_throws_no_agent_reason() {
        let store = makeStore(includeAgent: false)

        XCTAssertNil(store.agentForkAvailability(for: sourcePaneID))
        XCTAssertThrowsError(try store.forkAgentConversation(paneID: sourcePaneID, destination: .splitRight)) { error in
            XCTAssertEqual(error.localizedDescription, AgentForkCommandBuilder.noAgentReason)
        }
    }

    func test_fork_of_unknown_pane_throws_pane_not_found() {
        let store = makeStore()

        XCTAssertThrowsError(try store.forkAgentConversation(paneID: PaneID("missing"), destination: .splitRight)) { error in
            XCTAssertEqual(error as? WorklaneStore.AgentForkError, .paneNotFound)
        }
    }

    func test_availability_reflects_source_pane_agent() {
        let store = makeStore()

        XCTAssertEqual(store.agentForkAvailability(for: sourcePaneID)?.plan?.command, forkCommand)
    }

    // MARK: - Helpers

    private func makeStore(
        tool: AgentTool = .claudeCode,
        includeAgent: Bool = true,
        customTitle: String? = nil
    ) -> WorklaneStore {
        let agentStatus = includeAgent
            ? PaneAgentStatus(
                tool: tool,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                workingDirectory: "/tmp/project",
                sessionID: sessionID
            )
            : nil
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: sourcePaneID,
                                title: "agent",
                                customTitle: customTitle,
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                                width: 420
                            ),
                        ],
                        focusedPaneID: sourcePaneID
                    ),
                    nextPaneNumber: 2,
                    auxiliaryStateByPaneID: [
                        sourcePaneID: PaneAuxiliaryState(
                            shellContext: PaneShellContext(
                                scope: .local,
                                path: "/tmp/project",
                                home: "/Users/peter",
                                user: "peter",
                                host: nil
                            ),
                            agentStatus: agentStatus
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        return store
    }
}
