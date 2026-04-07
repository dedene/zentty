import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentStatusSupportTests: XCTestCase {
    func test_agent_interaction_classifier_recognizes_codex_attention_notifications() {
        let cases: [(message: String, kind: PaneAgentInteractionKind)] = [
            ("Approval requested: npm publish", .approval),
            ("Codex wants to edit Sources/App.swift", .approval),
            ("Approval requested by docs", .approval),
            ("Question requested: Choose deployment target", .decision),
            ("Questions requested: 2", .decision),
            ("Plan mode prompt: Implement this plan?", .approval),
        ]

        for testCase in cases {
            XCTAssertTrue(
                AgentInteractionClassifier.requiresHumanInput(message: testCase.message),
                "Expected Codex attention message to require human input: \(testCase.message)"
            )
            XCTAssertEqual(
                AgentInteractionClassifier.interactionKind(forWaitingMessage: testCase.message),
                testCase.kind,
                "Expected Codex attention message to infer the right interaction kind: \(testCase.message)"
            )
        }
    }

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

    func test_repository_shell_integrations_emit_guarded_git_branch_signal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shellIntegrationDirectory = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)

        for filename in ["zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let scriptURL = shellIntegrationDirectory.appendingPathComponent(filename, isDirectory: false)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)

            XCTAssertTrue(script.contains("git rev-parse --git-dir >/dev/null 2>&1"), filename)
            XCTAssertTrue(script.contains("git branch --show-current"), filename)
            XCTAssertTrue(script.contains("--git-branch"), filename)
        }
    }

    func test_repository_shell_integrations_dedupe_shell_activity_signal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shellIntegrationDirectory = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)

        for filename in ["zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let scriptURL = shellIntegrationDirectory.appendingPathComponent(filename, isDirectory: false)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)

            XCTAssertTrue(script.contains("_zentty_shell_activity_last"), filename)
            XCTAssertTrue(script.contains("[[ \"$_zentty_shell_activity_last\" == \"$state\" ]]"), filename)
        }
    }

    func test_zsh_shell_integration_emits_updated_pane_context_before_next_command_after_cd() throws {
        let targetDirectory = try makeTemporaryDirectory(named: "shell-zsh-target")

        let signals = try runShellIntegration(
            shell: .zsh,
            command: "cd \(shellQuoted(targetDirectory.path)) && :"
        )

        XCTAssertTrue(
            signals.contains(where: { $0.contains("pane-context local --path \(targetDirectory.path)") }),
            "Expected zsh integration to emit pane context for \(targetDirectory.path), got: \(signals)"
        )
    }

    func test_bash_shell_integration_emits_updated_pane_context_before_next_command_after_cd() throws {
        let targetDirectory = try makeTemporaryDirectory(named: "shell-bash-target")

        let signals = try runShellIntegration(
            shell: .bash,
            command: "cd \(shellQuoted(targetDirectory.path)) && :"
        )

        XCTAssertTrue(
            signals.contains(where: { $0.contains("pane-context local --path \(targetDirectory.path)") }),
            "Expected bash integration to emit pane context for \(targetDirectory.path), got: \(signals)"
        )
    }

    func test_repository_codex_wrapper_exports_session_scoped_pid() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codexWrapperURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)

        let script = try String(contentsOf: codexWrapperURL, encoding: .utf8)
        XCTAssertTrue(script.contains("export ZENTTY_CODEX_PID=$$"))
    }

    func test_copy_agent_resources_build_script_syncs_opencode_support_directory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFileURL = repositoryRoot.appendingPathComponent("Zentty.xcodeproj/project.pbxproj", isDirectory: false)

        let project = try String(contentsOf: projectFileURL, encoding: .utf8)

        XCTAssertTrue(project.contains("${RESOURCES_DST}/opencode/plugins"))
        XCTAssertTrue(project.contains("${RESOURCES_SRC}/opencode/"))
        XCTAssertTrue(project.contains("${RESOURCES_DST}/opencode/"))
    }

    func test_repository_opencode_plugin_exists_and_mentions_opencode_hook_bridge() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)

        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(plugin.contains("opencode-hook"))
        XCTAssertTrue(plugin.contains("stdio: [\"pipe\", \"ignore\", \"ignore\"]"))
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
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(command.payload.paneID, PaneID("worklane-main-shell"))
        XCTAssertEqual(command.payload.state, .needsInput)
        XCTAssertEqual(command.payload.toolName, "Claude Code")
        XCTAssertEqual(command.payload.text, "Claude is waiting for your input")
        XCTAssertEqual(command.payload.artifactKind, .pullRequest)

        let userInfo = try XCTUnwrap(command.payload.notificationUserInfo)
        let decodedPayload = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decodedPayload, command.payload)
    }

    func test_agent_status_payload_decodes_legacy_notification_defaults_when_kind_and_origin_are_omitted() throws {
        let payload = try AgentStatusPayload(
            userInfo: [
                "worklaneID": "worklane-main",
                "paneID": "worklane-main-shell",
                "state": "running",
                "toolName": "Claude Code",
            ]
        )

        XCTAssertEqual(payload.signalKind, .lifecycle)
        XCTAssertEqual(payload.origin, .compatibility)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Claude Code")
    }

    func test_agent_status_payload_decodes_legacy_completed_state_as_idle() throws {
        let payload = try AgentStatusPayload(
            userInfo: [
                "worklaneID": "worklane-main",
                "paneID": "worklane-main-shell",
                "state": "completed",
                "toolName": "Codex",
            ]
        )

        XCTAssertEqual(payload.state, .idle)
    }

    func test_agent_status_command_accepts_legacy_completed_alias() throws {
        let command = try AgentStatusCommand.parse(
            arguments: ["agent-status", "completed", "--tool", "Codex"],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.state, .idle)
        XCTAssertEqual(command.payload.toolName, "Codex")
    }

    func test_agent_signal_command_accepts_legacy_completed_alias_and_session_id() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "agent-signal",
                "lifecycle",
                "completed",
                "--tool", "Codex",
                "--session-id", "session-1",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.state, .idle)
        XCTAssertEqual(command.payload.toolName, "Codex")
        XCTAssertEqual(command.payload.sessionID, "session-1")
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
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
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

    func test_agent_signal_command_parses_local_pane_context_git_branch() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "local",
                "--path", "/Users/peter/src/zentty",
                "--home", "/Users/peter",
                "--git-branch", "feature/review-band",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
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
                host: nil,
                gitBranch: "feature/review-band"
            )
        )
    }

    func test_agent_status_payload_round_trips_pane_context_git_branch() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .paneContext,
            state: nil,
            paneContext: PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: "peter",
                host: "mbp",
                gitBranch: "feature/review-band"
            ),
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decodedPayload = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decodedPayload, payload)
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
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
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
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
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
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            )
        )
    }

    func test_notification_coordinator_fires_once_per_attention_state_entry() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        let needsInputWorklane = WorklaneState(
            id: worklaneID,
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
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        coordinator.update(
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)

        let clearedWorklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )
        coordinator.update(
            worklanes: [clearedWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        coordinator.update(
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(
            payload,
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("worklane-main-shell"),
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude is waiting for your input",
                lifecycleEvent: .update,
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    func test_claude_hook_notification_stays_generic_input_when_message_mentions_approval() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your approval"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .genericInput)
        XCTAssertNotEqual(payload.interactionKind, .approval)
    }

    func test_claude_hook_parse_input_reads_notification_type() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input","notification_type":"idle_prompt"}
            """.utf8)
        )

        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.sessionID, "session-1")
        XCTAssertEqual(input.message, "Claude is waiting for your input")
        XCTAssertEqual(input.notificationType, "idle_prompt")
    }

    func test_claude_hook_idle_prompt_notification_is_ignored() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input","notification_type":"idle_prompt"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(payload.text, "Allow file write?")
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.confidence, .explicit)
    }

    func test_claude_hook_ask_user_question_with_options_maps_to_decision_payload() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let input = try ClaudeHookBridge.parseInput(
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

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
    }

    func test_claude_hook_ask_user_question_without_options_maps_to_decision_payload() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?"
                  }
                ]
              }
            }
            """.utf8)
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?")
    }

    func test_claude_hook_generic_notification_does_not_replace_permission_request_copy() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
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
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )
        let notificationPayload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(permissionPayload.text, "Claude needs your approval")
        XCTAssertEqual(notificationPayload.text, "Claude needs your approval")
    }

    func test_claude_hook_generic_approval_notification_does_not_relabel_explicit_decision_prompt() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242,
            lastHumanMessage: "Choose one",
            lastInteractionKind: .decision
        )

        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your approval before continuing"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Choose one")
    }

    func test_claude_hook_ask_user_question_replaces_prior_explicit_approval_copy_when_kind_changes() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242,
            lastHumanMessage: "Claude needs your approval",
            lastInteractionKind: .approval
        )

        let input = try ClaudeHookBridge.parseInput(
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

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
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
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_CLAUDE_PID": "4242",
            ],
            sessionStore: store
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Claude Code",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
            ]
        )

        let record = try XCTUnwrap(store.lookup(sessionID: "session-1"))
        XCTAssertEqual(record.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(record.paneID, PaneID("worklane-main-shell"))
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
            worklaneID: WorklaneID("worklane-a"),
            paneID: PaneID("pane-a"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-b",
                    "ZENTTY_PANE_ID": "pane-b",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.worklaneID, WorklaneID("worklane-a"))
        XCTAssertEqual(payload.paneID, PaneID("pane-a"))
    }

    func test_claude_hook_pre_tool_use_ask_user_question_with_options_emits_explicit_decision_payload_and_persists_richer_message() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
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

        let preToolUsePayload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
            from: preToolUse,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        ).first
        )

        XCTAssertEqual(preToolUsePayload.state, .needsInput)
        XCTAssertEqual(preToolUsePayload.interactionKind, .decision)
        XCTAssertEqual(preToolUsePayload.text, "Ship this?\n[Yes] [No]")

        let notification = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your input"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
        XCTAssertEqual(payload.interactionKind, .decision)
    }

    func test_agent_status_center_delivers_payloads_on_main_actor() {
        let center = AgentStatusCenter()
        // Use test-only IDs to avoid leaking a real distributed notification
        // into a running Zentty instance (which uses "worklane-main" by default).
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("test-status-center"),
            paneID: PaneID("test-status-center-shell"),
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(payload.paneID, PaneID("worklane-main-shell"))
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Claude Code")
    }

    func test_claude_hook_stop_maps_to_stop_candidate_payload_without_clearing_pid_mapping() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Stop","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            ClaudeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.lifecycleEvent, .stopCandidate)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(try store.lookup(sessionID: "session-1")?.pid, 4242)
    }

    func test_codex_hook_prompt_submit_maps_to_running_payload() throws {
        let input = try CodexHookBridge.parseInput(
            Data("""
            {"hook_event_name":"UserPromptSubmit","session_id":"session-1","cwd":"/tmp/project"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            CodexHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_codex_hook_session_start_emits_session_scoped_pid_attach_and_starting_payloads() throws {
        let input = try CodexHookBridge.parseInput(
            Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project"}
            """.utf8)
        )

        let payloads = try CodexHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_CODEX_PID": "4242",
            ]
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Codex",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .lifecycle,
                    state: .starting,
                    origin: .explicitHook,
                    toolName: "Codex",
                    text: nil,
                    lifecycleEvent: .update,
                    confidence: .explicit,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: "/tmp/project"
                ),
            ]
        )
    }

    func test_codex_hook_stop_maps_to_idle_payload() throws {
        let input = try CodexHookBridge.parseInput(
            Data("""
            {"hook_event_name":"Stop","session_id":"session-1","last_assistant_message":"Done"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            CodexHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
    }

    func test_opencode_hook_session_status_busy_maps_to_running_payload() throws {
        let input = try OpenCodeHookBridge.parseInput(
            Data(
                """
                {"eventType":"session.status","sessionID":"session-1","cwd":"/tmp/project","status":"busy"}
                """.utf8
            )
        )
        let payload = try XCTUnwrap(
            OpenCodeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(
            payload,
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("worklane-main-shell"),
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                lifecycleEvent: .update,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: "/tmp/project"
            )
        )
    }

    func test_opencode_hook_permission_prompt_maps_to_needs_input_approval_payload() throws {
        let input = try OpenCodeHookBridge.parseInput(
            Data(
                """
                {"eventType":"permission.asked","sessionID":"session-1","cwd":"/tmp/project","title":"Allow file write?"}
                """.utf8
            )
        )
        let payload = try XCTUnwrap(
            OpenCodeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.text, "Allow file write?")
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.confidence, .explicit)
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_opencode_hook_question_prompt_with_options_maps_to_decision_payload() throws {
        let input = try OpenCodeHookBridge.parseInput(
            Data(
                """
                {"eventType":"question.asked","sessionID":"session-1","cwd":"/tmp/project","questions":[{"header":"Deployment","question":"Choose environment","options":[{"label":"Staging"},{"label":"Production"}]}]}
                """.utf8
            )
        )
        let payload = try XCTUnwrap(
            OpenCodeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.text, "Choose environment\n[Staging] [Production]")
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.confidence, .explicit)
    }

    func test_opencode_hook_permission_reply_maps_to_running_payload() throws {
        let input = try OpenCodeHookBridge.parseInput(
            Data(
                """
                {"eventType":"permission.replied","sessionID":"session-1","cwd":"/tmp/project"}
                """.utf8
            )
        )
        let payload = try XCTUnwrap(
            OpenCodeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_opencode_hook_session_idle_maps_to_idle_payload() throws {
        let input = try OpenCodeHookBridge.parseInput(
            Data(
                """
                {"eventType":"session.idle","sessionID":"session-1","cwd":"/tmp/project"}
                """.utf8
            )
        )
        let payload = try XCTUnwrap(
            OpenCodeHookBridge.makePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .lifecycle)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[0].sessionID, "session-1")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
        XCTAssertEqual(payloads[1].sessionID, "session-1")
        XCTAssertNil(try store.lookup(sessionID: "session-1"))
    }

    func test_claude_hook_session_end_without_session_id_does_not_clear_ambiguous_pane_sessions() throws {
        let input = try ClaudeHookBridge.parseInput(
            Data("""
            {"hook_event_name":"SessionEnd"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-parent",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )
        try store.upsert(
            sessionID: "session-child",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4343
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNotNil(try store.lookup(sessionID: "session-parent"))
        XCTAssertNotNil(try store.lookup(sessionID: "session-child"))
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
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
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try ClaudeHookBridge.makePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_notification_coordinator_fires_for_unresolved_stop_when_pane_is_not_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        let worklane = WorklaneState(
            id: worklaneID,
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
            worklanes: [worklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(
            recorder.requests,
            [
                .init(
                    identifier: recorder.requests.first?.identifier ?? "",
                    title: "Stopped early",
                    body: "Agent stopped early.",
                    soundName: ""
                )
            ]
        )
    }

    func test_notification_coordinator_fires_for_ready_when_pane_is_not_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            worklanes: [makeReadyWorklane(worklaneID: worklaneID, paneID: paneID, primaryText: "Implement push notifications")],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(
            recorder.requests,
            [
                .init(
                    identifier: recorder.requests.first?.identifier ?? "",
                    title: "Agent ready",
                    body: "Implement push notifications",
                    soundName: ""
                )
            ]
        )
    }

    func test_notification_coordinator_does_not_fire_for_ready_when_pane_is_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            worklanes: [makeReadyWorklane(worklaneID: worklaneID, paneID: paneID, primaryText: "Implement push notifications")],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func test_notification_coordinator_tracks_ready_and_stopped_notifications_per_pane() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let readyPaneID = PaneID("worklane-main-ready")
        let stoppedPaneID = PaneID("worklane-main-stopped")
        let worklaneID = WorklaneID("worklane-main")

        let committed = expectation(description: "notifications committed")
        committed.expectedFulfillmentCount = 2
        store.onChange = { committed.fulfill() }

        coordinator.update(
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: readyPaneID,
                    attentions: [
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                        .init(
                            paneID: stoppedPaneID,
                            title: "Fix failure handling",
                            state: .unresolvedStop,
                            updatedAt: Date(timeIntervalSince1970: 100)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )

        await fulfillment(of: [committed], timeout: 2)

        XCTAssertEqual(Set(store.notifications.map(\.paneID)), [readyPaneID, stoppedPaneID])
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Stopped early")
        XCTAssertEqual(recorder.requests.first?.soundName, "")
    }

    func test_notification_coordinator_resolves_live_notification_when_pane_becomes_focused() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let readyPaneID = PaneID("worklane-main-ready")
        let otherPaneID = PaneID("worklane-main-other")
        let worklaneID = WorklaneID("worklane-main")

        let committed = expectation(description: "notification committed")
        store.onChange = { committed.fulfill() }
        coordinator.update(
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: otherPaneID,
                    attentions: [
                        .init(
                            paneID: otherPaneID,
                            title: "Keep working",
                            state: .running,
                            updatedAt: Date(timeIntervalSince1970: 10)
                        ),
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )
        await fulfillment(of: [committed], timeout: 2)

        let resolved = expectation(description: "notification resolved")
        store.onChange = { resolved.fulfill() }
        coordinator.update(
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: readyPaneID,
                    attentions: [
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertTrue(store.notifications[0].isResolved)
    }

    func test_notification_coordinator_uses_sound_only_for_needs_input() throws {
        let recorder = WorklaneAttentionNotificationRecorder()
        let configURL = AppConfigStore.temporaryFileURL(prefix: "agent-notification-sound-tests")
        let configStore = AppConfigStore(fileURL: configURL)
        try configStore.update { config in
            config.notifications.soundName = "Glass"
        }
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            configStore: configStore
        )
        let paneID = PaneID("worklane-main-input")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .decision,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.soundName, "Glass")
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

    private func makeReadyWorklane(
        worklaneID: WorklaneID,
        paneID: PaneID,
        primaryText: String
    ) -> WorklaneState {
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.raw = PaneRawState(
            metadata: TerminalMetadata(
                title: primaryText,
                currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/Users/peter/Development/Personal/zentty",
                repositoryRoot: "/Users/peter/Development/Personal/zentty",
                reference: .branch("main")
            ),
            showsReadyStatus: true,
            lastDesktopNotificationText: "Agent ready",
            lastDesktopNotificationDate: Date(timeIntervalSince1970: 100)
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )

        return WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )
    }

    private struct AttentionFixture {
        let paneID: PaneID
        let title: String
        let state: WorklaneAttentionState
        var interactionKind: PaneInteractionKind? = nil
        let updatedAt: Date
    }

    private func makeAttentionWorklane(
        worklaneID: WorklaneID,
        focusedPaneID: PaneID,
        attentions: [AttentionFixture]
    ) -> WorklaneState {
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        let panes = attentions.map { attention in
            PaneState(id: attention.paneID, title: attention.title)
        }

        for attention in attentions {
            var auxiliaryState = PaneAuxiliaryState()
            auxiliaryState.presentation = PanePresentationState(
                cwd: "/tmp/project",
                repoRoot: "/tmp/project",
                branch: "main",
                branchDisplayText: "main",
                lookupBranch: "main",
                identityText: attention.title,
                contextText: "main · /tmp/project",
                rememberedTitle: attention.title,
                recognizedTool: .claudeCode,
                runtimePhase: runtimePhase(for: attention.state),
                statusText: statusText(for: attention.state, interactionKind: attention.interactionKind),
                pullRequest: nil,
                reviewChips: [],
                attentionArtifactLink: nil,
                updatedAt: attention.updatedAt,
                isWorking: false,
                isReady: attention.state == .ready,
                interactionKind: attention.interactionKind,
                interactionLabel: attention.interactionKind?.defaultLabel,
                interactionSymbolName: attention.interactionKind?.defaultSymbolName
            )
            auxiliaryStateByPaneID[attention.paneID] = auxiliaryState
        }

        return WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: panes,
                focusedPaneID: focusedPaneID
            ),
            auxiliaryStateByPaneID: auxiliaryStateByPaneID
        )
    }

    private func runtimePhase(for state: WorklaneAttentionState) -> PanePresentationPhase {
        switch state {
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .ready:
            return .idle
        case .running:
            return .running
        }
    }

    private func statusText(
        for state: WorklaneAttentionState,
        interactionKind: PaneInteractionKind?
    ) -> String {
        switch state {
        case .needsInput:
            return interactionKind?.defaultLabel ?? "Needs input"
        case .unresolvedStop:
            return "Stopped early"
        case .ready:
            return "Agent ready"
        case .running:
            return "Running"
        }
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
            <string>be.zenjoy.zentty.tests.\(name)</string>
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

    func test_agent_status_payload_round_trips_agent_working_directory() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: "/Users/peter/Development/my-project"
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decoded.agentWorkingDirectory, "/Users/peter/Development/my-project")
        XCTAssertEqual(decoded, payload)
    }

    func test_agent_status_payload_round_trips_nil_agent_working_directory() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertNil(decoded.agentWorkingDirectory)
        XCTAssertEqual(decoded, payload)
    }

    private func runShellIntegration(shell: ShellIntegrationTestShell, command: String) throws -> [String] {
        let scratchDirectory = try makeTemporaryDirectory(named: "shell-integration-scratch")
        let fakeAgentURL = scratchDirectory.appendingPathComponent("fake-agent", isDirectory: false)
        let logURL = scratchDirectory.appendingPathComponent("signals.log", isDirectory: false)

        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$LOG_FILE"
        """.write(to: fakeAgentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgentURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.executablePath)
        process.arguments = shell.arguments(
            for: "source \(shellQuoted(shell.integrationScriptURL.path)); \(command)"
        )
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LOG_FILE": logURL.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "peter",
            "ZENTTY_AGENT_BIN": fakeAgentURL.path,
            "ZENTTY_PANE_ID": "pane-under-test",
            "ZENTTY_SHELL_INTEGRATION": "1",
            "ZENTTY_WORKLANE_ID": "worklane-under-test",
            "ZENTTY_WRAPPER_BIN_DIR": scratchDirectory.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderrText)

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }

        let log = try String(contentsOf: logURL, encoding: .utf8)
        return log
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class WorklaneAttentionNotificationRecorder: WorklaneAttentionUserNotificationCenter {
    struct RequestRecord: Equatable {
        let identifier: String
        let title: String
        let body: String
        let soundName: String
    }

    private(set) var requests: [RequestRecord] = []

    func requestAuthorizationIfNeeded() {}

    func add(identifier: String, title: String, body: String, worklaneID: String, paneID: String, soundName: String) {
        requests.append(RequestRecord(identifier: identifier, title: title, body: body, soundName: soundName))
    }
}

private enum ShellIntegrationTestShell {
    case zsh
    case bash

    var executablePath: String {
        switch self {
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        }
    }

    var integrationScriptURL: URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let filename: String
        switch self {
        case .zsh:
            filename = "zentty-zsh-integration.zsh"
        case .bash:
            filename = "zentty-bash-integration.bash"
        }
        return repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    func arguments(for command: String) -> [String] {
        switch self {
        case .zsh:
            return ["-f", "-c", command]
        case .bash:
            return ["--noprofile", "--norc", "-c", command]
        }
    }
}
