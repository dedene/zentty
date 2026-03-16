import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentStatusSupportTests: XCTestCase {
    func test_agent_status_command_uses_env_defaults_and_round_trips_notification_payload() throws {
        let command = try AgentStatusCommand.parse(
            arguments: [
                "zentty-agent",
                "needs-input",
                "--tool", "Claude Code",
                "--text", "Claude is waiting for your input",
                "--artifact-kind", "pull-request",
                "--artifact-label", "PR #42",
                "--artifact-url", "https://example.com/pr/42",
            ],
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.workspaceID, WorkspaceID("workspace-main"))
        XCTAssertEqual(command.payload.paneID, PaneID("workspace-main-shell"))
        XCTAssertEqual(command.payload.state, .needsInput)
        XCTAssertEqual(command.payload.toolName, "Claude Code")
        XCTAssertEqual(command.payload.text, "Claude is waiting for your input")
        XCTAssertEqual(command.payload.artifactKind, .pullRequest)

        let userInfo = try XCTUnwrap(command.payload.notificationUserInfo)
        let decodedPayload = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decodedPayload, command.payload)
    }

    func test_notification_coordinator_fires_once_per_attention_state_entry() {
        let recorder = WorkspaceAttentionNotificationRecorder()
        let coordinator = WorkspaceAttentionNotificationCoordinator(center: recorder)
        let paneID = PaneID("workspace-main-shell")
        let workspaceID = WorkspaceID("workspace-main")

        let needsInputWorkspace = WorkspaceState(
            id: workspaceID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .needsInput,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        coordinator.update(
            workspaces: [needsInputWorkspace],
            activeWorkspaceID: workspaceID,
            windowIsKey: false
        )
        coordinator.update(
            workspaces: [needsInputWorkspace],
            activeWorkspaceID: workspaceID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)

        let clearedWorkspace = WorkspaceState(
            id: workspaceID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )
        coordinator.update(
            workspaces: [clearedWorkspace],
            activeWorkspaceID: workspaceID,
            windowIsKey: false
        )
        coordinator.update(
            workspaces: [needsInputWorkspace],
            activeWorkspaceID: workspaceID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 2)
    }

    func test_claude_hook_notification_maps_to_needs_input_payload() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","message":"Claude is waiting for your input"}
            """.utf8)
        )

        let payload = try ClaudeHookBridge.makePayload(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(
            payload,
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
                paneID: PaneID("workspace-main-shell"),
                state: .needsInput,
                toolName: "Claude Code",
                text: "Claude is waiting for your input",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    func test_claude_hook_prompt_submit_maps_to_running_payload() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"UserPromptSubmit"}
            """.utf8)
        )

        let payload = try ClaudeHookBridge.makePayload(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(payload?.state, .running)
        XCTAssertEqual(payload?.toolName, "Claude Code")
    }

    func test_claude_hook_stop_maps_to_completed_payload() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Stop"}
            """.utf8)
        )

        let payload = try ClaudeHookBridge.makePayload(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(payload?.state, .completed)
        XCTAssertEqual(payload?.toolName, "Claude Code")
    }

    func test_claude_hook_ignores_unknown_events() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"PostToolUse","message":"tool finished"}
            """.utf8)
        )

        let payload = try ClaudeHookBridge.makePayload(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertNil(payload)
    }
}

private final class WorkspaceAttentionNotificationRecorder: WorkspaceAttentionUserNotificationCenter {
    struct RequestRecord: Equatable {
        let identifier: String
        let title: String
        let body: String
    }

    private(set) var requests: [RequestRecord] = []

    func requestAuthorizationIfNeeded() {}

    func add(identifier: String, title: String, body: String) {
        requests.append(RequestRecord(identifier: identifier, title: title, body: body))
    }
}
