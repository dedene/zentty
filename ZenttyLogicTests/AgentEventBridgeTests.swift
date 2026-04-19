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
        let json = #"{"hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp"}"#
        let env = codexEnvironment(pid: "42")
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: env)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 42)
        XCTAssertEqual(payloads[0].pidEvent, .attach)
        XCTAssertEqual(payloads[1].state, .starting)
        XCTAssertEqual(payloads[1].toolName, "Codex")
    }

    func test_codex_adapter_event_from_cli_arg() throws {
        let payloads = try AgentEventBridge.codexAdapter(data: Data(), defaultEventName: "session-start", environment: codexEnvironment())
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .starting)
    }

    func test_codex_adapter_prompt_submit() throws {
        let json = #"{"hook_event_name": "UserPromptSubmit"}"#
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .running)
    }

    func test_codex_adapter_stop() throws {
        let json = #"{"hook_event_name": "Stop"}"#
        let payloads = try AgentEventBridge.codexAdapter(data: json.data(using: .utf8)!, defaultEventName: nil, environment: codexEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].lifecycleEvent, .update)
    }

    // MARK: - Copilot Adapter

    func test_copilot_adapter_session_start_seeds_idle() throws {
        let json = #"{"cwd": "/tmp/project"}"#
        let env = copilotEnvironment(pid: "99")
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "session-start", environment: env)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .pid)
        XCTAssertEqual(payloads[0].pid, 99)
        XCTAssertEqual(payloads[1].state, .idle)
        XCTAssertEqual(payloads[1].interactionKind, .none)
    }

    func test_copilot_adapter_pre_tool_use_question() throws {
        let json = #"{"toolName": "AskUserQuestion", "toolArgs": "{\"question\": \"Which file?\"}"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "pre-tool-use", environment: copilotEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .needsInput)
        XCTAssertEqual(payloads[0].interactionKind, .question)
        XCTAssertEqual(payloads[0].text, "Which file?")
    }

    func test_copilot_adapter_pre_tool_use_non_question_is_noop() throws {
        let json = #"{"toolName": "ReadFile"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "pre-tool-use", environment: copilotEnvironment())
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_copilot_adapter_post_tool_use_question_resets_to_idle() throws {
        let json = #"{"toolName": "AskUserQuestion"}"#
        let payloads = try AgentEventBridge.copilotAdapter(data: json.data(using: .utf8)!, defaultEventName: "post-tool-use", environment: copilotEnvironment())

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].state, .idle)
        XCTAssertEqual(payloads[0].interactionKind, .none)
    }

    func test_copilot_adapter_session_end_clears() throws {
        let payloads = try AgentEventBridge.copilotAdapter(data: Data(), defaultEventName: "session-end", environment: copilotEnvironment())
        XCTAssertEqual(payloads.count, 1)
        XCTAssertTrue(payloads[0].clearsStatus)
    }

    func test_copilot_adapter_user_prompt_is_noop() throws {
        let payloads = try AgentEventBridge.copilotAdapter(data: Data(), defaultEventName: "user-prompt-submitted", environment: copilotEnvironment())
        XCTAssertTrue(payloads.isEmpty)
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
}
