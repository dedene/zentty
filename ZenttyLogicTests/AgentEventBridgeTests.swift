import Foundation
import XCTest
@testable import Zentty

final class AgentEventBridgeTests: XCTestCase {

    private let defaultEnvironment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-1",
        "ZENTTY_PANE_ID": "pane-1",
        "ZENTTY_WINDOW_ID": "window-1",
    ]

    // MARK: - Parsing

    func test_parseInput_requires_version_1() throws {
        let json = #"{"version": 2, "event": "agent.running"}"#
        XCTAssertThrowsError(try AgentEventBridge.parseInput(json.data(using: .utf8)!))
    }

    func test_parseInput_requires_event_field() throws {
        let json = #"{"version": 1}"#
        XCTAssertThrowsError(try AgentEventBridge.parseInput(json.data(using: .utf8)!))
    }

    func test_parseInput_rejects_empty_data() throws {
        XCTAssertThrowsError(try AgentEventBridge.parseInput(Data()))
    }

    func test_parseInput_extracts_all_fields() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.needs-input",
          "agent": { "name": "My Agent", "pid": 12345 },
          "session": { "id": "sess-1", "parentId": "parent-1" },
          "state": {
            "text": "Waiting for approval",
            "stopCandidate": true,
            "interaction": { "kind": "approval", "text": "Allow write?" }
          },
          "progress": { "done": 3, "total": 7 },
          "artifact": { "kind": "pull-request", "label": "PR #42", "url": "https://github.com/org/repo/pull/42" },
          "context": { "workingDirectory": "/tmp/project" }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)

        XCTAssertEqual(input.event, "agent.needs-input")
        XCTAssertEqual(input.agentName, "My Agent")
        XCTAssertEqual(input.agentPID, 12345)
        XCTAssertEqual(input.sessionID, "sess-1")
        XCTAssertEqual(input.parentSessionID, "parent-1")
        XCTAssertEqual(input.stateText, "Waiting for approval")
        XCTAssertTrue(input.stopCandidate)
        XCTAssertEqual(input.interactionKind, "approval")
        XCTAssertEqual(input.interactionText, "Allow write?")
        XCTAssertEqual(input.progressDone, 3)
        XCTAssertEqual(input.progressTotal, 7)
        XCTAssertEqual(input.artifactKind, "pull-request")
        XCTAssertEqual(input.artifactLabel, "PR #42")
        XCTAssertEqual(input.artifactURL, "https://github.com/org/repo/pull/42")
        XCTAssertEqual(input.workingDirectory, "/tmp/project")
    }

    func test_parseInput_handles_minimal_payload() throws {
        let json = #"{"version": 1, "event": "agent.idle"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)

        XCTAssertEqual(input.event, "agent.idle")
        XCTAssertNil(input.agentName)
        XCTAssertNil(input.agentPID)
        XCTAssertNil(input.sessionID)
        XCTAssertFalse(input.stopCandidate)
        XCTAssertNil(input.interactionKind)
        XCTAssertNil(input.progressDone)
    }

    func test_claude_wrapper_delegates_to_shared_agent_wrapper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapperPath = repoRoot
            .appendingPathComponent("ZenttyResources/bin/claude/claude")
            .path
        let script = try String(contentsOfFile: wrapperPath, encoding: .utf8)

        XCTAssertTrue(script.contains("ZENTTY_AGENT_TOOL=\"claude\""))
        XCTAssertTrue(script.contains("zentty-agent-wrapper"))
    }

    func test_run_claude_adapter_invalid_payload_fails_open_without_logging() throws {
        var postedPayloads: [AgentStatusPayload] = []
        var loggedErrors: [String] = []

        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=claude"],
            environment: defaultEnvironment,
            inputData: Data(),
            post: { postedPayloads.append($0) },
            writeError: { loggedErrors.append(String(describing: $0)) }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertTrue(loggedErrors.isEmpty)
    }

    func test_run_copilot_adapter_invalid_payload_still_fails_closed() throws {
        var postedPayloads: [AgentStatusPayload] = []
        var loggedErrors: [String] = []

        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=copilot"],
            environment: defaultEnvironment,
            inputData: Data(),
            post: { postedPayloads.append($0) },
            writeError: { loggedErrors.append(String(describing: $0)) }
        )

        XCTAssertEqual(result, EXIT_FAILURE)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertEqual(loggedErrors.count, 1)
    }

    func test_run_cursor_adapter_invalid_payload_still_fails_closed() throws {
        var postedPayloads: [AgentStatusPayload] = []
        var loggedErrors: [String] = []

        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: defaultEnvironment,
            inputData: Data(),
            post: { postedPayloads.append($0) },
            writeError: { loggedErrors.append(String(describing: $0)) }
        )

        XCTAssertEqual(result, EXIT_FAILURE)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertEqual(loggedErrors.count, 1)
    }

    func test_cursor_adapter_session_start_includes_pid_when_env_set() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = """
        {"hook_event_name":"sessionStart","conversation_id":"c1","workspace_roots":["/tmp/ws"]}
        """
        let env = defaultEnvironment.merging(["ZENTTY_CURSOR_PID": "9999"]) { _, new in new }
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: env,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 2)
        XCTAssertEqual(postedPayloads[0].signalKind, .pid)
        XCTAssertEqual(postedPayloads[0].pid, 9999)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
        XCTAssertEqual(postedPayloads[1].state, .starting)
        XCTAssertEqual(postedPayloads[1].toolName, "Cursor")
        XCTAssertEqual(postedPayloads[1].sessionID, "c1")
        XCTAssertEqual(postedPayloads[1].agentWorkingDirectory, "/tmp/ws")
    }

    func test_cursor_adapter_before_submit_prompt_maps_to_running() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = #"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c-run"}"#
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: defaultEnvironment,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 1)
        XCTAssertEqual(postedPayloads[0].state, .running)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
        XCTAssertEqual(postedPayloads[0].sessionID, "c-run")
    }

    func test_cursor_adapter_stop_completed_maps_to_idle() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = #"{"hook_event_name":"stop","conversation_id":"c2","status":"completed"}"#
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: defaultEnvironment,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 1)
        XCTAssertEqual(postedPayloads[0].state, .idle)
        XCTAssertEqual(postedPayloads[0].lifecycleEvent, .update)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
    }

    func test_cursor_adapter_stop_error_maps_to_unresolved_stop() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = #"{"hook_event_name":"stop","conversation_id":"c3","status":"error"}"#
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: defaultEnvironment,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 1)
        XCTAssertEqual(postedPayloads[0].state, .unresolvedStop)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
    }

    func test_cursor_adapter_shell_execution_hooks_are_ignored_by_default() throws {
        for event in ["beforeShellExecution", "afterShellExecution"] {
            var postedPayloads: [AgentStatusPayload] = []
            let json = #"{"hook_event_name":"\#(event)","conversation_id":"c-shell"}"#
            let result = AgentEventBridge.run(
                arguments: ["zentty", "agent-event", "--adapter=cursor"],
                environment: defaultEnvironment,
                inputData: Data(json.utf8),
                post: { postedPayloads.append($0) },
                writeError: { XCTFail("unexpected error: \($0)") }
            )

            XCTAssertEqual(result, EXIT_SUCCESS)
            XCTAssertTrue(postedPayloads.isEmpty, "Expected \(event) to stay quiet without verbose hooks")
        }
    }

    func test_cursor_adapter_before_shell_execution_verbose_maps_to_running() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = #"{"hook_event_name":"beforeShellExecution","conversation_id":"c-shell","workspace_roots":["/tmp/ws"]}"#
        let env = defaultEnvironment.merging(["ZENTTY_CURSOR_VERBOSE_HOOKS": "1"]) { _, new in new }
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: env,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 1)
        XCTAssertEqual(postedPayloads[0].state, .running)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
        XCTAssertEqual(postedPayloads[0].sessionID, "c-shell")
        XCTAssertEqual(postedPayloads[0].agentWorkingDirectory, "/tmp/ws")
    }

    func test_cursor_adapter_after_shell_execution_verbose_maps_to_running() throws {
        var postedPayloads: [AgentStatusPayload] = []
        let json = #"{"hook_event_name":"afterShellExecution","conversation_id":"c-shell"}"#
        let env = defaultEnvironment.merging(["ZENTTY_CURSOR_VERBOSE_HOOKS": "1"]) { _, new in new }
        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=cursor"],
            environment: env,
            inputData: Data(json.utf8),
            post: { postedPayloads.append($0) },
            writeError: { XCTFail("unexpected error: \($0)") }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(postedPayloads.count, 1)
        XCTAssertEqual(postedPayloads[0].state, .running)
        XCTAssertEqual(postedPayloads[0].toolName, "Cursor")
    }

    func test_cursor_adapter_pre_tool_use_todo_write_array_reports_progress() throws {
        let store = try makeCursorTaskStore()
        let payload = try XCTUnwrap(
            AgentEventBridge.cursorAdapter(
                data: Data("""
                {"hook_event_name":"preToolUse","conversation_id":"cursor-session","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Review logs","status":"completed"},{"content":"Patch adapter","status":"in_progress"},{"content":"Run tests","status":"pending"}]}}
                """.utf8),
                environment: defaultEnvironment,
                taskStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Cursor")
        XCTAssertEqual(payload.sessionID, "cursor-session")
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_cursor_adapter_post_tool_use_todo_write_checklist_reports_progress() throws {
        let store = try makeCursorTaskStore()
        let payload = try XCTUnwrap(
            AgentEventBridge.cursorAdapter(
                data: Data("""
                {"hook_event_name":"postToolUse","conversationId":"cursor-session","toolName":"TodoWrite","toolInput":{"todos":"- [x] Review logs\\n- [ ] Run tests"}}
                """.utf8),
                environment: defaultEnvironment,
                taskStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_cursor_adapter_stop_carries_unfinished_todo_progress() throws {
        let store = try makeCursorTaskStore()
        _ = try AgentEventBridge.cursorAdapter(
            data: Data("""
            {"hook_event_name":"preToolUse","conversation_id":"cursor-session","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Review logs","status":"completed"},{"content":"Run tests","status":"pending"}]}}
            """.utf8),
            environment: defaultEnvironment,
            taskStore: store
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.cursorAdapter(
                data: Data(#"{"hook_event_name":"stop","conversation_id":"cursor-session","status":"completed"}"#.utf8),
                environment: defaultEnvironment,
                taskStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_cursor_adapter_session_end_clears_task_progress() throws {
        let store = try makeCursorTaskStore()
        _ = try AgentEventBridge.cursorAdapter(
            data: Data("""
            {"hook_event_name":"preToolUse","conversation_id":"cursor-session","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Review logs","status":"pending"}]}}
            """.utf8),
            environment: defaultEnvironment,
            taskStore: store
        )

        _ = try AgentEventBridge.cursorAdapter(
            data: Data(#"{"hook_event_name":"sessionEnd","conversation_id":"cursor-session"}"#.utf8),
            environment: defaultEnvironment,
            taskStore: store
        )

        XCTAssertNil(try store.taskProgress(sessionID: "cursor-session"))
    }

    // MARK: - session.start

    func test_session_start_produces_pid_and_lifecycle_payloads() throws {
        let json = """
        {
          "version": 1,
          "event": "session.start",
          "agent": { "name": "my-agent", "pid": 42 },
          "session": { "id": "sess-1" },
          "context": { "workingDirectory": "/tmp" }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.count, 2)

        let pidPayload = payloads[0]
        XCTAssertEqual(pidPayload.signalKind, .pid)
        XCTAssertEqual(pidPayload.pidEvent, .attach)
        XCTAssertEqual(pidPayload.pid, 42)
        XCTAssertEqual(pidPayload.sessionID, "sess-1")
        XCTAssertEqual(pidPayload.toolName, "my-agent")

        let lifecyclePayload = payloads[1]
        XCTAssertEqual(lifecyclePayload.signalKind, .lifecycle)
        XCTAssertEqual(lifecyclePayload.state, .starting)
        XCTAssertEqual(lifecyclePayload.origin, .explicitHook)
        XCTAssertEqual(lifecyclePayload.confidence, .explicit)
        XCTAssertEqual(lifecyclePayload.sessionID, "sess-1")
        XCTAssertEqual(lifecyclePayload.agentWorkingDirectory, "/tmp")
    }

    func test_session_start_without_pid_produces_only_lifecycle() throws {
        let json = #"{"version": 1, "event": "session.start", "agent": {"name": "no-pid-agent"}}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].signalKind, .lifecycle)
        XCTAssertEqual(payloads[0].state, .starting)
    }

    // MARK: - session.end

    func test_session_end_clears_status_and_pid() throws {
        let json = #"{"version": 1, "event": "session.end", "session": {"id": "sess-1"}}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.count, 2)

        let lifecyclePayload = payloads[0]
        XCTAssertTrue(lifecyclePayload.clearsStatus)
        XCTAssertNil(lifecyclePayload.state)

        let pidPayload = payloads[1]
        XCTAssertEqual(pidPayload.signalKind, .pid)
        XCTAssertEqual(pidPayload.pidEvent, .clear)
    }

    // MARK: - agent.running

    func test_agent_running_sets_state_and_clears_interaction() throws {
        let json = #"{"version": 1, "event": "agent.running", "state": {"text": "Thinking..."}}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
        XCTAssertEqual(payloads[0].text, "Thinking...")
        XCTAssertEqual(payloads[0].confidence, .explicit)
    }

    func test_agent_running_with_artifact() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.running",
          "artifact": { "kind": "pull-request", "label": "PR #7", "url": "https://example.com/pr/7" }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].artifactKind, .pullRequest)
        XCTAssertEqual(payloads[0].artifactLabel, "PR #7")
        XCTAssertEqual(payloads[0].artifactURL, URL(string: "https://example.com/pr/7"))
    }

    // MARK: - agent.idle

    func test_agent_idle_basic() throws {
        let json = #"{"version": 1, "event": "agent.idle"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .update)
    }

    func test_agent_idle_stop_candidate() throws {
        let json = #"{"version": 1, "event": "agent.idle", "state": {"stopCandidate": true}}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .stopCandidate)
    }

    // MARK: - agent.needs-input

    func test_needs_input_with_interaction_kind() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.needs-input",
          "state": {
            "interaction": { "kind": "approval", "text": "Allow file write?" }
          }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Allow file write?")
    }

    func test_needs_input_defaults_to_generic() throws {
        let json = #"{"version": 1, "event": "agent.needs-input"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].interactionKind, .genericInput)
    }

    func test_needs_input_all_kinds() throws {
        for kind in ["approval", "question", "decision", "auth", "generic-input"] {
            let json = """
            {"version": 1, "event": "agent.needs-input", "state": {"interaction": {"kind": "\(kind)"}}}
            """
            let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
            let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)
            XCTAssertEqual(payloads[0].state, .needsInput, "Failed for kind: \(kind)")
            XCTAssertNotNil(payloads[0].interactionKind, "Nil interactionKind for: \(kind)")
        }
    }

    func test_needs_input_prefers_interaction_text_over_state_text() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.needs-input",
          "state": {
            "text": "state-level text",
            "interaction": { "kind": "question", "text": "interaction-level text" }
          }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].text, "interaction-level text")
    }

    func test_needs_input_falls_back_to_state_text() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.needs-input",
          "state": { "text": "What should I do?" }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].text, "What should I do?")
    }

    // MARK: - agent.input-resolved

    func test_input_resolved_transitions_to_running() throws {
        let json = #"{"version": 1, "event": "agent.input-resolved"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    // MARK: - task.progress

    func test_task_progress() throws {
        let json = #"{"version": 1, "event": "task.progress", "progress": {"done": 2, "total": 5}}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].taskProgress?.doneCount, 2)
        XCTAssertEqual(payloads[0].taskProgress?.totalCount, 5)
    }

    // MARK: - Pi bridge

    func test_pi_needs_input_payload_resolves_to_pi_tool() throws {
        let json = """
        {
          "version": 1,
          "event": "agent.needs-input",
          "agent": { "name": "Pi" },
          "session": { "id": "pi-session-1" },
          "context": { "workingDirectory": "/tmp/project" },
          "state": { "interaction": { "kind": "approval", "text": "Allow write?" } }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads.first?.state, .needsInput)
        XCTAssertEqual(payloads.first?.interactionKind, .approval)
        XCTAssertEqual(AgentTool.resolve(named: payloads.first?.toolName), .pi)
        XCTAssertEqual(payloads.first?.agentWorkingDirectory, "/tmp/project")
    }

    func test_pi_running_idle_lifecycle() throws {
        let running = try AgentEventBridge.makePayloads(
            from: AgentEventBridge.parseInput(
                #"{"version":1,"event":"agent.running","agent":{"name":"Pi"}}"#.data(using: .utf8)!
            ),
            environment: defaultEnvironment
        )
        let idle = try AgentEventBridge.makePayloads(
            from: AgentEventBridge.parseInput(
                #"{"version":1,"event":"agent.idle","agent":{"name":"Pi"}}"#.data(using: .utf8)!
            ),
            environment: defaultEnvironment
        )

        XCTAssertEqual(running.first?.state, .running)
        XCTAssertEqual(idle.first?.state, .idle)
        XCTAssertEqual(AgentTool.resolve(named: running.first?.toolName), .pi)
        XCTAssertEqual(AgentTool.resolve(named: idle.first?.toolName), .pi)
    }

    func test_pi_wrapper_delegates_via_zentty_launch() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapperPath = repoRoot
            .appendingPathComponent("ZenttyResources/bin/pi/pi")
            .path
        let script = try String(contentsOfFile: wrapperPath, encoding: .utf8)

        XCTAssertTrue(script.contains("exec \"$cli_bin\" launch pi \"$@\""))
        XCTAssertTrue(script.contains("find_real_pi"))
    }

    func test_kimi_wrapper_delegates_to_shared_agent_wrapper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapperPath = repoRoot
            .appendingPathComponent("ZenttyResources/bin/kimi/kimi")
            .path
        let script = try String(contentsOfFile: wrapperPath, encoding: .utf8)

        XCTAssertTrue(script.contains("ZENTTY_AGENT_TOOL=\"kimi\""))
        XCTAssertTrue(script.contains("zentty-agent-wrapper"))
    }

    // MARK: - Environment

    func test_missing_worklane_id_throws() throws {
        let json = #"{"version": 1, "event": "agent.running"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let env = ["ZENTTY_PANE_ID": "pane-1"]

        XCTAssertThrowsError(try AgentEventBridge.makePayloads(from: input, environment: env))
    }

    func test_missing_pane_id_throws() throws {
        let json = #"{"version": 1, "event": "agent.running"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let env = ["ZENTTY_WORKLANE_ID": "worklane-1"]

        XCTAssertThrowsError(try AgentEventBridge.makePayloads(from: input, environment: env))
    }

    func test_unknown_event_throws() throws {
        let json = #"{"version": 1, "event": "unknown.event"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)

        XCTAssertThrowsError(try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment))
    }

    func test_pane_and_worklane_ids_from_environment() throws {
        let json = #"{"version": 1, "event": "agent.running"}"#
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        XCTAssertEqual(payloads[0].worklaneID, WorklaneID("worklane-1"))
        XCTAssertEqual(payloads[0].paneID, PaneID("pane-1"))
        XCTAssertEqual(payloads[0].windowID, WindowID("window-1"))
    }

    // MARK: - Session Hierarchy

    func test_parent_session_id_propagated() throws {
        let json = """
        {
          "version": 1,
          "event": "session.start",
          "session": { "id": "child-1", "parentId": "parent-1" },
          "agent": { "name": "Subagent" }
        }
        """
        let input = try AgentEventBridge.parseInput(json.data(using: .utf8)!)
        let payloads = try AgentEventBridge.makePayloads(from: input, environment: defaultEnvironment)

        let lifecycle = payloads.first { $0.signalKind == .lifecycle }
        XCTAssertEqual(lifecycle?.sessionID, "child-1")
        XCTAssertEqual(lifecycle?.parentSessionID, "parent-1")
    }

    // MARK: - Codex Adapter

    func test_codex_adapter_session_start_with_pid() throws {
        let json = #"{"hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp", "transcript_path": "/tmp/codex.jsonl"}"#
        let env = codexEnvironment(pid: "42")
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: env)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 42)
        XCTAssertEqual(payloads[0].pidEvent, .attach)
        XCTAssertEqual(payloads[1].state, .starting)
        XCTAssertEqual(payloads[1].toolName, "Codex")
        XCTAssertEqual(payloads[1].agentTranscriptPath, "/tmp/codex.jsonl")
    }

    func test_codex_adapter_event_from_cli_arg() throws {
        let payloads = try AgentEventBridge.codexAdapter(data: Data(), defaultEventName: "session-start", environment: codexEnvironment())
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .starting)
    }

    func test_codex_hook_permission_request_default_event_maps_to_needs_input_approval() throws {
        let payloads = try AgentEventBridge.codexAdapter(data: Data(), defaultEventName: "permission-request", environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].toolName, "Codex")
        XCTAssertEqual(payloads[0].text, "Codex needs your approval")
    }

    func test_codex_hook_permission_request_for_request_user_input_uses_question_text() throws {
        let json = """
        {
          "hook_event_name": "PermissionRequest",
          "session_id": "s1",
          "tool_name": "request_user_input",
          "tool_input": {
            "questions": [{
              "question": "What should Codex do next?",
              "options": [{"label": "Fix"}, {"label": "Explain"}]
            }]
          }
        }
        """

        let payloads = try AgentEventBridge.codexAdapter(data: Data(json.utf8), defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .decision)
        XCTAssertEqual(payloads[0].text, "What should Codex do next?\n[Fix] [Explain]")
    }

    func test_codex_hook_pre_tool_use_for_request_user_input_uses_question_text() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s1",
          "transcript_path": "/tmp/codex.jsonl",
          "tool_name": "request_user_input",
          "tool_input": {
            "questions": [{
              "question": "Which would you rather have right now?",
              "options": [{"label": "Good coffee"}, {"label": "Quiet hour"}]
            }]
          }
        }
        """

        let payloads = try AgentEventBridge.codexAdapter(data: Data(json.utf8), defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .decision)
        XCTAssertEqual(payloads[0].text, "Which would you rather have right now?\n[Good coffee] [Quiet hour]")
        XCTAssertEqual(payloads[0].agentTranscriptPath, "/tmp/codex.jsonl")
    }

    func test_codex_hook_permission_request_for_non_question_tool_ignores_question_shaped_input() throws {
        let json = """
        {
          "hook_event_name": "PermissionRequest",
          "session_id": "s1",
          "tool_name": "Bash",
          "tool_input": {
            "questions": [{
              "question": "Misleading nested field?",
              "options": [{"label": "Yes"}]
            }]
          }
        }
        """

        let payloads = try AgentEventBridge.codexAdapter(data: Data(json.utf8), defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Codex needs your approval")
    }

    func test_codex_notify_ignores_automatic_approval_review_success() throws {
        let json = """
        {
          "type": "notification",
          "message": "Automatic approval review approved (risk: low, authorization: unknown): Auto-review returned a low-risk allow decision."
        }
        """

        let payloads = try AgentEventBridge.codexNotifyAdapter(data: Data(json.utf8), environment: codexEnvironment())

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_codex_notify_ignores_auto_reviewer_approved_success() throws {
        let json = """
        {
          "type": "notification",
          "message": "Auto-reviewer approved codex to run TEST_RUNNER_SWIFT_BACKTRACE=enable=no xcodebuild test -scheme Zentty this time"
        }
        """

        let payloads = try AgentEventBridge.codexNotifyAdapter(data: Data(json.utf8), environment: codexEnvironment())

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_codex_notify_permission_request_still_maps_to_approval() throws {
        let json = """
        {
          "type": "permission-request",
          "message": "Codex needs your approval to run xcodebuild test"
        }
        """

        let payloads = try AgentEventBridge.codexNotifyAdapter(data: Data(json.utf8), environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Codex needs your approval to run xcodebuild test")
    }

    func test_codex_adapter_prompt_submit() throws {
        let json = #"{"hook_event_name": "UserPromptSubmit", "transcript_path": "/tmp/codex.jsonl"}"#
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].agentTranscriptPath, "/tmp/codex.jsonl")
    }

    func test_codex_adapter_stop() throws {
        let json = #"{"hook_event_name": "Stop"}"#
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .turnComplete)
    }

    // MARK: - Kimi Adapter

    func test_kimi_adapter_session_start_with_pid() throws {
        let json = #"{"hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp"}"#
        let env = kimiEnvironment(pid: "42")
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: env)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 42)
        XCTAssertEqual(payloads[0].pidEvent, .attach)
        XCTAssertEqual(payloads[1].state, .starting)
        XCTAssertEqual(payloads[1].toolName, "Kimi")
    }

    func test_kimi_adapter_user_prompt_submit() throws {
        let json = #"{"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/project"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].sessionID, "s1")
        XCTAssertEqual(payloads[0].agentWorkingDirectory, "/tmp/project")
    }

    func test_kimi_adapter_stop() throws {
        let json = #"{"hook_event_name": "Stop", "session_id": "s1"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .update)
    }

    func test_kimi_adapter_session_end_clears_status_and_pid_mapping() throws {
        let json = #"{"hook_event_name": "SessionEnd", "session_id": "s1"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .lifecycle)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertNil(payloads[1].pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
    }

    func test_kimi_adapter_permission_prompt_notification_maps_to_needs_input_payload() throws {
        let json = #"{"hook_event_name": "Notification", "session_id": "s1", "cwd": "/tmp/project", "notification_type": "permission_prompt", "title": "Allow edit", "body": "project.yml"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Allow edit")
        XCTAssertEqual(payloads[0].agentWorkingDirectory, "/tmp/project")
    }

    func test_kimi_adapter_pre_tool_use_ask_user_question_maps_to_question_payload() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp/project","tool_name":"AskUserQuestion","tool_input":{"question":"Which file?"}}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .question)
        XCTAssertEqual(payloads[0].text, "Which file?")
    }

    func test_kimi_adapter_pre_tool_use_str_replace_file_maps_to_approval_payload() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp/project","tool_name":"StrReplaceFile","tool_input":{"path":"README.md"}}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "StrReplaceFile is requesting approval to edit file: README.md")
    }

    func test_kimi_adapter_post_tool_use_ask_user_question_restores_running_payload() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp/project","tool_name":"AskUserQuestion"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    func test_kimi_adapter_post_tool_use_str_replace_file_restores_running_payload() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp/project","tool_name":"StrReplaceFile"}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    func test_kimi_adapter_pre_tool_use_read_file_is_noop() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp/project","tool_name":"ReadFile","tool_input":{"path":"README.md"}}"#
        let payloads = try AgentEventBridge.kimiAdapter(data: json.data(using: .utf8)!, environment: kimiEnvironment())

        XCTAssertTrue(payloads.isEmpty)
    }

    // MARK: - Copilot Adapter

    func test_copilot_adapter_session_start_seeds_idle() throws {
        let json = #"{"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd": "/tmp/project"}"#
        let env = copilotEnvironment(pid: "99")
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "session-start", environment: env)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 99)
        XCTAssertEqual(payloads[0].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(payloads[1].state, .idle)
        XCTAssertEqual(payloads[1].interactionKind, .none)
        XCTAssertEqual(payloads[1].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_adapter_pre_tool_use_question() throws {
        let json = #"{"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","toolName": "AskUserQuestion", "toolArgs": "{\"question\": \"Which file?\"}"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "pre-tool-use", environment: copilotEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .question)
        XCTAssertEqual(payloads[0].text, "Which file?")
        XCTAssertEqual(payloads[0].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_adapter_pre_tool_use_non_question_is_noop() throws {
        let json = #"{"toolName": "ReadFile"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "pre-tool-use", environment: copilotEnvironment())
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_copilot_adapter_post_tool_use_question_resets_to_idle() throws {
        let json = #"{"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","toolName": "AskUserQuestion"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "post-tool-use", environment: copilotEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].interactionKind, .none)
        XCTAssertEqual(payloads[0].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_adapter_session_end_clears() throws {
        let json = #"{"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "session-end", environment: copilotEnvironment())
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(payloads[0].clearsStatus)
        XCTAssertEqual(payloads[0].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
        XCTAssertEqual(payloads[1].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_adapter_user_prompt_marks_session_running() throws {
        let json = #"{"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "user-prompt-submitted", environment: copilotEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
        XCTAssertEqual(payloads[0].sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(payloads[0].agentWorkingDirectory, "/tmp/project")
    }

    // MARK: - Claude Adapter

    func test_claude_adapter_session_start_attaches_pid() throws {
        let json = #"{"hook_event_name": "SessionStart", "session_id": "cs1"}"#
        let env = claudeEnvironment(pid: "55")
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: env)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 55)
        XCTAssertEqual(payloads[0].pidEvent, .attach)
    }

    func test_claude_adapter_stop_transitions_to_idle() throws {
        let json = #"{"hook_event_name": "Stop", "session_id": "cs1"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .update)
    }

    func test_claude_adapter_subagent_stop_is_regular_update() throws {
        let json = #"{"hook_event_name": "SubagentStop", "session_id": "cs1"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .update)
    }

    func test_claude_adapter_user_prompt_submit_sets_running() throws {
        let json = #"{"hook_event_name": "UserPromptSubmit", "session_id": "cs1"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    func test_claude_adapter_pre_tool_use_ask_user_question() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "cs1",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [{"question": "Which approach?", "options": [{"label": "A"}, {"label": "B"}]}]
          }
        }
        """
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .decision)
        XCTAssertTrue(payloads[0].text?.contains("Which approach?") ?? false)
    }

    func test_claude_adapter_pre_tool_use_regular_tool_sets_running() throws {
        let json = #"{"hook_event_name": "PreToolUse", "session_id": "cs1", "tool_name": "Edit"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads[0].state, .running)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    func test_claude_adapter_permission_request_approval() throws {
        let json = #"{"hook_event_name": "PermissionRequest", "session_id": "cs1", "tool_name": "Bash", "message": "Run npm install?"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())

        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .approval)
        XCTAssertEqual(payloads[0].text, "Run npm install?")
    }

    func test_claude_adapter_unknown_event_returns_empty() throws {
        let json = #"{"hook_event_name": "SomeNewEvent"}"#
        let payloads = try AgentEventBridge.claudeAdapter(data: json.data(using: .utf8)!, environment: claudeEnvironment())
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_run_invalid_claude_adapter_payload_fails_open() {
        var postedPayloads: [AgentStatusPayload] = []
        var wroteError = false
        let exitCode = AgentEventBridge.run(
            arguments: ["zentty-agent", "agent-event", "--adapter=claude"],
            environment: claudeEnvironment(),
            inputData: Data("not-json".utf8),
            post: { postedPayloads.append($0) },
            writeError: { _ in wroteError = true }
        )

        XCTAssertEqual(exitCode, EXIT_SUCCESS)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertFalse(wroteError)
    }

    func test_run_invalid_codex_adapter_payload_fails_closed() {
        var postedPayloads: [AgentStatusPayload] = []
        var wroteError = false
        let exitCode = AgentEventBridge.run(
            arguments: ["zentty-agent", "agent-event", "--adapter=codex"],
            environment: codexEnvironment(),
            inputData: Data("not-json".utf8),
            post: { postedPayloads.append($0) },
            writeError: { _ in wroteError = true }
        )

        XCTAssertEqual(exitCode, EXIT_FAILURE)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertTrue(wroteError)
    }

    // MARK: - Adapter Test Helpers

    private func codexEnvironment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_CODEX_PID"] = pid }
        return env
    }

    private func kimiEnvironment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_KIMI_PID"] = pid }
        return env
    }

    private func copilotEnvironment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_COPILOT_PID"] = pid }
        return env
    }

    private func claudeEnvironment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_CLAUDE_PID"] = pid }
        return env
    }

    private func droidEnvironment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_DROID_PID"] = pid }
        return env
    }

    private func makeDroidTaskStore() throws -> DroidTaskStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        return DroidTaskStore(stateURL: directoryURL.appendingPathComponent("droid-task-sessions.json"))
    }

    private func makeCursorTaskStore() throws -> CursorTaskStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        return CursorTaskStore(stateURL: directoryURL.appendingPathComponent("cursor-task-sessions.json"))
    }

    // MARK: - Droid Task Progress

    func test_droid_preToolUse_Task_increments_total() throws {
        let store = try makeDroidTaskStore()
        let json = #"{"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Task","cwd":"/tmp"}"#
        let payloads = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))
    }

    func test_droid_preToolUse_nonTask_preserves_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        let json = #"{"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Edit","cwd":"/tmp"}"#
        let payloads = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))
    }

    func test_droid_preToolUse_todoWrite_string_reports_exact_progress() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"TodoWrite","cwd":"/tmp","tool_input":{"todos":"1. [completed] Review logs\\n2. [in_progress] Patch adapter\\n3. [pending] Run tests"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_droid_preToolUse_todoWrite_array_reports_exact_progress() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"TodoWrite","cwd":"/tmp","tool_input":{"todos":[{"content":"Review logs","status":"completed"},{"content":"Patch adapter","status":"in_progress"},{"content":"Run tests","status":"pending"}]}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_droid_preToolUse_todoWrite_accepts_camel_case_tool_input() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"TodoWrite","cwd":"/tmp","toolInput":{"todos":"- [x] Review logs\\n- [ ] Run tests"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_droid_preToolUse_todoWrite_unrecognized_string_preserves_existing_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"TodoWrite","cwd":"/tmp","tool_input":{"todos":"Review logs\\nRun tests"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))
    }

    func test_droid_preToolUse_todoWrite_empty_list_hides_stale_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.updateProgress(sessionID: "sess-1", doneCount: 1, totalCount: 3)
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"TodoWrite","cwd":"/tmp","tool_input":{"todos":[]}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 1))
        XCTAssertNil(try store.taskProgress(sessionID: "sess-1"))
    }

    func test_droid_subagent_events_do_not_mutate_todo_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.updateProgress(sessionID: "sess-1", doneCount: 1, totalCount: 3)

        let taskJSON = #"{"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Task","cwd":"/tmp"}"#
        let taskPayloads = try AgentEventBridge.droidAdapter(data: Data(taskJSON.utf8), environment: droidEnvironment(), taskStore: store)
        XCTAssertEqual(try XCTUnwrap(taskPayloads.first).taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))

        let stopJSON = #"{"hook_event_name":"SubagentStop","session_id":"sess-1","cwd":"/tmp"}"#
        let stopPayloads = try AgentEventBridge.droidAdapter(data: Data(stopJSON.utf8), environment: droidEnvironment(), taskStore: store)
        XCTAssertEqual(try XCTUnwrap(stopPayloads.first).taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_droid_preToolUse_askUser_reports_question() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"AskUser","cwd":"/tmp","tool_input":{"question":"Choose a target?","options":["Staging","Production"]}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Choose a target?\n- Staging\n- Production")
    }

    func test_droid_preToolUse_exitSpecMode_reports_approval() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"ExitSpecMode","cwd":"/tmp","tool_input":{"plan":"Add Droid CLI to the agent-aware feature list\\n\\nDetails follow..."}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Droid proposed a spec: Add Droid CLI to the agent-aware feature list")
    }

    func test_droid_preToolUse_exitSpecMode_without_plan_falls_back() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"ExitSpecMode","cwd":"/tmp","tool_input":{}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Droid drafted a specification for your approval")
    }

    func test_droid_postToolUse_exitSpecMode_emits_nothing() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"sess-1","tool_name":"ExitSpecMode","permission_mode":"spec","cwd":"/tmp","tool_input":{"plan":"Some spec"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_droid_stop_in_spec_mode_emits_nothing() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"Stop","session_id":"sess-1","permission_mode":"spec","cwd":"/tmp"}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_droid_stop_in_off_mode_still_idles() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"Stop","session_id":"sess-1","permission_mode":"off","cwd":"/tmp"}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .idle)
    }

    func test_droid_postToolUse_non_exitSpec_still_running() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"sess-1","tool_name":"Read","permission_mode":"spec","cwd":"/tmp","tool_input":{"file_path":"/tmp/README.md"},"tool_response":"ok"}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
    }

    func test_droid_preToolUse_manual_execute_reports_approval() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Execute","permission_mode":"off","cwd":"/tmp","tool_input":{"command":"xcodebuild test"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Allow Execute: xcodebuild test")
    }

    func test_droid_preToolUse_auto_execute_stays_running() throws {
        let store = try makeDroidTaskStore()
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Execute","permission_mode":"auto-low","cwd":"/tmp","tool_input":{"command":"ls"}}
        """
        let payloads = try AgentEventBridge.droidAdapter(data: Data(json.utf8), environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertNil(payload.interactionKind)
    }

    func test_droid_subagentStop_increments_done() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        _ = try store.taskCreated(sessionID: "sess-1")
        let json = #"{"hook_event_name":"SubagentStop","session_id":"sess-1","cwd":"/tmp"}"#
        let payloads = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_droid_task_full_lifecycle() throws {
        let store = try makeDroidTaskStore()
        let env = droidEnvironment()

        // Create 3 tasks
        for _ in 1...3 {
            let json = #"{"hook_event_name":"PreToolUse","session_id":"sess-1","tool_name":"Task","cwd":"/tmp"}"#
            _ = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: env, taskStore: store)
        }

        let progress1 = try store.taskProgress(sessionID: "sess-1")
        XCTAssertEqual(progress1, PaneAgentTaskProgress(doneCount: 0, totalCount: 3))

        // Complete 2 tasks
        for _ in 1...2 {
            let json = #"{"hook_event_name":"SubagentStop","session_id":"sess-1","cwd":"/tmp"}"#
            _ = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: env, taskStore: store)
        }

        let progress2 = try store.taskProgress(sessionID: "sess-1")
        XCTAssertEqual(progress2, PaneAgentTaskProgress(doneCount: 2, totalCount: 3))

        // Complete last task
        let json = #"{"hook_event_name":"SubagentStop","session_id":"sess-1","cwd":"/tmp"}"#
        _ = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: env, taskStore: store)

        let progress3 = try store.taskProgress(sessionID: "sess-1")
        XCTAssertEqual(progress3, PaneAgentTaskProgress(doneCount: 3, totalCount: 3))
    }

    func test_droid_sessionEnd_clears_task_progress() throws {
        let store = try makeDroidTaskStore()
        let env = droidEnvironment()

        _ = try store.taskCreated(sessionID: "sess-1")
        _ = try store.taskCreated(sessionID: "sess-1")

        let json = #"{"hook_event_name":"SessionEnd","session_id":"sess-1"}"#
        _ = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: env, taskStore: store)

        let progress = try store.taskProgress(sessionID: "sess-1")
        XCTAssertNil(progress)
    }

    func test_droid_task_store_reads_entries_without_source() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }

        let stateURL = directoryURL.appendingPathComponent("droid-task-sessions.json")
        let stateJSON = #"{"sessions":{"sess-1":{"doneCount":1,"totalCount":3,"updatedAt":123}}}"#
        try Data(stateJSON.utf8).write(to: stateURL)

        let store = DroidTaskStore(stateURL: stateURL)
        XCTAssertEqual(try store.taskProgress(sessionID: "sess-1"), PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_droid_stop_carries_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        let json = #"{"hook_event_name":"Stop","session_id":"sess-1","cwd":"/tmp"}"#
        let payloads = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))
    }

    func test_droid_notification_carries_progress() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        _ = try store.taskCompleted(sessionID: "sess-1")
        _ = try store.taskCreated(sessionID: "sess-1")
        let json = #"{"hook_event_name":"Notification","session_id":"sess-1","message":"Droid needs permission","cwd":"/tmp"}"#
        let payloads = try AgentEventBridge.droidAdapter(data: json.data(using: .utf8)!, environment: droidEnvironment(), taskStore: store)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_droid_doneCount_clamps_to_totalCount() throws {
        let store = try makeDroidTaskStore()
        _ = try store.taskCreated(sessionID: "sess-1")
        _ = try store.taskCompleted(sessionID: "sess-1")
        // Extra SubagentStop beyond total should not exceed totalCount
        _ = try store.taskCompleted(sessionID: "sess-1")
        let progress = try store.taskProgress(sessionID: "sess-1")
        XCTAssertEqual(progress, PaneAgentTaskProgress(doneCount: 1, totalCount: 1))
    }
}
