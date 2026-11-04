import XCTest
@testable import Zentty

/// Copilot hook sequences driven through the real adapter into the store, so
/// ordering, OSC activity and subagent traffic are covered end to end (#168).
@MainActor
final class CopilotAgentStatusFlowTests: XCTestCase {
    private let sessionID = "ffed296c-1964-4fc6-b831-efd206b7399f"

    func test_permission_prompt_resolves_through_post_tool_use_and_ends_at_agent_stop() throws {
        let (store, paneID) = try makeStore()

        try send(.userPromptSubmitted, to: store, paneID: paneID)
        XCTAssertEqual(status(store, paneID)?.state, .running)

        try send(.permissionPrompt, to: store, paneID: paneID)
        XCTAssertEqual(status(store, paneID)?.state, .needsInput)
        XCTAssertEqual(status(store, paneID)?.interactionKind, .approval)
        XCTAssertEqual(presentation(store, paneID)?.statusText, "Requires approval")

        try send(.postToolUse(agentID: nil), to: store, paneID: paneID)
        XCTAssertEqual(status(store, paneID)?.state, .running)
        XCTAssertEqual(presentation(store, paneID)?.statusText, "Running")

        try send(.agentStop, to: store, paneID: paneID)
        XCTAssertEqual(status(store, paneID)?.state, .idle)
    }

    func test_terminal_progress_does_not_clear_unanswered_permission_prompt() throws {
        let (store, paneID) = try makeStore()
        try send(.userPromptSubmitted, to: store, paneID: paneID)
        try send(.permissionPrompt, to: store, paneID: paneID)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        XCTAssertEqual(status(store, paneID)?.state, .needsInput)
        XCTAssertEqual(status(store, paneID)?.interactionKind, .approval)
        XCTAssertEqual(presentation(store, paneID)?.statusText, "Requires approval")
    }

    func test_subagent_tool_activity_after_agent_stop_keeps_session_idle() throws {
        let (store, paneID) = try makeStore()
        try send(.userPromptSubmitted, to: store, paneID: paneID)
        try send(.agentStop, to: store, paneID: paneID)

        try send(.postToolUse(agentID: "background-explore-1"), to: store, paneID: paneID)

        XCTAssertEqual(status(store, paneID)?.state, .idle)
    }

    func test_subagent_tool_activity_resolves_subagent_permission_prompt() throws {
        let (store, paneID) = try makeStore()
        try send(.userPromptSubmitted, to: store, paneID: paneID)
        try send(.permissionPrompt, to: store, paneID: paneID)

        try send(.postToolUse(agentID: "task-agent-1"), to: store, paneID: paneID)

        XCTAssertEqual(status(store, paneID)?.state, .running)
    }

    func test_late_permission_notification_after_agent_stop_is_dropped() throws {
        let (store, paneID) = try makeStore()
        try send(.userPromptSubmitted, to: store, paneID: paneID)
        try send(.postToolUse(agentID: nil), to: store, paneID: paneID)
        try send(.agentStop, to: store, paneID: paneID)

        // Fire-and-forget notification hook that lost the race to agentStop.
        try send(.permissionPrompt, to: store, paneID: paneID)

        XCTAssertEqual(status(store, paneID)?.state, .idle)
    }

    func test_new_prompt_after_agent_stop_runs_again() throws {
        let (store, paneID) = try makeStore()
        try send(.userPromptSubmitted, to: store, paneID: paneID)
        try send(.agentStop, to: store, paneID: paneID)

        try send(.userPromptSubmitted, to: store, paneID: paneID)

        XCTAssertEqual(status(store, paneID)?.state, .running)
    }

    // MARK: - Helpers

    private enum HookEvent {
        case userPromptSubmitted
        case permissionPrompt
        case postToolUse(agentID: String?)
        case agentStop

        var name: String {
            switch self {
            case .userPromptSubmitted: return "user-prompt-submitted"
            case .permissionPrompt: return "notification"
            case .postToolUse: return "post-tool-use"
            case .agentStop: return "agent-stop"
            }
        }

        func body(sessionID: String) -> [String: Any] {
            var body: [String: Any] = ["sessionId": sessionID, "cwd": "/tmp/project", "timestamp": 1_793_451_019_796]
            switch self {
            case .userPromptSubmitted:
                body["prompt"] = "clean the build folder"
            case .permissionPrompt:
                body["hook_event_name"] = "Notification"
                body["notification_type"] = "permission_prompt"
                body["message"] = "Copilot wants to run: rm -rf build"
            case .postToolUse(let agentID):
                body["toolName"] = "bash"
                body["toolArgs"] = #"{"command":"rm -rf build"}"#
                if let agentID {
                    body["agentId"] = agentID
                    body["agentType"] = "explore"
                }
            case .agentStop:
                body["stopReason"] = "end_turn"
                body["stop_hook_active"] = false
            }
            return body
        }
    }

    private func makeStore() throws -> (WorklaneStore, PaneID) {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        return (store, paneID)
    }

    private func send(_ event: HookEvent, to store: WorklaneStore, paneID: PaneID) throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: JSONSerialization.data(withJSONObject: event.body(sessionID: sessionID)),
            defaultEventName: event.name,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": paneID.rawValue,
            ]
        )
        XCTAssertFalse(payloads.isEmpty, "Expected payloads for \(event.name)")
        for payload in payloads {
            store.applyAgentStatusPayload(payload)
        }
    }

    private func status(_ store: WorklaneStore, _ paneID: PaneID) -> PaneAgentStatus? {
        store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus
    }

    private func presentation(_ store: WorklaneStore, _ paneID: PaneID) -> PanePresentationState? {
        store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation
    }
}
