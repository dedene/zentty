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

    func test_user_submit_promotes_idle_vibe_session_to_running() {
        // Vibe has no turn-start hook: after a turn ends (post_agent_turn ->
        // idle) a user submit (Enter) is the only signal that a new turn began.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-vibe"),
                state: .running,
                origin: .explicitHook,
                toolName: "Mistral Vibe",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "vibe-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-vibe"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Mistral Vibe",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "vibe-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let promoted = reducerState.promoteExplicitVibeSessionFromUserInput(now: startedAt.addingTimeInterval(2))

        XCTAssertTrue(promoted, "A user submit must promote an idle Vibe session to running")
        XCTAssertEqual(
            reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))?.state,
            .running
        )
    }

    func test_user_submit_does_not_promote_non_vibe_session() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-claude"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "claude-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-claude"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                lifecycleEvent: .update,
                sessionID: "claude-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            reducerState.promoteExplicitVibeSessionFromUserInput(now: startedAt.addingTimeInterval(2)),
            "Vibe submit promotion must not touch other agents"
        )
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

    func test_running_signal_preserves_explicit_transient_text_for_visibility_window() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: "Compacting",
                lifecycleEvent: .toolActivity,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )

        XCTAssertEqual(reducerState.reducedStatus(now: startedAt)?.state, .running)
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt)?.text, "Compacting")
        XCTAssertNil(
            reducerState.reducedStatus(
                now: startedAt.addingTimeInterval(PaneAgentReducerState.transientRunningTextVisibilityWindow + 0.1)
            )?.text
        )
    }

    func test_post_compact_clears_compacting_text_while_running() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: "Compacting",
                lifecycleEvent: .toolActivity,
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
            now: startedAt.addingTimeInterval(0.1)
        )

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(0.2))?.text)
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(0.2))?.state, .running)
    }

    func test_compacting_text_clears_when_session_becomes_idle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Compacting",
                lifecycleEvent: .toolActivity,
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
                lifecycleEvent: .turnComplete,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(5)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(5))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertNil(status?.text)
    }

    func test_shell_state_does_not_extend_compacting_text_deadline() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: "Compacting",
                lifecycleEvent: .toolActivity,
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
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(PaneAgentReducerState.transientRunningTextVisibilityWindow - 0.1)
        )

        XCTAssertNil(
            reducerState.reducedStatus(
                now: startedAt.addingTimeInterval(PaneAgentReducerState.transientRunningTextVisibilityWindow + 0.1)
            )?.text
        )
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

    func test_shell_command_running_does_not_clear_grok_explicit_question() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Grok",
                text: "Ship this?",
                interactionKind: .question,
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
                toolName: "Grok",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.state, .needsInput)
        XCTAssertEqual(status?.interactionKind, .some(.question))
        XCTAssertEqual(status?.text, "Ship this?")
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

    func test_opencode_session_id_lifecycle_preserves_prelaunch_pid_from_fallback_session() {
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
                toolName: "OpenCode",
                text: nil,
                sessionID: nil,
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
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "ses_1de868207ffebJ66ISsfrf7AzW",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(status?.sessionID, "ses_1de868207ffebJ66ISsfrf7AzW")
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertNil(reducerState.sessionsByID["pane-opencode"])
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

    func test_nil_session_codex_turn_complete_does_not_replace_restorable_session() {
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
            now: startedAt.addingTimeInterval(1)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .turnComplete,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )
        reducerState.sessionsByID["session-1"]?.source = .inferred
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .turnComplete,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                sessionID: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2.1)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(2.1))
        XCTAssertEqual(status?.sessionID, "session-1")
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertNil(reducerState.sessionsByID["pane-codex"])
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

    func test_real_opencode_session_idle_replaces_synthetic_prelaunch_session() {
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
                toolName: "OpenCode",
                text: nil,
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
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3),
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
                state: .idle,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.sessionID, "session-1")
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertEqual(status?.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
        XCTAssertNil(reducerState.sessionsByID["pane-opencode"])
    }

    func test_sweep_removes_exited_idle_opencode_session() {
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
                toolName: "OpenCode",
                text: nil,
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
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3),
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
                state: .idle,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(3), isProcessAlive: { _ in false })

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(3)))
        XCTAssertTrue(reducerState.sessionsByID.isEmpty)
    }

    func test_sweep_keeps_idle_opencode_session_when_process_is_alive() {
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
                toolName: "OpenCode",
                text: nil,
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
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3),
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
                state: .idle,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(3), isProcessAlive: { _ in true })

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(3))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.tool, .openCode)
        XCTAssertEqual(status?.trackedPID, 4242)
        XCTAssertEqual(status?.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_sweep_removes_idle_session_when_process_exits_regardless_of_tool() {
        // Universal version of test_sweep_removes_exited_idle_opencode_session.
        // Originally only OpenCode cleared the badge on dead-PID-while-idle;
        // every other tool kept the badge alive for the full
        // idleVisibilityWindow (~120s). For Grok and Amp that path is the
        // common case (no SessionEnd hook on Ctrl+C), so the rule now
        // applies to every tool.
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
            now: startedAt.addingTimeInterval(1)
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
            now: startedAt.addingTimeInterval(2)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(3), isProcessAlive: { _ in false })

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(3)))
        XCTAssertTrue(reducerState.sessionsByID.isEmpty)
    }

    func test_sweep_removes_idle_grok_session_on_ctrl_c() {
        // Regression: Grok 0.1.211 does not fire SessionEnd on Ctrl+C, so the
        // only signal that the agent is gone is the polling sweep noticing
        // the PID is dead. With state already at .idle (from the last Stop
        // hook), the badge must clear immediately — not after 120s.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 9001,
                pidEvent: .attach,
                origin: .explicitHook,
                toolName: "Grok",
                text: nil,
                sessionID: "session-grok",
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
                toolName: "Grok",
                text: nil,
                confidence: .explicit,
                sessionID: "session-grok",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(2), isProcessAlive: { _ in false })

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(2)))
        XCTAssertTrue(reducerState.sessionsByID.isEmpty)
    }

    func test_sweep_removes_idle_amp_session_on_ctrl_c() {
        // Regression: Amp emits agent.idle via its plugin but doesn't emit
        // any teardown event when killed via SIGINT. Same expectation as
        // Grok: dead PID + .idle → badge cleared on the next polling tick.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 9002,
                pidEvent: .attach,
                origin: .explicitHook,
                toolName: "Amp",
                text: nil,
                sessionID: "session-amp",
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
                toolName: "Amp",
                text: nil,
                confidence: .explicit,
                sessionID: "session-amp",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(2), isProcessAlive: { _ in false })

        XCTAssertNil(reducerState.reducedStatus(now: startedAt.addingTimeInterval(2)))
        XCTAssertTrue(reducerState.sessionsByID.isEmpty)
    }

    func test_sweep_keeps_idle_session_when_process_is_alive_regardless_of_tool() {
        // Inverse pin: a normal "agent finished its turn, prompt waiting"
        // case (idle + alive PID) must remain visible so the user sees
        // "Idle" for the full idleVisibilityWindow. The dead-PID fix must
        // not regress this.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 9003,
                pidEvent: .attach,
                origin: .explicitHook,
                toolName: "Grok",
                text: nil,
                sessionID: "session-grok",
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
                state: .running,
                origin: .explicitHook,
                toolName: "Grok",
                text: nil,
                confidence: .explicit,
                sessionID: "session-grok",
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
                state: .idle,
                origin: .explicitHook,
                toolName: "Grok",
                text: nil,
                confidence: .explicit,
                sessionID: "session-grok",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )

        reducerState.sweep(now: startedAt.addingTimeInterval(3), isProcessAlive: { _ in true })

        let status = reducerState.reducedStatus(now: startedAt.addingTimeInterval(3))
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.tool, .grok)
        XCTAssertEqual(status?.trackedPID, 9003)
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

    func test_mark_claude_code_idle_from_idle_title_keeps_running_until_grace_window_expires() {
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
        XCTAssertEqual(reducerState.reducedStatus(now: idleNow)?.state, .running)
        XCTAssertEqual(
            reducerState.sessionsByID.values.first?.completionCandidateDeadline,
            idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow)
        )

        reducerState.sweep(
            now: idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1),
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(
            reducerState.reducedStatus(
                now: idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
            )?.state,
            .idle
        )
    }

    func test_mark_claude_code_idle_from_idle_title_refreshes_grace_window() {
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
        XCTAssertEqual(reducerState.reducedStatus(now: idleNow)?.state, .running)
        XCTAssertEqual(
            reducerState.sessionsByID.values.first?.completionCandidateDeadline,
            idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow)
        )
    }

    func test_claude_permission_request_cancels_idle_title_candidate() {
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

        let idleNow = now.addingTimeInterval(5)
        XCTAssertTrue(reducerState.markExplicitClaudeCodeSessionIdleFromIdleTitle(now: idleNow))
        XCTAssertNotNil(reducerState.sessionsByID.values.first?.completionCandidateDeadline)

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your approval",
                lifecycleEvent: .update,
                interactionKind: .approval,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: idleNow.addingTimeInterval(0.01)
        )

        XCTAssertEqual(reducerState.reducedStatus(now: idleNow.addingTimeInterval(0.01))?.state, .needsInput)
        XCTAssertEqual(reducerState.reducedStatus(now: idleNow.addingTimeInterval(0.01))?.interactionKind, .approval)
        XCTAssertNil(reducerState.sessionsByID.values.first?.completionCandidateDeadline)

        reducerState.sweep(
            now: idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1),
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(
            reducerState.reducedStatus(
                now: idleNow.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
            )?.state,
            .needsInput
        )
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
