import Foundation
import XCTest
@testable import Zentty

/// Reproduces the symptom Peter screenshotted: a Claude session that has
/// finished a turn (Stop fired) ends up displayed as "Needs input" because a
/// `Notification` hook arrives a moment later carrying a generic
/// "Claude is waiting for your input" message.
///
/// These tests drive the real Claude adapter (`AgentEventBridge.claudeAdapter`)
/// through a fresh `ClaudeHookSessionStore`, accumulate the produced payloads
/// in a `PaneAgentReducerState`, and assert on the final reduced status.
///
/// Pre-fix: both tests fail because the late Notification flips the session
/// from `.idle` back to `.needsInput`. Post-fix: both tests pass because the
/// reducer/adapter pipeline ignores the late Notification once Stop has put
/// the session into `.idle`.
final class ClaudeStopNotificationRaceTests: XCTestCase {

    private let defaultEnvironment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-stop-race",
        "ZENTTY_PANE_ID": "pane-stop-race",
        "ZENTTY_WINDOW_ID": "window-stop-race",
    ]

    private var sessionStore: ClaudeHookSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-hook-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test_late_notification_after_stop_keeps_session_idle() throws {
        let env = environment(pid: "12345")
        var reducer = PaneAgentReducerState()
        let baseTime = Date(timeIntervalSince1970: 1_000)

        let events: [ReplayEvent] = [
            .init(offset: 0.00, json: #"{"hook_event_name":"SessionStart","session_id":"sess-bug-1"}"#),
            .init(offset: 0.10, json: #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-bug-1"}"#),
            .init(offset: 0.20, json: #"{"hook_event_name":"PreToolUse","session_id":"sess-bug-1","tool_name":"Bash"}"#),
            .init(offset: 0.50, json: #"{"hook_event_name":"Stop","session_id":"sess-bug-1"}"#),
            .init(offset: 0.60, json: #"{"hook_event_name":"Notification","session_id":"sess-bug-1","message":"Claude is waiting for your input"}"#),
        ]

        for event in events {
            let payloads = try AgentEventBridge.claudeMakePayloads(
                from: AgentEventBridge.claudeParseInput(Data(event.json.utf8)),
                environment: env,
                sessionStore: sessionStore
            )
            for payload in payloads {
                reducer.apply(payload, now: baseTime.addingTimeInterval(event.offset))
            }
        }

        let reduced = reducer.reducedStatus(now: baseTime.addingTimeInterval(0.7))
        XCTAssertEqual(
            reduced?.state, .idle,
            "Late Notification arriving after Stop must not flip the session back to needsInput. Got state=\(String(describing: reduced?.state)) text=\(reduced?.text ?? "nil")"
        )
        XCTAssertEqual(reduced?.interactionKind, PaneAgentInteractionKind.none)
    }

    func test_ask_user_question_then_stop_then_late_notification_keeps_session_idle() throws {
        let env = environment(pid: "12345")
        var reducer = PaneAgentReducerState()
        let baseTime = Date(timeIntervalSince1970: 1_000)

        // This variant exercises the structured-interaction cache:
        //
        //   PreToolUse(AskUserQuestion) caches a structured interaction in
        //   ClaudeHookSessionStore. The user "answers" (no clearing hook),
        //   Stop fires, then a generic "waiting for input" Notification
        //   arrives. The cache is still populated, so the
        //   `hasExplicitStructuredInteraction && isGenericMessage` branch
        //   kicks in and flips the session back to needsInput with the
        //   structured (decision) interaction kind.
        let askUserQuestionJSON = #"""
        {
          "hook_event_name": "PreToolUse",
          "session_id": "sess-bug-2",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [{"question": "Which approach?", "options": [{"label": "A"}, {"label": "B"}]}]
          }
        }
        """#

        let events: [ReplayEvent] = [
            .init(offset: 0.00, json: #"{"hook_event_name":"SessionStart","session_id":"sess-bug-2"}"#),
            .init(offset: 0.10, json: #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-bug-2"}"#),
            .init(offset: 0.20, json: askUserQuestionJSON),
            // No clearing hook between AskUserQuestion answer and Stop —
            // matches Claude Code's actual behavior when the user picks an
            // option and Claude resumes the same turn without further tool
            // calls.
            .init(offset: 0.50, json: #"{"hook_event_name":"Stop","session_id":"sess-bug-2"}"#),
            .init(offset: 0.60, json: #"{"hook_event_name":"Notification","session_id":"sess-bug-2","message":"Claude is waiting for your input"}"#),
        ]

        for event in events {
            let payloads = try AgentEventBridge.claudeMakePayloads(
                from: AgentEventBridge.claudeParseInput(Data(event.json.utf8)),
                environment: env,
                sessionStore: sessionStore
            )
            for payload in payloads {
                reducer.apply(payload, now: baseTime.addingTimeInterval(event.offset))
            }
        }

        let reduced = reducer.reducedStatus(now: baseTime.addingTimeInterval(0.7))
        XCTAssertEqual(
            reduced?.state, .idle,
            "Cached structured interaction from AskUserQuestion must not survive Stop. Got state=\(String(describing: reduced?.state)) interactionKind=\(String(describing: reduced?.interactionKind)) text=\(reduced?.text ?? "nil")"
        )
        XCTAssertEqual(reduced?.interactionKind, PaneAgentInteractionKind.none)
    }

    private func environment(pid: String? = nil) -> [String: String] {
        var env = defaultEnvironment
        if let pid { env["ZENTTY_CLAUDE_PID"] = pid }
        return env
    }

    private struct ReplayEvent {
        let offset: TimeInterval
        let json: String
    }
}
