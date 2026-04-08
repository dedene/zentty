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
}
