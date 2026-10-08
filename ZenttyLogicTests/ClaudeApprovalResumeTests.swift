import Foundation
import XCTest
@testable import Zentty

/// Reproduces the "Needs input while Claude is clearly working" symptom.
///
/// Live agent-bench trace (claude/approval_then_work, Claude Code 2.1.261):
///
///   PreToolUse(Write) → PermissionRequest(Write) → [user approves] →
///   Write runs → Read runs → Grep runs → PreToolUse(Bash) → Stop
///
/// Between the approval and the next Bash/Write/Edit PreToolUse there were
/// eleven seconds with zero hook events. Only Enter, a PreToolUse for the
/// narrow matcher set, or Stop ever cleared the approval prompt. Approving
/// with `1`/`y` and then working through Read/Grep/Agent tools left the pane
/// on "Needs input" for the whole stretch.
///
/// These tests drive the real Claude adapter through a fresh session store
/// and assert the reduced status after each PostToolUse.
///
/// Payload shapes mirror Claude Code 2.1.261: `PermissionRequest` carries
/// `tool_name` and `tool_input` but no `tool_use_id`; `PostToolUse` /
/// `PostToolUseFailure` carry `tool_use_id`, and the failure variant adds
/// `is_interrupt`.
final class ClaudeApprovalResumeTests: XCTestCase {

