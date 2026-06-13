import Foundation
import XCTest
@testable import Zentty

final class VibeCanonicalReEmitterTests: XCTestCase {

    // MARK: - post_agent_turn tests

    func test_postAgentTurn_returns_idle_payload() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "post_agent_turn",
            "session_id": "test-session-123",
            "parent_session_id": "parent-123",
            "transcript_path": "/path/to/transcript.md",
            "cwd": "/test/working/dir"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1, "Should return exactly one payload for post_agent_turn")
        
        guard let payload = payloads.first else {
            XCTFail("Expected at least one payload")
            return
        }

        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["event"] as? String, "agent.idle")

        if let session = payload["session"] as? [String: Any] {
            XCTAssertEqual(session["id"] as? String, "test-session-123")
        } else {
            XCTFail("Expected session in payload")
        }

        if let context = payload["context"] as? [String: Any] {
            XCTAssertEqual(context["workingDirectory"] as? String, "/test/working/dir")
        } else {
            XCTFail("Expected context in payload")
        }
    }

    func test_postAgentTurn_without_optional_fields() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "post_agent_turn"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "agent.idle")
        XCTAssertNil(payload["session"])
        XCTAssertNil(payload["context"])
    }

    // MARK: - before_tool tests

    func test_beforeTool_with_AskUserQuestion_returns_needsInput_question() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "before_tool",
            "session_id": "test-session-123",
            "tool_name": "AskUserQuestion",
            "tool_call_id": "call-123",
            "tool_input": [
                "question": "What is your name?"
            ],
            "cwd": "/test/working/dir"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["event"] as? String, "agent.needs-input")
        
        if let state = payload["state"] as? [String: Any] {
            XCTAssertEqual(state["text"] as? String, "What is your name?")
            if let interaction = state["interaction"] as? [String: Any] {
                XCTAssertEqual(interaction["kind"] as? String, "question")
                XCTAssertEqual(interaction["text"] as? String, "What is your name?")
            } else {
                XCTFail("Expected interaction in state")
            }
        } else {
            XCTFail("Expected state in payload")
        }
        
        if let session = payload["session"] as? [String: Any] {
            XCTAssertEqual(session["id"] as? String, "test-session-123")
        }
    }

    func test_beforeTool_with_ask_user_question_variant() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "before_tool",
            "tool_name": "ask_user_question",
            "tool_input": [
                "questions": [
                    ["question": "Continue?"]
                ]
            ]
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "agent.needs-input")
        if let state = payload["state"] as? [String: Any] {
            XCTAssertEqual(state["text"] as? String, "Continue?")
        }
    }

    func test_beforeTool_with_regular_tool_returns_running() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "before_tool",
            "session_id": "test-session-123",
            "tool_name": "grep",
            "cwd": "/test/working/dir"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "agent.running")
        if let session = payload["session"] as? [String: Any] {
            XCTAssertEqual(session["id"] as? String, "test-session-123")
        }
    }

    // MARK: - after_tool tests

    func test_afterTool_with_AskUserQuestion_success_returns_inputResolved() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "after_tool",
            "session_id": "test-session-123",
            "tool_name": "AskUserQuestion",
            "tool_call_id": "call-123",
            "tool_status": "success",
            "tool_output": ["text": "Yes"],
            "cwd": "/test/working/dir"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["event"] as? String, "agent.input-resolved")
        
        if let session = payload["session"] as? [String: Any] {
            XCTAssertEqual(session["id"] as? String, "test-session-123")
        }
    }

    func test_afterTool_with_AskUserQuestion_failure_returns_inputResolved() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "after_tool",
            "session_id": "test-session-123",
            "tool_name": "AskUserQuestion",
            "tool_status": "error",
            "tool_error": "User cancelled"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "agent.input-resolved")
    }

    func test_afterTool_with_vibe_todo_tool_computes_progress_from_status() throws {
        // Real Mistral Vibe `todo` output shape: a full todo list plus a
        // total_count, NOT a done/total pair. Progress is derived from the
        // status of each item (done == "completed").
        let hookPayload: [String: Any] = [
            "hook_event_name": "after_tool",
            "session_id": "test-session-123",
            "tool_name": "todo",
            "tool_status": "success",
            "tool_output": [
                "message": "Updated 4 todos",
                "total_count": 4,
                "todos": [
                    ["id": "1", "content": "Review", "status": "completed"],
                    ["id": "2", "content": "Identify", "status": "completed"],
                    ["id": "3", "content": "Suggest", "status": "in_progress"],
                    ["id": "4", "content": "Verify", "status": "pending"],
                ],
            ],
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "task.progress")
        if let progress = payload["progress"] as? [String: Any] {
            XCTAssertEqual(progress["done"] as? Int, 2, "two completed todos")
            XCTAssertEqual(progress["total"] as? Int, 4)
        } else {
            XCTFail("Expected progress in payload")
        }
    }

    func test_afterTool_with_regular_tool_returns_running() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "after_tool",
            "session_id": "test-session-123",
            "tool_name": "grep",
            "tool_status": "success",
            "cwd": "/test/working/dir"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)

        XCTAssertEqual(payloads.count, 1)
        guard let payload = payloads.first else { return }

        XCTAssertEqual(payload["event"] as? String, "agent.running")
    }

    // MARK: - Unknown hook event

    func test_unknown_hook_event_returns_empty() throws {
        let hookPayload: [String: Any] = [
            "hook_event_name": "unknown_event",
            "session_id": "test-session-123"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)
        XCTAssertTrue(payloads.isEmpty)
    }

    // MARK: - Missing hook_event_name

    func test_missing_hook_event_name_returns_empty() throws {
        let hookPayload: [String: Any] = [
            "session_id": "test-session-123"
        ]

        let payloads = VibeCanonicalReEmitter.canonicalPayloads(from: hookPayload)
        XCTAssertTrue(payloads.isEmpty)
    }

}
