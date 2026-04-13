import Foundation
import XCTest
@testable import Zentty

final class PaneAgentReducerTests: XCTestCase {
    func test_stop_candidate_promotes_to_idle_after_grace_window() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .stopCandidate,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(1.5))?.state, .running)

        reducerState.sweep(now: startedAt.addingTimeInterval(3.1), isProcessAlive: { _ in true })

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(3.1))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.interactionKind, PaneAgentInteractionKind.none)
    }

    func test_running_signal_cancels_pending_stop_candidate() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .stopCandidate,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1.5)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(4), isProcessAlive: { _ in true })

        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(4))?.state, .running)
    }

    func test_idle_without_prior_running_does_not_surface_status() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        XCTAssertNil(reducerState.reducedStatus(now: startedAt))
    }

    func test_specific_interaction_kind_beats_generic_input() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .heuristic,
                toolName: "Claude Code",
                text: "Claude needs your input",
                interactionKind: .genericInput,
                confidence: .weak,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Ship this?\n[Yes] [No]",
                interactionKind: .question,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .question)
        XCTAssertEqual(status?.text, "Ship this?\n[Yes] [No]")
    }

    func test_heuristic_needs_input_promotes_running_session_for_same_session_id() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Waiting for your input",
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .genericInput)
        XCTAssertEqual(status?.text, "Waiting for your input")
    }

    func test_heuristic_needs_input_does_not_beat_idle_session() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Waiting for your input",
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.interactionKind, PaneAgentInteractionKind.none)
    }

    func test_subagent_completion_does_not_clear_parent_blocking_interaction() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Allow write?",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "parent-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "child-session",
                parentSessionID: "parent-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .approval)
        XCTAssertEqual(status?.text, "Allow write?")
    }

    func test_same_explicit_interaction_kind_replaces_generic_copy_with_specific_text() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your approval",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Allow file write?",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.interactionKind, .approval)
        XCTAssertEqual(status?.text, "Allow file write?")
    }

    func test_generic_input_does_not_downgrade_explicit_decision() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Ship this?\n[Yes] [No]",
                interactionKind: .decision,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your input",
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.interactionKind, .decision)
        XCTAssertEqual(status?.text, "Ship this?\n[Yes] [No]")
    }

    func test_shell_command_running_clears_blocked_state_into_running() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Ship this?\n[Yes] [No]",
                interactionKind: .decision,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(status?.interactionKind, .some(.none))
        XCTAssertNil(status?.text)
    }

    func test_shell_command_running_does_not_promote_explicit_starting_codex_session_to_running() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
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
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .starting,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(0.5)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .starting)
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertFalse(status?.hasObservedRunning == true)
        XCTAssertEqual(Array(reducerState.sessionsByID.keys), ["session-1"])
    }

    func test_shell_command_running_does_not_promote_explicit_starting_opencode_session_to_running() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "OpenCode",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .starting,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(0.5)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "OpenCode",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .starting)
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertFalse(status?.hasObservedRunning == true)
        XCTAssertEqual(Array(reducerState.sessionsByID.keys), ["session-1"])
    }

    func test_prompt_idle_clears_explicit_running_session_into_idle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .shellState,
                state: nil,
                shellActivityState: .promptIdle,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.interactionKind, .some(.none))
        XCTAssertNil(status?.text)
    }

    func test_idle_session_preserves_tracked_pid_when_process_is_still_running() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(0.5)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .shellState,
                state: nil,
                shellActivityState: .promptIdle,
                origin: .shell,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.trackedPID, 4242)
    }

    func test_reduced_status_preserves_task_progress_across_lifecycle_updates() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3),
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Need approval",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_dead_pid_without_completion_becomes_unresolved_stop() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(5), isProcessAlive: { _ in false })

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(5))
        XCTAssertEqual(status?.state, .unresolvedStop)
        XCTAssertEqual(status?.tool, .codex)
        XCTAssertNil(status?.trackedPID)
    }

    func test_stop_candidate_overrides_needs_input_with_human_attention() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        // 0. Model starts running (UserPromptSubmit)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        // 1. Model uses AskUserQuestion → needsInput with decision (requiresHumanAttention)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Which approach?\n[A] [B]",
                interactionKind: .decision,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))?.state, .needsInput)

        // 2. Model finishes (user answered, model generated final text, Stop fires)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .stopCandidate,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(5)
        )

        // stopCandidate must NOT be blocked — session should be in grace period (.running)
        XCTAssertEqual(
            reducerState.reducedStatus(now: startedAt.addingTimeInterval(5))?.state,
            .running,
            "stopCandidate must override needsInput — session should enter grace period"
        )

        // 3. Grace window passes → idle
        reducerState.sweep(now: startedAt.addingTimeInterval(8), isProcessAlive: { _ in true })
        XCTAssertEqual(
            reducerState.reducedStatus(now: startedAt.addingTimeInterval(8))?.state,
            .idle,
            "After grace window, session should be idle"
        )
    }

    func test_immediate_dead_pid_for_ephemeral_start_collapses_to_inactive() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(0.5), isProcessAlive: { _ in false })

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(0.5)))
        XCTAssertTrue(reducerState.sessionsByID.isEmpty)
    }

    // MARK: - markExplicitClaudeCodeSessionIdleFromIdleTitle

    func test_mark_claude_code_idle_from_idle_title_transitions_running_to_idle() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: now
        )

        XCTAssertEqual(reducerState.reducedStatus()?.state, .running)

        let idleNow = now.addingTimeInterval(5)
        let result = reducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: idleNow)

        XCTAssertTrue(result)
        XCTAssertEqual(reducerState.reducedStatus(now: idleNow)?.state, .idle)
    }

    func test_mark_claude_code_idle_from_idle_title_cancels_grace_window() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: now
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .stopCandidate,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: now.addingTimeInterval(1)
        )

        // Still in grace window — shows running.
        XCTAssertEqual(reducerState.reducedStatus(now: now.addingTimeInterval(1.5))?.state, .running)

        // Title says "Interrupted" → force idle immediately.
        let idleNow = now.addingTimeInterval(1.5)
        let result = reducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: idleNow)

        XCTAssertTrue(result)
        XCTAssertEqual(reducerState.reducedStatus(now: idleNow)?.state, .idle)
        XCTAssertNil(reducerState.sessionsByID.values.first?.completionCandidateDeadline)
    }

    func test_mark_claude_code_idle_from_idle_title_ignores_codex_session() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: now
        )

        let result = reducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: now.addingTimeInterval(5))

        XCTAssertFalse(result)
        XCTAssertEqual(reducerState.reducedStatus()?.state, .running)
    }

    func test_mark_claude_code_idle_from_idle_title_requires_observed_running() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.sessionsByID["session-1"] = PaneAgentSessionState(
            sessionID: "session-1",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .starting,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: false,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        let result = reducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: now.addingTimeInterval(5))

        XCTAssertFalse(result)
    }

    // MARK: - Parent / child session preference

    func test_parent_running_preferred_over_child_running_with_newer_timestamp() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.sessionsByID["parent"] = PaneAgentSessionState(
            sessionID: "parent",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        reducerState.sessionsByID["child"] = PaneAgentSessionState(
            sessionID: "child",
            parentSessionID: "parent",
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now.addingTimeInterval(5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        let status = reducerState.reducedStatus(now: now.addingTimeInterval(5))
        XCTAssertEqual(status?.sessionID, "parent")
    }

    func test_child_needs_input_surfaces_over_parent_running() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.sessionsByID["parent"] = PaneAgentSessionState(
            sessionID: "parent",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        reducerState.sessionsByID["child"] = PaneAgentSessionState(
            sessionID: "child",
            parentSessionID: "parent",
            tool: .claudeCode,
            state: .needsInput,
            text: "Allow write?",
            artifactLink: nil,
            updatedAt: now.addingTimeInterval(5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .approval,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        let status = reducerState.reducedStatus(now: now.addingTimeInterval(5))
        XCTAssertEqual(status?.sessionID, "child")
        XCTAssertEqual(status?.state, .needsInput)
    }

    func test_child_running_surfaces_over_parent_unresolved_stop() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.sessionsByID["parent"] = PaneAgentSessionState(
            sessionID: "parent",
            parentSessionID: nil,
            tool: .codex,
            state: .unresolvedStop,
            text: nil,
            artifactLink: nil,
            updatedAt: now.addingTimeInterval(5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: now.addingTimeInterval(600)
        )

        reducerState.sessionsByID["child"] = PaneAgentSessionState(
            sessionID: "child",
            parentSessionID: "parent",
            tool: .codex,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        let status = reducerState.reducedStatus(now: now.addingTimeInterval(5))
        XCTAssertEqual(status?.sessionID, "child")
        XCTAssertEqual(status?.state, .running)
    }

    func test_parent_task_progress_visible_when_child_running_without_progress() {
        let now = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.sessionsByID["parent"] = PaneAgentSessionState(
            sessionID: "parent",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            taskProgress: PaneAgentTaskProgress(doneCount: 3, totalCount: 7),
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        reducerState.sessionsByID["child"] = PaneAgentSessionState(
            sessionID: "child",
            parentSessionID: "parent",
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now.addingTimeInterval(5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        let status = reducerState.reducedStatus(now: now.addingTimeInterval(5))
        XCTAssertEqual(status?.sessionID, "parent")
        XCTAssertEqual(status?.taskProgress?.doneCount, 3)
        XCTAssertEqual(status?.taskProgress?.totalCount, 7)
    }
}