    private let defaultEnvironment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-approval-resume",
        "ZENTTY_PANE_ID": "pane-approval-resume",
        "ZENTTY_WINDOW_ID": "window-approval-resume",
        "ZENTTY_CLAUDE_PID": "4242",
    ]

    private var sessionStore: ClaudeHookSessionStore!
    /// Temp-dir registry: the adapter must never touch the real
    /// ~/Library/Application Support state from a test.
    private var subagentStore: AgentSubagentRegistryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-approval-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        subagentStore = AgentSubagentRegistryStore(
            stateURL: directory.appendingPathComponent("agent-subagent-sessions.json", isDirectory: false),
            transcriptModificationDate: { _ in nil }
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test_post_tool_use_after_approval_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Write","tool_use_id":"tu-write"}"#, into: &reducer, at: base + 4.7)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Write","message":"Create file ZENTTY_OK?"}"#, into: &reducer, at: base + 4.72)

        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.interactionKind, .approval)

        // User approved with `1` (no Enter, so no userSubmittedInput event).
        // The approved tool finishes: PostToolUse is the first hook Claude
        // Code emits after the permission was resolved.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Write","tool_use_id":"tu-write","tool_response":{"success":true}}"#, into: &reducer, at: base + 10.8)

        let afterWrite = reducer.reducedStatus(now: base + 11)
        XCTAssertEqual(afterWrite?.state, .running, "PostToolUse for the approved tool must clear the approval prompt. Got \(String(describing: afterWrite?.state)) text=\(afterWrite?.text ?? "nil")")
        XCTAssertEqual(afterWrite?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertNil(afterWrite?.text)

        // Read/Grep never fire PreToolUse (narrow matcher); PostToolUse keeps
        // the pane on running.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 14)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Grep","tool_use_id":"tu-grep"}"#, into: &reducer, at: base + 18)
        XCTAssertEqual(reducer.reducedStatus(now: base + 19)?.state, .running)

        try replay(#"{"hook_event_name":"Stop","session_id":"s1"}"#, into: &reducer, at: base + 23.8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 24)?.state, .idle)
    }

    func test_unregistered_background_fork_stop_does_not_restart_completed_turn() throws {
        // Claude 2.1.276 generates an away recap after the user turn ends.
        // Its internal fork emits SubagentStop without SubagentStart; it is
        // not a worker whose result wakes the parent for more work.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"recap"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"recap"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"Stop","session_id":"recap"}"#, into: &reducer, at: base + 2)

        let stopped = reducer.sessionsByID
        let payloads = try makePayloads(#"{"hook_event_name":"SubagentStop","session_id":"recap","agent_id":"internal-recap","agent_type":"","agent_transcript_path":"/tmp/absent-recap.jsonl"}"#)
        XCTAssertTrue(payloads.isEmpty)
        for payload in payloads { reducer.apply(payload, now: base + 182) }
        XCTAssertEqual(reducer.sessionsByID, stopped)
        XCTAssertNotEqual(reducer.reducedStatus(now: base + 182)?.state, .running)

        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"recap"}"#, into: &reducer, at: base + 200)
        XCTAssertEqual(reducer.reducedStatus(now: base + 200)?.state, .running, "the next real prompt must still resume the parent")
    }

    func test_unregistered_fork_stop_preserves_parent_approval_and_live_worker() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"recap-approval"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"SubagentStart","session_id":"recap-approval","agent_id":"worker","agent_type":"general-purpose"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"recap-approval","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 2)

        let payloads = try makePayloads(#"{"hook_event_name":"SubagentStop","session_id":"recap-approval","agent_id":"internal-recap","agent_type":""}"#)
        XCTAssertTrue(payloads.isEmpty)
        for payload in payloads { reducer.apply(payload, now: base + 3) }
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "recap-approval")?.structuredInteractionKind, .approval)
        let key = AgentSubagentRegistryStore.Key(
            tool: "claude",
            worklaneID: WorklaneID("worklane-approval-resume"),
            paneID: PaneID("pane-approval-resume")
        )
        XCTAssertEqual(try subagentStore.summary(key: key)?.entries.map(\.id), ["worker"])
    }

    func test_registered_worker_stop_resumes_parent_but_duplicate_stop_does_not() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"worker-complete"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"SubagentStart","session_id":"worker-complete","agent_id":"worker","agent_type":"general-purpose"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"Stop","session_id":"worker-complete"}"#, into: &reducer, at: base + 2)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .idle)

        let stop = #"{"hook_event_name":"SubagentStop","session_id":"worker-complete","agent_id":"worker","agent_type":"general-purpose"}"#
        try replay(stop, into: &reducer, at: base + 3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.subagents, .empty)

        try replay(#"{"hook_event_name":"Stop","session_id":"worker-complete"}"#, into: &reducer, at: base + 4)
        XCTAssertTrue(try makePayloads(stop).isEmpty)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .idle)
    }

    func test_anonymous_stop_without_live_worker_does_not_restart_parent() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 1_000)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"anonymous-stop"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"anonymous-stop"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"Stop","session_id":"anonymous-stop"}"#, into: &reducer, at: base + 2)
        let missingID = #"{"hook_event_name":"SubagentStop","session_id":"anonymous-stop"}"#
        let blankID = #"{"hook_event_name":"SubagentStop","session_id":"anonymous-stop","agent_id":"  "}"#
        XCTAssertTrue(try makePayloads(missingID).isEmpty)
        XCTAssertTrue(try makePayloads(blankID).isEmpty)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .idle)

        try replay(#"{"hook_event_name":"SubagentStart","session_id":"anonymous-stop","agent_id":"worker"}"#, into: &reducer, at: base + 4)
        try replay(#"{"hook_event_name":"Stop","session_id":"anonymous-stop"}"#, into: &reducer, at: base + 5)
        try replay(missingID, into: &reducer, at: base + 6)
        XCTAssertEqual(reducer.reducedStatus(now: base + 6)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 6)?.subagents, .empty)
        try replay(#"{"hook_event_name":"Stop","session_id":"anonymous-stop"}"#, into: &reducer, at: base + 7)
        XCTAssertTrue(try makePayloads(missingID).isEmpty)
        XCTAssertEqual(reducer.reducedStatus(now: base + 8)?.state, .idle)
    }

    func test_registered_worker_stop_survives_quiet_transcript_pruning() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        subagentStore = AgentSubagentRegistryStore(
            stateURL: subagentStore.stateURL,
            now: { now },
            transcriptModificationDate: { _ in base }
        )
        let key = AgentSubagentRegistryStore.Key(
            tool: "claude",
            worklaneID: WorklaneID("worklane-approval-resume"),
            paneID: PaneID("pane-approval-resume")
        )
        for pruneBeforeStop in [false, true] {
            now = base
            var reducer = PaneAgentReducerState()
            try replay(#"{"hook_event_name":"SessionStart","session_id":"quiet-worker"}"#, into: &reducer, at: now)
            try replay(#"{"hook_event_name":"SubagentStart","session_id":"quiet-worker","agent_id":"worker","agent_transcript_path":"/tmp/quiet-worker.jsonl"}"#, into: &reducer, at: now)
            try replay(#"{"hook_event_name":"Stop","session_id":"quiet-worker"}"#, into: &reducer, at: now + 1)

            // A long tool can finish after the transcript has been quiet for
            // 15 minutes. Whether a prior read pruned it or the stop itself
            // does, this was a real worker and its result can wake the parent.
            now = base + AgentSubagentRegistryStore.transcriptQuietWindow + 1
            if pruneBeforeStop { XCTAssertEqual(try subagentStore.summary(key: key), .empty) }
            let stop = #"{"hook_event_name":"SubagentStop","session_id":"quiet-worker","agent_id":"worker"}"#
            try replay(stop, into: &reducer, at: now)
            XCTAssertEqual(reducer.reducedStatus(now: now)?.state, .running)
            XCTAssertEqual(reducer.reducedStatus(now: now)?.subagents, .empty)
            XCTAssertTrue(try makePayloads(stop).isEmpty, "a pruned id must be consumed so duplicate stops cannot restart a later completed turn")
        }
    }

    func test_post_tool_use_failure_after_approval_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 2_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s2"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s2"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        try replay(#"{"hook_event_name":"PostToolUseFailure","session_id":"s2","tool_name":"Bash","tool_use_id":"tu-bash","error":"exit 2"}"#, into: &reducer, at: base + 9)
        XCTAssertEqual(reducer.reducedStatus(now: base + 10)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 10)?.interactionKind, PaneAgentInteractionKind.none)
    }

    func test_post_tool_use_for_sibling_tool_keeps_pending_approval_visible() throws {
        // Parallel tool batch: Read A and Bash B are issued together. B needs
        // permission; A completes while B's dialog is still open. A's
        // PostToolUse must not clear B's prompt.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 3_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s3"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s3"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s3","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s3","tool_name":"Bash","message":"Run rm -rf build?"}"#, into: &reducer, at: base + 1.02)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Read","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1.3)

        let status = reducer.reducedStatus(now: base + 2)
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .approval)
        XCTAssertEqual(status?.text, "Run rm -rf build?")

        // B's own completion clears it.
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_permission_request_inherits_tool_use_id_from_preceding_pre_tool_use() throws {
        // PermissionRequest has no tool_use_id of its own. The PreToolUse for
        // the same tool call announced it moments earlier; that id is what
        // lets a sibling Read's PostToolUse be told apart from Bash's own.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 5_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s5"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s5","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s5","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s5"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-bash")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "Bash")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s5","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 1.3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.text, "Run make?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s5","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s5")?.lastStructuredInteractionToolName)
    }

    func test_permission_request_without_pre_tool_use_falls_back_to_tool_name() throws {
        // The PreToolUse matcher only covers Bash/Write/Edit. A WebFetch
        // prompt therefore has no id at all; the tool name is the only handle.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 6_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s6"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s6"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s6","tool_name":"WebFetch","message":"Fetch https://example.com?"}"#, into: &reducer, at: base + 1)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s6")?.lastStructuredInteractionToolUseID)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s6","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 1.3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.text, "Fetch https://example.com?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s6","tool_name":"WebFetch","tool_use_id":"tu-fetch"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_pre_tool_use_from_a_subagent_does_not_lend_its_id_to_the_parent_prompt() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 7_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s7"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s7","tool_name":"Bash","tool_use_id":"tu-sub","agent_id":"agent-1"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s7","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s7"))
        XCTAssertNil(record.lastStructuredInteractionToolUseID, "a subagent's PreToolUse must not be mistaken for the parent's prompted call")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "Bash")
    }

    func test_interrupted_post_tool_use_failure_ends_the_turn_as_an_interrupt() throws {
        // Escape during a long Bash: no Stop hook follows, and under a
        // terminal multiplexer the title stays "✳" the whole time, so this
        // late PostToolUseFailure is the only sign the turn ended. It must
        // say idle, marked as an interrupt so no "Agent ready" follows.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 8_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s8"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s8"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .running)

        let payloads = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash","error":"interrupted","is_interrupt":true,"duration_ms":4200}"#)
        XCTAssertEqual(payloads.map(\.state), [.idle])
        XCTAssertEqual(payloads.first?.lifecycleEvent, .interrupt)
        XCTAssertEqual(payloads.first?.interactionKind, PaneAgentInteractionKind.none)
        for payload in payloads {
            reducer.apply(payload, now: base + 5)
        }
        XCTAssertEqual(reducer.reducedStatus(now: base + 6)?.state, .idle)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s8")?.structuredInteractionKind)

        // A non-interrupt failure still resumes.
        let failure = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8","tool_name":"Bash","tool_use_id":"tu-bash","error":"exit 2","is_interrupt":false}"#)
        XCTAssertEqual(failure.first?.state, .running)
    }

    func test_interrupted_subagent_tool_does_not_end_the_parent_turn() throws {
        // A background subagent's tool can be interrupted while the parent
        // keeps working; only the root agent's interrupt ends the turn.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 8_050)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s8s"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s8s"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s8s","tool_name":"Bash","tool_use_id":"tu-sub","agent_id":"agent-1"}"#, into: &reducer, at: base + 1)

        let payloads = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8s","tool_name":"Bash","tool_use_id":"tu-sub","agent_id":"agent-1","error":"interrupted","is_interrupt":true}"#)
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .running)
    }

    func test_interrupt_on_open_permission_prompt_emits_explicit_idle() throws {
        // Escape on the permission dialog itself. The title showed "✳" the
        // whole time the dialog was up, so no title change follows and the
        // reducer would sit in needsInput forever; the interrupt must say
        // idle explicitly.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 8_100)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s8b"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s8b"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s8b","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s8b","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        let payloads = try makePayloads(#"{"hook_event_name":"PostToolUseFailure","session_id":"s8b","tool_name":"Bash","tool_use_id":"tu-bash","error":"interrupted","is_interrupt":true}"#)
        XCTAssertEqual(payloads.map(\.state), [.idle])
        XCTAssertEqual(payloads.first?.lifecycleEvent, .interrupt)
        XCTAssertEqual(payloads.first?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertEqual(payloads.first?.confidence, .explicit)
        for payload in payloads {
            reducer.apply(payload, now: base + 5)
        }
        let status = reducer.reducedStatus(now: base + 6)
        XCTAssertNotEqual(status?.state, .needsInput, "interrupting the dialog must leave needsInput")
        XCTAssertEqual(status?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s8b")?.structuredInteractionKind)
    }

    func test_pre_tool_use_slots_are_kept_per_agent() throws {
        // Parent announces Bash A, a subagent announces Bash B in between,
        // then the parent's prompt arrives: it must inherit A, and only A's
        // completion (from the parent context) may clear it.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 9_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s9"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s9"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s9","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s9","tool_name":"Bash","tool_use_id":"tu-b","agent_id":"agent-x"}"#, into: &reducer, at: base + 1.01)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s9","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s9"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-a")
        XCTAssertNil(record.lastStructuredInteractionAgentID)
        XCTAssertTrue(record.preToolUseSlots(agentID: nil).isEmpty, "the inherited slot is consumed")
        XCTAssertEqual(record.preToolUseSlots(agentID: "agent-x").map(\.toolUseID), ["tu-b"], "the subagent's slot is untouched")
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s9","tool_name":"Bash","tool_use_id":"tu-b","agent_id":"agent-x"}"#, into: &reducer, at: base + 3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 4)?.state, .needsInput, "a subagent's tool finishing says nothing about the parent's prompt")
        XCTAssertEqual(reducer.reducedStatus(now: base + 4)?.text, "Run make?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s9","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_subagent_post_tool_use_with_same_tool_name_keeps_parent_prompt() throws {
        // No ids anywhere (WebFetch is outside the PreToolUse matcher): the
        // agent context alone must keep a subagent's WebFetch completion from
        // clearing the parent's WebFetch prompt.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 9_500)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s9b"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s9b","tool_name":"WebFetch","message":"Fetch https://example.com?"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s9b","tool_name":"WebFetch","tool_use_id":"tu-sub","agent_id":"agent-x"}"#, into: &reducer, at: base + 2)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s9b","tool_name":"WebFetch","tool_use_id":"tu-parent"}"#, into: &reducer, at: base + 4)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .running)
    }

    func test_stale_pre_tool_use_id_does_not_leak_into_the_next_turn() throws {
        // Turn 1 announces and prompts Bash tu-1. In turn 2 the PreToolUse is
        // dropped (hook process killed, bridge restart); the PermissionRequest
        // must not pick up tu-1 or a sibling Read would look like "tu-1
        // still pending" for the wrong reasons.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 10_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s10"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s10"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s10","tool_name":"Bash","tool_use_id":"tu-1"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s10","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s10")?.lastStructuredInteractionToolUseID, "tu-1")
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s10","tool_name":"Edit","tool_use_id":"tu-edit"}"#, into: &reducer, at: base + 4)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s10","tool_name":"Bash","tool_use_id":"tu-1"}"#, into: &reducer, at: base + 5)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s10")?.preToolUseSlots(agentID: nil).map(\.toolUseID), ["tu-edit"], "PostToolUse keeps the batch's other announcements")
        try replay(#"{"hook_event_name":"Stop","session_id":"s10"}"#, into: &reducer, at: base + 6)
        XCTAssertTrue(try XCTUnwrap(sessionStore.lookup(sessionID: "s10")).preToolUseSlotsByAgentID.isEmpty, "Stop resets every queue")

        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s10"}"#, into: &reducer, at: base + 20)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s10","tool_name":"Bash","message":"Run make again?"}"#, into: &reducer, at: base + 21)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s10"))
        XCTAssertNil(record.lastStructuredInteractionToolUseID, "turn 1's id must not be inherited")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "Bash")
    }

    func test_pre_tool_use_slot_is_consumed_by_the_prompt_it_announced() throws {
        // Same session, same turn: the second PermissionRequest for Bash has
        // no PreToolUse of its own (dropped) and must not reuse the first one's
        // id after that prompt was already answered and cleared.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 10_500)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s10b"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s10b","tool_name":"Bash","tool_use_id":"tu-1"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s10b","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s10b")?.lastStructuredInteractionToolUseID, "tu-1")
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s10b")?.preToolUseSlots(agentID: nil).count, 0)

        try sessionStore.clearInteractionContext(sessionID: "s10b", ifTextMatches: "Run make?")
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s10b","tool_name":"Bash","message":"Run make again?"}"#, into: &reducer, at: base + 3)
        XCTAssertNil(try sessionStore.lookup(sessionID: "s10b")?.lastStructuredInteractionToolUseID)
    }

    func test_permission_request_for_ask_user_question_keeps_the_pre_tool_use_id() throws {
        // PreToolUse(AskUserQuestion) carries tool_use_id; the PermissionRequest
        // that re-describes the same call does not, and AskUserQuestion has no
        // PreToolUse slot. The id must survive the second write.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 11_000)
        let ask = #"""
        {"hook_event_name":"PreToolUse","session_id":"s11","tool_name":"AskUserQuestion","tool_use_id":"tu-ask",
         "tool_input":{"questions":[{"question":"Which approach?","options":[{"label":"A"},{"label":"B"}]}]}}
        """#

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s11"}"#, into: &reducer, at: base)
        try replay(ask, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s11","tool_name":"AskUserQuestion"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s11"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-ask")
        XCTAssertEqual(record.lastStructuredInteractionToolName, "AskUserQuestion")
        XCTAssertEqual(record.structuredInteractionKind, .decision)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s11","tool_name":"Read","tool_use_id":"tu-read"}"#, into: &reducer, at: base + 2)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s11","tool_name":"AskUserQuestion","tool_use_id":"tu-ask"}"#, into: &reducer, at: base + 4)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .running)
    }

    func test_permission_request_for_a_different_tool_does_not_inherit_the_slot() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 12_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s12"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s12","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s12","tool_name":"WebFetch","message":"Fetch https://example.com?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s12"))
        XCTAssertNil(record.lastStructuredInteractionToolUseID)
        XCTAssertEqual(record.lastStructuredInteractionToolName, "WebFetch")
        XCTAssertEqual(record.preToolUseSlots(agentID: nil).map(\.toolUseID), ["tu-bash"], "an unclaimed slot stays for the Bash prompt that may still come")
    }

    func test_post_tool_use_without_id_for_another_tool_keeps_pending_prompt() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 13_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s13"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s13","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s13","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s13","tool_name":"Read"}"#, into: &reducer, at: base + 2)

        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.text, "Run make?")
    }

    func test_allowlisted_sibling_announced_after_the_prompted_call_does_not_lend_its_id() throws {
        // Parallel batch: Bash A needs approval, Bash B (allowlisted `git
        // status`) is announced right after it and runs at once. The prompt
        // for A must inherit A's id, and B finishing must not clear it.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 15_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s15"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s15"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s15","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s15","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 1.01)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s15","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)

        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s15"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-a", "the oldest unclaimed Bash announcement is the prompted one")
        XCTAssertEqual(record.preToolUseSlots(agentID: nil).map(\.toolUseID), ["tu-b"], "only the inherited entry is consumed")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s15","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 2)
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput, "the allowlisted sibling finishing must not clear A's dialog")
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.text, "Run make?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s15","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_pre_tool_use_queue_is_bounded_per_agent_and_keeps_the_oldest() throws {
        // The prompt inherits the oldest matching announcement, so overflow
        // must drop the newest: 17 Bash calls in one batch, the first one
        // prompts.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 15_500)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"s15b"}"#, into: &reducer, at: base)
        for index in 0..<(ClaudePreToolUseSlot.maximumPerAgent + 1) {
            try replay(#"{"hook_event_name":"PreToolUse","session_id":"s15b","tool_name":"Bash","tool_use_id":"tu-\#(index)"}"#, into: &reducer, at: base + 1 + Double(index) / 100)
        }
        let slots = try XCTUnwrap(sessionStore.lookup(sessionID: "s15b")).preToolUseSlots(agentID: nil)
        XCTAssertEqual(slots.count, ClaudePreToolUseSlot.maximumPerAgent)
        XCTAssertEqual(slots.first?.toolUseID, "tu-0", "the oldest announcement survives overflow")
        XCTAssertEqual(slots.last?.toolUseID, "tu-\(ClaudePreToolUseSlot.maximumPerAgent - 1)", "the newest is the one not recorded")

        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s15b","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 2)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s15b")?.lastStructuredInteractionToolUseID, "tu-0")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s15b","tool_name":"Bash","tool_use_id":"tu-1"}"#, into: &reducer, at: base + 3)
        XCTAssertEqual(reducer.reducedStatus(now: base + 4)?.state, .needsInput, "the second call finishing must not clear the first call's dialog")
    }

    func test_post_tool_use_keeps_the_batch_queue_for_the_next_prompt() throws {
        // Pre A, Pre B, Pre C (allowlisted, long-running); A prompts and is
        // approved; A finishes. B's prompt must still inherit B's id, so C
        // finishing (same tool name) cannot clear B's dialog.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 18_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s18"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s18"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 1.01)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-c"}"#, into: &reducer, at: base + 1.02)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s18","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.03)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s18")?.lastStructuredInteractionToolUseID, "tu-a")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 5)
        XCTAssertEqual(reducer.reducedStatus(now: base + 6)?.state, .running)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s18")?.preToolUseSlots(agentID: nil).map(\.toolUseID), ["tu-b", "tu-c"], "PostToolUse must keep the batch's remaining announcements")

        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s18","tool_name":"Bash","message":"Run make install?"}"#, into: &reducer, at: base + 7)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s18")?.lastStructuredInteractionToolUseID, "tu-b")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-c"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .needsInput, "the allowlisted sibling finishing must not clear B's dialog")
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.text, "Run make install?")
        XCTAssertTrue(try XCTUnwrap(sessionStore.lookup(sessionID: "s18")).preToolUseSlots(agentID: nil).isEmpty, "a finished call leaves the queue")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s18","tool_name":"Bash","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 12)
        XCTAssertEqual(reducer.reducedStatus(now: base + 13)?.state, .running)
    }

    func test_finished_allowlisted_call_does_not_lend_its_id_to_a_later_prompt() throws {
        // Pre C (allowlisted) finishes before Pre D is even announced; D's
        // prompt must inherit D, not the stale oldest entry C.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 18_500)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s18b"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s18b","tool_name":"Bash","tool_use_id":"tu-c"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s18b","tool_name":"Bash","tool_use_id":"tu-c"}"#, into: &reducer, at: base + 2)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s18b","tool_name":"Bash","tool_use_id":"tu-d"}"#, into: &reducer, at: base + 3)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s18b","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 3.01)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s18b")?.lastStructuredInteractionToolUseID, "tu-d")
    }

    func test_subagent_pre_tool_use_leaves_the_parent_prompt_open() throws {
        // A subagent keeps editing while the parent waits for approval. Its
        // PreToolUse(Edit) is in the Bash/Write/Edit matcher set and used to
        // wipe the parent's prompt and force the pane to running.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 16_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s16"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s16"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s16","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s16","tool_name":"Bash","message":"Run make?"}"#, into: &reducer, at: base + 1.02)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)

        let payloads = try makePayloads(#"{"hook_event_name":"PreToolUse","session_id":"s16","tool_name":"Edit","tool_use_id":"tu-edit","agent_id":"agent-x"}"#)
        XCTAssertTrue(payloads.isEmpty, "a subagent's PreToolUse must not speak for the parent's open dialog")
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s16"))
        XCTAssertEqual(record.structuredInteractionKind, .approval)
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-bash")
        XCTAssertEqual(record.preToolUseSlots(agentID: "agent-x").map(\.toolUseID), ["tu-edit"], "the subagent's call is still remembered for its own prompt")
        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .needsInput)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s16","tool_name":"Edit","tool_use_id":"tu-edit","agent_id":"agent-x"}"#, into: &reducer, at: base + 4)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 5)?.text, "Run make?")

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s16","tool_name":"Bash","tool_use_id":"tu-bash"}"#, into: &reducer, at: base + 8)
        XCTAssertEqual(reducer.reducedStatus(now: base + 9)?.state, .running)
    }

    func test_clear_if_text_matches_accepts_the_notification_text() throws {
        // The pane may display the non-generic Notification message that
        // arrived for the prompt rather than the prompt text itself.
        try sessionStore.rememberStructuredInteraction(
            sessionID: "s17", worklaneID: WorklaneID("w"), paneID: PaneID("p"), cwd: nil, pid: nil,
            text: "Run make?", kind: .approval, confidence: .explicit, toolUseID: "tu-bash", toolName: "Bash"
        )
        try sessionStore.recordNotificationText(sessionID: "s17", text: "Claude needs permission to run make in build/")

        try sessionStore.clearInteractionContext(sessionID: "s17", ifTextMatches: "Something else entirely")
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s17")?.structuredInteractionKind, .approval, "an unrelated text must not clear")

        try sessionStore.clearInteractionContext(sessionID: "s17", ifTextMatches: "Claude needs permission to run make in build/")
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s17"))
        XCTAssertNil(record.structuredInteractionKind)
        XCTAssertNil(record.lastStructuredInteractionToolUseID)
        XCTAssertNil(record.lastNotificationText)
    }

    func test_records_written_before_the_slot_map_still_decode() throws {
        // Shape of a live record in ~/Library/Application Support/Zentty/
        // claude-hook-sessions.json written by the previous build: no
        // preToolUseSlotsByAgentID, no lastStructuredInteractionAgentID. One
        // undecodable record makes loadState fall back to an empty file and
        // the next save wipes every session on disk.
        let legacy = """
        {"version":1,"sessions":{
          "session-legacy":{
            "cwd":"/tmp/project",
            "lastHumanMessage":"Ship this?\\n[Yes] [No]",
            "lastInteractionKindRawValue":"decision",
            "lastNotificationText":"Claude Code needs your attention",
            "lastStructuredInteractionConfidenceRawValue":"explicit",
            "lastStructuredInteractionKindRawValue":"decision",
            "lastStructuredInteractionText":"Ship this?\\n[Yes] [No]",
            "lastStructuredInteractionToolName":"AskUserQuestion",
            "paneIDRawValue":"pn_c9406021-0fb2-412b-a152-e404b9963772",
            "sessionID":"session-legacy",
            "tasksByID":{},
            "updatedAt":1788634535.7325559,
            "worklaneIDRawValue":"wl_ee0a6d3a-3520-4981-a33c-b6464ef9fe79"
          },
          "session-minimal":{
            "sessionID":"session-minimal",
            "worklaneIDRawValue":"wl_min",
            "paneIDRawValue":"pn_min",
            "updatedAt":1
          }
        }}
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-legacy-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        try Data(legacy.utf8).write(to: stateURL)
        let store = ClaudeHookSessionStore(stateURL: stateURL)

        let record = try XCTUnwrap(store.lookup(sessionID: "session-legacy"))
        XCTAssertEqual(record.structuredInteractionKind, .decision)
        XCTAssertEqual(record.lastStructuredInteractionToolName, "AskUserQuestion")
        XCTAssertTrue(record.preToolUseSlotsByAgentID.isEmpty)
        XCTAssertNil(record.lastStructuredInteractionAgentID)

        // A write touching another session must carry both legacy records over.
        try store.upsert(sessionID: "session-new", worklaneID: WorklaneID("w"), paneID: PaneID("p"), cwd: nil, pid: nil)
        XCTAssertNotNil(try store.lookup(sessionID: "session-legacy"), "a legacy record must survive the next save")
        XCTAssertEqual(try store.lookup(sessionID: "session-minimal")?.tasks, [], "a record without tasks decodes with the default")
        XCTAssertNotNil(try store.lookup(sessionID: "session-new"))
    }

    func test_default_store_path_stays_out_of_application_support_under_xctest() throws {
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Zentty", isDirectory: true)
            .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)

        let underTests = ClaudeHookSessionStore(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
        XCTAssertEqual(underTests.stateURL.lastPathComponent, "claude-hook-sessions.json")
        XCTAssertTrue(
            underTests.stateURL.path.contains("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)"),
            "under XCTest the default store must be a per-process temp file, got \(underTests.stateURL.path)"
        )
        XCTAssertNotEqual(underTests.stateURL.standardizedFileURL, appSupport.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: underTests.stateURL.deletingLastPathComponent().path), "the temp directory is created")

        let inApp = ClaudeHookSessionStore(environment: [:])
        XCTAssertEqual(inApp.stateURL.standardizedFileURL, appSupport.standardizedFileURL)

        let overridden = ClaudeHookSessionStore(environment: [
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
            "ZENTTY_CLAUDE_HOOK_STATE_PATH": "~/custom/claude-hook-sessions.json",
        ])
        XCTAssertEqual(
            overridden.stateURL.path,
            NSString(string: "~/custom/claude-hook-sessions.json").expandingTildeInPath,
            "the explicit override wins over the XCTest fallback"
        )

        // The process really is under XCTest, so the no-argument init lands on the temp file too.
        XCTAssertNotEqual(ClaudeHookSessionStore().stateURL.standardizedFileURL, appSupport.standardizedFileURL)
    }

    func test_compaction_restart_keeps_the_queued_announcement() throws {
        // PreToolUse(Bash) inside a subagent, auto-compaction (PreCompact then
        // SessionStart(compact)), then the PermissionRequest for that call:
        // the id must survive the compaction window. A real restart resets.
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 19_000)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s19","source":"startup"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s19"}"#, into: &reducer, at: base + 0.1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s19","tool_name":"Bash","tool_use_id":"tu-sub","agent_id":"agent-a"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PreCompact","session_id":"s19","trigger":"auto"}"#, into: &reducer, at: base + 2)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"s19","source":"compact"}"#, into: &reducer, at: base + 3)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s19")?.preToolUseSlots(agentID: "agent-a").map(\.toolUseID), ["tu-sub"], "SessionStart(compact) must keep the batch's announcements")

        try replay(#"{"hook_event_name":"PermissionRequest","session_id":"s19","tool_name":"Bash","message":"Run make?","agent_id":"agent-a"}"#, into: &reducer, at: base + 4)
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "s19"))
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-sub")
        XCTAssertEqual(record.lastStructuredInteractionAgentID, "agent-a")

        // A genuine restart of the same session id starts from nothing.
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s19","tool_name":"Bash","tool_use_id":"tu-later","agent_id":"agent-a"}"#, into: &reducer, at: base + 10)
        try replay(#"{"hook_event_name":"SessionStart","session_id":"s19","source":"startup"}"#, into: &reducer, at: base + 11)
        XCTAssertTrue(try XCTUnwrap(sessionStore.lookup(sessionID: "s19")).preToolUseSlotsByAgentID.isEmpty, "SessionStart(startup) resets the queues")
    }

    func test_post_tool_use_without_id_leaves_the_queue_intact() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 19_500)

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s19b"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s19b","tool_name":"Bash","tool_use_id":"tu-a"}"#, into: &reducer, at: base + 1)
        try replay(#"{"hook_event_name":"PreToolUse","session_id":"s19b","tool_name":"Edit","tool_use_id":"tu-b"}"#, into: &reducer, at: base + 1.01)
        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s19b","tool_name":"Read"}"#, into: &reducer, at: base + 2)

        XCTAssertEqual(reducer.reducedStatus(now: base + 3)?.state, .running)
        XCTAssertEqual(try sessionStore.lookup(sessionID: "s19b")?.preToolUseSlots(agentID: nil).map(\.toolUseID), ["tu-a", "tu-b"])
    }

    func test_session_start_drops_phantom_subagents_unless_compacting() throws {
        // A killed session never sent SubagentStop; the next session in the
        // same pane must start from an empty registry. Compaction keeps the
        // same session (and its live children).
        let key = AgentSubagentRegistryStore.Key(
            tool: "claude",
            worklaneID: WorklaneID("worklane-approval-resume"),
            paneID: PaneID("pane-approval-resume")
        )
        for source in ["startup", "resume", "clear"] {
            _ = try subagentStore.start(key: key, entry: PaneAgentSubagentEntry(id: "phantom-\(source)"))
            XCTAssertEqual(try subagentStore.summary(key: key)?.entries.count, 1)
            _ = try makePayloads(#"{"hook_event_name":"SessionStart","session_id":"s14","source":"\#(source)"}"#)
            XCTAssertEqual(try subagentStore.summary(key: key)?.entries.count ?? 0, 0, "SessionStart(\(source)) must clear the pane's registry entry")
        }

        _ = try subagentStore.start(key: key, entry: PaneAgentSubagentEntry(id: "live-child"))
        _ = try makePayloads(#"{"hook_event_name":"SessionStart","session_id":"s14","source":"compact"}"#)
        XCTAssertEqual(try subagentStore.summary(key: key)?.entries.count, 1, "compaction keeps live subagents")
    }

    func test_post_tool_use_after_ask_user_question_returns_to_running() throws {
        var reducer = PaneAgentReducerState()
        let base = Date(timeIntervalSince1970: 4_000)
        let ask = #"""
        {"hook_event_name":"PreToolUse","session_id":"s4","tool_name":"AskUserQuestion","tool_use_id":"tu-ask",
         "tool_input":{"questions":[{"question":"Which approach?","options":[{"label":"A"},{"label":"B"}]}]}}
        """#

        try replay(#"{"hook_event_name":"SessionStart","session_id":"s4"}"#, into: &reducer, at: base)
        try replay(#"{"hook_event_name":"UserPromptSubmit","session_id":"s4"}"#, into: &reducer, at: base + 0.1)
        try replay(ask, into: &reducer, at: base + 1)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.state, .needsInput)
        XCTAssertEqual(reducer.reducedStatus(now: base + 2)?.interactionKind, .decision)

        try replay(#"{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"AskUserQuestion","tool_use_id":"tu-ask"}"#, into: &reducer, at: base + 20)
        XCTAssertEqual(reducer.reducedStatus(now: base + 21)?.state, .running)
        XCTAssertEqual(reducer.reducedStatus(now: base + 21)?.interactionKind, PaneAgentInteractionKind.none)
    }

    private func replay(_ json: String, into reducer: inout PaneAgentReducerState, at now: Date) throws {
        for payload in try makePayloads(json) {
            reducer.apply(payload, now: now)
        }
    }

    private func makePayloads(_ json: String) throws -> [AgentStatusPayload] {
        try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(json.utf8)),
            environment: defaultEnvironment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
    }
}

/// Terminal-title half of the same symptom. While a Claude Code permission or
/// AskUserQuestion dialog is open the title carries the idle glyph "✳"; the
/// moment the user answers (with `1`, `y`, Enter, or a click elsewhere) the
/// spinner glyphs "◐ ◑" come back — several seconds before any hook fires.
/// Live bench timeline (claude/approval_then_work):
///
///   4707 ms  title "✳ …"   (dialog open)
///   4721 ms  PermissionRequest
///  10737 ms  user types 1
///  10747 ms  title "◐ …"   ← resume signal
///  21893 ms  PreToolUse(Bash) — first hook after approval
@MainActor
final class ClaudeSpinnerTitleResumeTests: XCTestCase {

    func test_spinner_title_after_idle_title_resumes_blocked_claude_session() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Create file ZENTTY_OK?", interactionKind: .approval
            )
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        // Title stays on the idle glyph while the dialog is open: no change.
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        // User answers; spinner returns.
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        let status = store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus
        XCTAssertEqual(status?.state, .running, "spinner title after the idle-glyph dialog title must resume the session")
        XCTAssertEqual(status?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertNil(status?.text)
    }

    func test_spinner_resume_clears_pending_prompt_in_hook_session_store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-spinner-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            claudeHookSessionStoreProvider: { sessionStore }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        try sessionStore.rememberStructuredInteraction(
            sessionID: "session-claude-spinner",
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            cwd: "/tmp/project",
            pid: nil,
            text: "Create file ZENTTY_OK?",
            kind: .approval,
            confidence: .explicit,
            toolUseID: "tu-write",
            toolName: "Write"
        )

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Create file ZENTTY_OK?", interactionKind: .approval
            )
        )
        XCTAssertEqual(try sessionStore.lookup(sessionID: "session-claude-spinner")?.structuredInteractionKind, .approval)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "session-claude-spinner"))
        XCTAssertNil(record.structuredInteractionKind, "the bridge must forget the answered prompt or it keeps dropping PostToolUse for the rest of the turn")
        XCTAssertNil(record.lastStructuredInteractionToolUseID)
        XCTAssertNil(record.lastStructuredInteractionToolName)
    }

    func test_spinner_resume_leaves_a_newer_prompt_in_the_hook_session_store() throws {
        // The spinner title for the answered prompt can land after the bridge
        // already stored the next PermissionRequest. Clearing by session id
        // alone would wipe that newer prompt.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-spinner-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            claudeHookSessionStoreProvider: { sessionStore }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Create file ZENTTY_OK?", interactionKind: .approval
            )
        )
        // The bridge has moved on to the next prompt before the title caught up.
        try sessionStore.rememberStructuredInteraction(
            sessionID: "session-claude-spinner",
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            cwd: "/tmp/project",
            pid: nil,
            text: "Run make?",
            kind: .approval,
            confidence: .explicit,
            toolUseID: "tu-bash",
            toolName: "Bash"
        )

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: "session-claude-spinner"))
        XCTAssertEqual(record.structuredInteractionText, "Run make?", "the newer prompt must survive the stale resume")
        XCTAssertEqual(record.lastStructuredInteractionToolUseID, "tu-bash")
    }

    func test_stale_spinner_title_before_dialog_title_does_not_clear_prompt() throws {
        // Reverse race: PermissionRequest lands before the "✳" title does. The
        // spinner glyph that is still on screen must not be read as a resume.
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◐ regression test"))
        store.applyAgentStatusPayload(claudePayload(paneID: paneID, worklaneID: store.activeWorklaneID, state: .running))
        store.applyAgentStatusPayload(
            claudePayload(
                paneID: paneID, worklaneID: store.activeWorklaneID,
                state: .needsInput, text: "Run make?", interactionKind: .approval
            )
        )
        store.updateMetadata(paneID: paneID, metadata: metadata(title: "◑ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        store.updateMetadata(paneID: paneID, metadata: metadata(title: "✳ regression test"))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Run make?")
    }

    private func metadata(title: String) -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: "main"
        )
    }

    private func claudePayload(
        paneID: PaneID,
        worklaneID: WorklaneID,
        state: PaneAgentState,
        text: String? = nil,
        interactionKind: PaneAgentInteractionKind? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: text,
            lifecycleEvent: .update,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: "session-claude-spinner",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}
