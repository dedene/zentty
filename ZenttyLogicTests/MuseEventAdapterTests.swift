import Foundation
import XCTest
@testable import Zentty

/// Muse Code hooks are Claude Code-format compatible; these tests pin the
/// differences that motivated a dedicated adapter, using payload shapes
/// captured from muse 1.4.6: hooks fire for every thread (root, delegated
/// subagents, internal `*-reminder` agents that run after the root Stop),
/// todos only arrive through `PostToolBatch`, and `ToolUseStart` marks an
/// answered approval.
final class MuseEventAdapterTests: XCTestCase {

    private static let rootSessionID = "01a1312e-945c-7e90-9dbd-0ea0522f8119"
    private static let childSessionID = "01a1312f-40eb-7c11-8b1b-ecf60c31ed73"
    private static let reminderSessionID = "36e44e2f-65dd-4489-a3a3-e5bdb533d81e"

    private final class Harness {
        let sessionStore: ClaudeHookSessionStore
        let subagentStore: AgentSubagentRegistryStore
        var environment: [String: String]

        init(environment: [String: String]) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zentty-muse-bridge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessionStore = ClaudeHookSessionStore(
                stateURL: directory.appendingPathComponent("muse-hook-sessions.json", isDirectory: false)
            )
            subagentStore = AgentSubagentRegistryStore(
                stateURL: directory.appendingPathComponent("muse-subagent-sessions.json", isDirectory: false),
                transcriptModificationDate: { _ in nil }
            )
            self.environment = environment
        }

