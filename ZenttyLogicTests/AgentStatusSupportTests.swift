import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentStatusSupportTests: XCTestCase {
    func test_agent_status_helper_returns_nil_when_resource_directories_are_missing() throws {
        let bundle = try makeTemporaryBundle(named: "MissingResources")

        XCTAssertNil(AgentStatusHelper.wrapperBinPath(in: bundle))
        XCTAssertNil(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle))
    }

    func test_agent_status_helper_requires_expected_resource_files() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "CompleteResources")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        for name in ["zentty-agent-wrapper", "claude", "codex", "opencode"] {
            let fileURL = binURL.appendingPathComponent(name, isDirectory: false)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }

        let shellURL = resourcesURL.appendingPathComponent("shell-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: shellURL, withIntermediateDirectories: true)
        for name in [".zshenv", "zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let fileURL = shellURL.appendingPathComponent(name, isDirectory: false)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("# test\n".utf8))
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        XCTAssertEqual(AgentStatusHelper.wrapperBinPath(in: bundle), binURL.path)
        XCTAssertEqual(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle), shellURL.path)
    }

    func test_agent_status_helper_requires_executable_wrapper_files() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "NonExecutableWrappers")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        for name in ["zentty-agent-wrapper", "claude", "codex", "opencode"] {
            let fileURL = binURL.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let shellURL = resourcesURL.appendingPathComponent("shell-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: shellURL, withIntermediateDirectories: true)
        for name in [".zshenv", "zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let fileURL = shellURL.appendingPathComponent(name, isDirectory: false)
            try "# test\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        XCTAssertNil(AgentStatusHelper.wrapperBinPath(in: bundle))
        XCTAssertEqual(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle), shellURL.path)
    }

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

    func test_agent_signal_command_parses_local_pane_context_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "local",
                "--path", "/Users/peter/src/zentty",
                "--home", "/Users/peter",
            ],
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertEqual(
            command.payload.paneContext,
            PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: nil,
                host: nil
            )
        )
    }

    func test_agent_signal_command_parses_remote_pane_context_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "remote",
                "--path", "/home/peter/project",
                "--home", "/home/peter",
                "--user", "peter",
                "--host", "gilfoyle",
            ],
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertEqual(
            command.payload.paneContext,
            PaneShellContext(
                scope: .remote,
                path: "/home/peter/project",
                home: "/home/peter",
                user: "peter",
                host: "gilfoyle"
            )
        )
    }

    func test_agent_signal_command_parses_pane_context_clear_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "clear",
            ],
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertNil(command.payload.paneContext)
        XCTAssertTrue(command.payload.clearsPaneContext)
    }

    func test_agent_signal_command_rejects_missing_pane_context_scope() {
        XCTAssertThrowsError(
            try AgentSignalCommand.parse(
                arguments: [
                    "zentty-agent",
                    "agent-signal",
                    "pane-context",
                ],
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ]
            )
        )
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
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(
            payload,
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
                paneID: PaneID("workspace-main-shell"),
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude is waiting for your input",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    func test_claude_hook_permission_request_maps_to_needs_input_payload() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"PermissionRequest","session_id":"session-1","message":"Allow file write?"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(payload.text, "Allow file write?")
    }

    func test_claude_hook_generic_notification_does_not_replace_permission_request_copy() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let permissionRequest = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"PermissionRequest","session_id":"session-1","message":"Claude needs your approval"}
            """.utf8)
        )
        let notification = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your attention"}
            """.utf8)
        )

        let permissionPayload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: permissionRequest,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )
        let notificationPayload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(permissionPayload.text, "Claude needs your approval")
        XCTAssertEqual(notificationPayload.text, "Claude needs your approval")
    }

    func test_claude_hook_session_start_records_mapping_and_emits_pid_attach() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
                "ZENTTY_CLAUDE_PID": "4242",
            ],
            sessionStore: store
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    workspaceID: WorkspaceID("workspace-main"),
                    paneID: PaneID("workspace-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Claude Code",
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
            ]
        )

        let record = try XCTUnwrap(store.lookup(sessionID: "session-1"))
        XCTAssertEqual(record.workspaceID, WorkspaceID("workspace-main"))
        XCTAssertEqual(record.paneID, PaneID("workspace-main-shell"))
        XCTAssertEqual(record.cwd, "/tmp/project")
        XCTAssertEqual(record.pid, 4242)
    }

    func test_claude_hook_notification_uses_persisted_session_target_not_current_env() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-a"),
            paneID: PaneID("pane-a"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-b",
                    "ZENTTY_PANE_ID": "pane-b",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.workspaceID, WorkspaceID("workspace-a"))
        XCTAssertEqual(payload.paneID, PaneID("pane-a"))
    }

    func test_claude_hook_pre_tool_use_ask_user_question_persists_richer_message_for_notification() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let preToolUse = try ClaudeHookBridge.parseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )

        let preToolUsePayloads = try ClaudeHookBridge.makePayloads(
            from: preToolUse,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(preToolUsePayloads.isEmpty)

        let notification = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your input"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
    }

    func test_agent_status_center_delivers_payloads_on_main_actor() {
        let center = AgentStatusCenter()
        let payload = AgentStatusPayload(
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: "Claude needs your approval",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let deliveredOnMain = expectation(description: "payload delivered on main actor")

        center.onPayload = { receivedPayload in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(receivedPayload, payload)
            deliveredOnMain.fulfill()
        }
        center.start()

        DispatchQueue.global(qos: .userInitiated).async {
            DistributedNotificationCenter.default().postNotificationName(
                AgentStatusTransport.notificationName,
                object: nil,
                userInfo: payload.notificationUserInfo,
                deliverImmediately: true
            )
        }

        wait(for: [deliveredOnMain], timeout: 2)
    }

    func test_claude_hook_pre_tool_use_clears_waiting_and_restores_running() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"PreToolUse","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.workspaceID, WorkspaceID("workspace-main"))
        XCTAssertEqual(payload.paneID, PaneID("workspace-main-shell"))
    }

    func test_claude_hook_prompt_submit_maps_to_running_payload() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"UserPromptSubmit","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Claude Code")
    }

    func test_claude_hook_stop_maps_to_completed_payload_without_clearing_pid_mapping() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Stop","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKSPACE_ID": "workspace-main",
                    "ZENTTY_PANE_ID": "workspace-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .completed)
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(try store.lookup(sessionID: "session-1")?.pid, 4242)
    }

    func test_claude_hook_session_end_clears_status_pid_and_mapping() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"SessionEnd","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .lifecycle)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
        XCTAssertNil(try store.lookup(sessionID: "session-1"))
    }

    func test_claude_hook_non_action_notification_is_ignored() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Doing well, thanks!"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_claude_hook_ignores_unknown_events() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"PostToolUse","session_id":"session-1","message":"tool finished"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            workspaceID: WorkspaceID("workspace-main"),
            paneID: PaneID("workspace-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_notification_coordinator_does_not_fire_for_unresolved_stop() {
        let recorder = WorkspaceAttentionNotificationRecorder()
        let coordinator = WorkspaceAttentionNotificationCoordinator(center: recorder)
        let paneID = PaneID("workspace-main-shell")
        let workspaceID = WorkspaceID("workspace-main")

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .unresolvedStop,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        coordinator.update(
            workspaces: [workspace],
            activeWorkspaceID: workspaceID,
            windowIsKey: false
        )

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    private func makeClaudeHookSessionStore() throws -> ClaudeHookSessionStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return ClaudeHookSessionStore(stateURL: directoryURL.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func makeTemporaryBundle(named name: String) throws -> Bundle {
        let bundleRoot = try makeTemporaryBundleRoot(named: name)
        return try XCTUnwrap(Bundle(url: bundleRoot))
    }

    private func makeTemporaryBundleRoot(named name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.peterdedene.zentty.tests.\(name)</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let executableURL = macOSURL.appendingPathComponent(name, isDirectory: false)
        FileManager.default.createFile(atPath: executableURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return rootURL
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