        func payloads(for json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.museAdapter(
                data: Data(json.utf8),
                environment: environment,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }

        /// SessionStart + UserPromptSubmit for the root session.
        func startTurn() throws {
            _ = try payloads(for: #"{"hook_event_name":"SessionStart","source":"startup","session_id":"\#(MuseEventAdapterTests.rootSessionID)","cwd":"/tmp/project","model":"muse-spark-1.2"}"#)
            _ = try payloads(for: #"{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"\#(MuseEventAdapterTests.rootSessionID)","turn_id":"t-1"}"#)
        }
    }

    private func makeHarness(pid: String? = nil) throws -> Harness {
        var environment = [
            "ZENTTY_WORKLANE_ID": "worklane-1",
            "ZENTTY_PANE_ID": "pane-1",
            "ZENTTY_WINDOW_ID": "window-1",
            "MUSE_SESSION_ID": Self.rootSessionID,
        ]
        if let pid { environment["ZENTTY_MUSE_PID"] = pid }
        return try Harness(environment: environment)
    }

    // MARK: - Lifecycle

    func test_muse_adapter_fails_open_on_malformed_payload() {
        var postedPayloads: [AgentStatusPayload] = []
        var loggedErrors: [String] = []

        let result = AgentEventBridge.run(
            arguments: ["zentty", "agent-event", "--adapter=muse"],
            environment: ["ZENTTY_WORKLANE_ID": "worklane-1", "ZENTTY_PANE_ID": "pane-1"],
            inputData: Data("{ not valid json".utf8),
            post: { postedPayloads.append($0) },
            writeError: { loggedErrors.append(String(describing: $0)) }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertTrue(postedPayloads.isEmpty)
        XCTAssertTrue(loggedErrors.isEmpty)
    }

    func test_muse_adapter_session_start_attaches_session_and_pid() throws {
        let harness = try makeHarness(pid: "4242")
        let payloads = try harness.payloads(for: #"{"hook_event_name":"SessionStart","source":"startup","session_id":"\#(Self.rootSessionID)","cwd":"/tmp/project"}"#)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].state, .starting)
        XCTAssertEqual(payloads[0].toolName, "Muse Code")
        XCTAssertEqual(payloads[0].sessionID, Self.rootSessionID)
        XCTAssertEqual(payloads[0].agentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pid, 4242)
        XCTAssertEqual(payloads[1].pidEvent, .attach)
    }

    func test_muse_adapter_prompt_tools_and_stop_drive_running_then_idle() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"\#(Self.rootSessionID)"}"#)

        let prompt = try harness.payloads(for: #"{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(prompt.first?.state, .running)

        let pre = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_use_id":"call_1","tool_input":{"command":"ls"},"session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(pre.first?.state, .running)
        let post = try harness.payloads(for: #"{"hook_event_name":"PostToolUse","tool_name":"bash","tool_use_id":"call_1","tool_response":"{}","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(post.first?.state, .running)

        let stop = try harness.payloads(for: #"{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop[0].state, .idle)
        XCTAssertEqual(stop[0].toolName, "Muse Code")
    }

    func test_muse_adapter_interrupt_and_stop_failure_go_idle() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        XCTAssertEqual(try harness.payloads(for: #"{"hook_event_name":"Interrupt","session_id":"\#(Self.rootSessionID)"}"#).first?.state, .idle)

        _ = try harness.payloads(for: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(try harness.payloads(for: #"{"hook_event_name":"StopFailure","session_id":"\#(Self.rootSessionID)"}"#).first?.state, .idle)
    }

    func test_muse_adapter_session_end_clears_state_and_pid() throws {
        let harness = try makeHarness(pid: "4242")
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"\#(Self.rootSessionID)"}"#)

        let payloads = try harness.payloads(for: #"{"hook_event_name":"SessionEnd","reason":"other","session_id":"\#(Self.rootSessionID)"}"#)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[0].sessionID, Self.rootSessionID)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: Self.rootSessionID))
    }

    func test_muse_adapter_compaction_reports_compacting() throws {
        let harness = try makeHarness()
        try harness.startTurn()

        let pre = try harness.payloads(for: #"{"hook_event_name":"PreCompact","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(pre.first?.state, .running)
        XCTAssertEqual(pre.first?.text, "Compacting")
        let post = try harness.payloads(for: #"{"hook_event_name":"PostCompact","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(post.first?.state, .running)
        XCTAssertNil(post.first?.text)
    }

    // MARK: - Child threads

    /// Reminder agents keep running after the root Stop; their tool calls
    /// must not pull the idle pane back to running.
    func test_muse_adapter_ignores_reminder_threads_after_root_stop() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"\#(Self.rootSessionID)"}"#)

        let reminderEvents = [
            #"{"hook_event_name":"SubagentStart","subagent_id":"goal-reminder","child_session_id":"\#(Self.reminderSessionID)","session_id":"\#(Self.reminderSessionID)"}"#,
            #"{"hook_event_name":"PreToolUse","tool_name":"submit_reminder_decision","tool_use_id":"call_r","tool_input":{"decision":"none"},"session_id":"\#(Self.reminderSessionID)"}"#,
            #"{"hook_event_name":"PostToolUse","tool_name":"submit_reminder_decision","tool_use_id":"call_r","session_id":"\#(Self.reminderSessionID)"}"#,
            #"{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"submit_reminder_decision"}],"session_id":"\#(Self.reminderSessionID)"}"#,
            #"{"hook_event_name":"SubagentStop","subagent_id":"goal-reminder","child_session_id":"\#(Self.reminderSessionID)","session_id":"\#(Self.reminderSessionID)"}"#,
        ]
        for event in reminderEvents {
            XCTAssertTrue(try harness.payloads(for: event).isEmpty, event)
        }
        XCTAssertEqual(try harness.subagentStore.summary(key: museKey())?.count ?? 0, 0)
    }

    func test_muse_adapter_delegated_subagent_tracks_badge_and_ignores_child_tools() throws {
        let harness = try makeHarness()
        try harness.startTurn()

        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"subagent_spawn","tool_use_id":"call_s","tool_input":{"command_id":"list-files-001","objective":"List files","role":"assistant"},"session_id":"\#(Self.rootSessionID)"}"#)
        let start = try harness.payloads(for: #"{"hook_event_name":"SubagentStart","subagent_id":"01a1312f-40aa-7e01-9b4d-da199d66bece","child_session_id":"\#(Self.childSessionID)","session_id":"\#(Self.childSessionID)","model":"muse-spark-1.2"}"#)
        XCTAssertEqual(start.first?.state, .running)
        XCTAssertEqual(start.first?.subagents?.count, 1)
        XCTAssertEqual(start.first?.subagents?.entries.first?.model, "muse-spark-1.2")
        // SubagentStart has no type; the spawn call's role supplies it.
        XCTAssertEqual(start.first?.subagents?.entries.first?.agentType, "assistant")

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_use_id":"call_c","tool_input":{"command":"ls"},"session_id":"\#(Self.childSessionID)"}"#).isEmpty)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","tool_name":"bash","tool_use_id":"call_c","session_id":"\#(Self.childSessionID)"}"#).isEmpty)

        let stop = try harness.payloads(for: #"{"hook_event_name":"SubagentStop","subagent_id":"01a1312f-40aa-7e01-9b4d-da199d66bece","child_session_id":"\#(Self.childSessionID)","session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(stop.first?.state, .running)
        XCTAssertEqual(stop.first?.subagents?.count, 0)
    }

    /// A background subagent finishing after the parent's turn ended updates
    /// the badge but keeps the pane idle.
    func test_muse_adapter_subagent_stop_after_parent_stop_stays_idle() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"SubagentStart","subagent_id":"sub-1","session_id":"\#(Self.childSessionID)"}"#)

        let parentStop = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(parentStop.first?.state, .idle)
        XCTAssertEqual(parentStop.first?.subagents?.count, 1)

        let childStop = try harness.payloads(for: #"{"hook_event_name":"SubagentStop","subagent_id":"sub-1","session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(childStop.first?.state, .idle)
        XCTAssertEqual(childStop.first?.subagents?.count, 0)
    }

    func test_muse_adapter_untracked_subagent_stop_is_ignored() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"SubagentStop","subagent_id":"never-started","session_id":"\#(Self.childSessionID)"}"#).isEmpty)
    }

    // MARK: - Interactions

    func test_muse_adapter_permission_request_then_tool_use_start_resolves_approval() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_use_id":"call_1","tool_input":{"command":"echo ok > probe.txt"},"session_id":"\#(Self.rootSessionID)"}"#)

        let request = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","tool_input":{"command":"echo ok > probe.txt"},"session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(request.first?.state, .needsInput)
        XCTAssertEqual(request.first?.interactionKind, .approval)
        XCTAssertEqual(request.first?.text, "Muse Code wants to run bash: echo ok > probe.txt")

        let notification = try harness.payloads(for: #"{"notification_type":"permission_prompt","title":"Muse Code needs approval","message":"ws — waiting for approval","hook_event_name":"Notification","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(notification.first?.state, .needsInput)
        XCTAssertEqual(notification.first?.text, "Muse Code wants to run bash: echo ok > probe.txt")

        let started = try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"bash","tool_use_id":"call_1","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(started.first?.state, .running)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind)
    }

    /// Reminder agents keep starting their decision tool while the root's
    /// approval prompt is open; that must not count as the answer.
    func test_muse_adapter_reminder_tool_start_keeps_pending_approval() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","tool_input":{"command":"printf ok"},"session_id":"\#(Self.rootSessionID)"}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"submit_reminder_decision","tool_input":{"decision":"none"},"session_id":"\#(Self.reminderSessionID)"}"#).isEmpty)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"submit_reminder_decision","tool_use_id":"call_r","session_id":"\#(Self.reminderSessionID)"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind, .approval)

        let started = try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"bash","tool_use_id":"call_1","session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(started.first?.state, .running)
    }

    func test_muse_adapter_tool_use_start_without_pending_approval_is_ignored() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"\#(Self.rootSessionID)"}"#)

        // An async ToolUseStart landing after Stop must not revive the pane.
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"bash","tool_use_id":"call_1","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
    }

    func test_muse_adapter_subagent_permission_request_blocks_pane() throws {
        let harness = try makeHarness()
        try harness.startTurn()

        let request = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","tool_input":{"command":"rm -rf build"},"session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(request.first?.state, .needsInput)
        XCTAssertEqual(request.first?.sessionID, Self.rootSessionID)

        let started = try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"bash","tool_use_id":"call_c","session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(started.first?.state, .running)
    }

    /// A subagent's approval belongs to its thread: the root's own tool
    /// traffic must not answer it, the child's own completion does.
    func test_muse_adapter_child_approval_is_scoped_to_its_thread() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","tool_input":{"command":"rm -rf build"},"session_id":"\#(Self.childSessionID)"}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","tool_name":"bash","tool_use_id":"root_call","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"ToolUseStart","tool_name":"bash","tool_use_id":"root_call","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind, .approval)

        // Denied, the child carries on: its next completion clears the prompt.
        let carriedOn = try harness.payloads(for: #"{"hook_event_name":"PostToolUseFailure","tool_name":"bash","tool_use_id":"call_c","session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(carriedOn.first?.state, .running)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind)
    }

    func test_muse_adapter_subagent_stop_clears_its_open_approval() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"SubagentStart","subagent_id":"sub-1","child_session_id":"\#(Self.childSessionID)","session_id":"\#(Self.childSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","session_id":"\#(Self.childSessionID)"}"#)

        let stop = try harness.payloads(for: #"{"hook_event_name":"SubagentStop","subagent_id":"sub-1","child_session_id":"\#(Self.childSessionID)","session_id":"\#(Self.childSessionID)"}"#)

        XCTAssertEqual(stop.first?.state, .running)
        XCTAssertEqual(stop.first?.subagents?.count, 0)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind)
    }

    /// `Interrupt` is an async hook: one for the previous turn can land after
    /// the next prompt was submitted.
    func test_muse_adapter_late_interrupt_for_previous_turn_is_ignored() throws {
        let harness = try makeHarness()
        _ = try harness.payloads(for: #"{"hook_event_name":"SessionStart","session_id":"\#(Self.rootSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(Self.rootSessionID)","turn_id":"turn-1"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(Self.rootSessionID)","turn_id":"turn-2"}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"Interrupt","session_id":"\#(Self.rootSessionID)","turn_id":"turn-1"}"#).isEmpty)
        XCTAssertEqual(try harness.payloads(for: #"{"hook_event_name":"Interrupt","session_id":"\#(Self.rootSessionID)","turn_id":"turn-2"}"#).first?.state, .idle)
    }

    func test_muse_adapter_failed_spawn_does_not_label_next_subagent() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"subagent_spawn","tool_use_id":"spawn_1","tool_input":{"role":"reviewer"},"session_id":"\#(Self.rootSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PostToolUseFailure","tool_name":"subagent_spawn","tool_use_id":"spawn_1","session_id":"\#(Self.rootSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"subagent_spawn","tool_use_id":"spawn_2","tool_input":{"role":"assistant"},"session_id":"\#(Self.rootSessionID)"}"#)

        let start = try harness.payloads(for: #"{"hook_event_name":"SubagentStart","subagent_id":"sub-2","session_id":"\#(Self.childSessionID)"}"#)
        XCTAssertEqual(start.first?.subagents?.entries.first?.agentType, "assistant")
    }

    /// Without MUSE_SESSION_ID every event counts as the root's; reminder
    /// bookkeeping must still not revive an idle pane.
    func test_muse_adapter_ignores_reminder_tool_without_root_session_env() throws {
        let harness = try makeHarness()
        harness.environment["MUSE_SESSION_ID"] = nil
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"Stop","session_id":"\#(Self.rootSessionID)"}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"submit_reminder_decision","tool_use_id":"r","session_id":"\#(Self.reminderSessionID)"}"#).isEmpty)
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","tool_name":"submit_reminder_decision","tool_use_id":"r","session_id":"\#(Self.reminderSessionID)"}"#).isEmpty)
    }

    func test_muse_adapter_sibling_completion_preserves_pending_approval() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_use_id":"sibling","session_id":"\#(Self.rootSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_use_id":"call_1","session_id":"\#(Self.rootSessionID)"}"#)
        _ = try harness.payloads(for: #"{"hook_event_name":"PermissionRequest","tool_name":"bash","tool_input":{"command":"deploy"},"session_id":"\#(Self.rootSessionID)"}"#)

        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolUse","tool_name":"read_file","tool_use_id":"sibling","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind, .approval)
    }

    /// `request_user_input` fires no PreToolUse; the open question is only
    /// announced by a `question_prompt` notification and answered when the
    /// call completes in a PostToolBatch (captured from muse 1.4.6).
    func test_muse_adapter_question_prompt_until_answered_in_batch() throws {
        let harness = try makeHarness()
        try harness.startTurn()

        let question = try harness.payloads(for: #"{"notification_type":"question_prompt","title":"Muse Code needs your input","message":"ws — waiting for your answer","hook_event_name":"Notification","session_id":"\#(Self.rootSessionID)","turn_id":"t-1"}"#)
        XCTAssertEqual(question.first?.state, .needsInput)
        XCTAssertEqual(question.first?.interactionKind, .decision)
        XCTAssertEqual(question.first?.text, "Muse Code needs your input")

        // A reminder thread's batch does not answer the root's question.
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"request_user_input"}],"session_id":"\#(Self.reminderSessionID)"}"#).isEmpty)
        XCTAssertEqual(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind, .decision)

        let answered = try harness.payloads(for: #"{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"request_user_input","tool_input":{"questions":[{"question":"Which colour?"}]}}],"session_id":"\#(Self.rootSessionID)"}"#)
        XCTAssertEqual(answered.first?.state, .running)
        XCTAssertNil(answered.first?.taskProgress)
        XCTAssertNil(try harness.sessionStore.lookup(sessionID: Self.rootSessionID)?.structuredInteractionKind)
    }

    func test_muse_adapter_non_permission_notification_is_ignored() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
    }

    // MARK: - Tasks

    func test_muse_adapter_write_todos_batch_reports_progress() throws {
        let harness = try makeHarness()
        try harness.startTurn()

        let payloads = try harness.payloads(for: """
        {"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"write_todos","tool_input":{"todos":[
          {"text":"Review directory","status":"completed"},
          {"text":"Identify main language","status":"in_progress"},
          {"text":"Suggest one improvement","status":"pending"}
        ]},"tool_use_id":"call_t","tool_response":"{\\"ok\\":true}"}],"session_id":"\(Self.rootSessionID)"}
        """)

        let progress = try XCTUnwrap(payloads.first?.taskProgress)
        XCTAssertEqual(payloads.first?.state, .running)
        XCTAssertEqual(progress.doneCount, 1)
        XCTAssertEqual(progress.totalCount, 3)
        XCTAssertEqual(progress.items.map(\.title), ["Review directory", "Identify main language", "Suggest one improvement"])
    }

    func test_muse_adapter_batch_without_todos_is_ignored() throws {
        let harness = try makeHarness()
        try harness.startTurn()
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"bash"}],"session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
    }

    func test_muse_adapter_unknown_hook_event_returns_empty() throws {
        let harness = try makeHarness()
        XCTAssertTrue(try harness.payloads(for: #"{"hook_event_name":"PreLLMCall","session_id":"\#(Self.rootSessionID)"}"#).isEmpty)
    }

    private func museKey() -> AgentSubagentRegistryStore.Key {
        AgentSubagentRegistryStore.Key(tool: "muse", worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-1"))
    }
}
