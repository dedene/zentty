import Foundation
import os

private let vibeReEmitterLogger = Logger(subsystem: "be.zenjoy.zentty", category: "VibeCanonicalReEmitter")

/// Translates raw Mistral Vibe hook payloads into canonical Agent Status Protocol
/// events that Zentty can process.
///
/// Mistral Vibe hook invocations provide a JSON payload on stdin containing:
/// - Common: `session_id`, `parent_session_id`, `transcript_path`, `cwd`, `hook_event_name`
/// - `before_tool`: adds `tool_name`, `tool_call_id`, `tool_input`
/// - `after_tool`: adds `tool_name`, `tool_call_id`, `tool_input`, `tool_status`, `tool_output`, `tool_output_text`, `tool_error`, `duration_ms`
/// - `post_agent_turn`: common fields only
///
/// This re-emitter inspects the hook payload and fans out additional canonical
/// Agent Status Protocol envelopes when the payload represents known semantic
/// events (questions, permissions, task progress, session lifecycle).
///
/// See: https://github.com/mistralai/mistral-vibe#hooks-experimental
/// See: Agent Status Protocol (docs/agent-status-protocol.md)
enum VibeCanonicalReEmitter {

    /// Inspects the raw Vibe hook payload and returns zero or more canonical
    /// Agent Status Protocol payloads to post alongside the raw hook forward.
    ///
    /// - Parameter hookPayload: the raw JSON payload from Vibe's hook invocation
    /// - Returns: array of canonical protocol envelopes
    static func canonicalPayloads(
        from hookPayload: [String: Any]
    ) -> [[String: Any]] {
        guard let hookEventName = hookPayload["hook_event_name"] as? String else {
            vibeReEmitterLogger.debug("No hook_event_name in payload")
            return []
        }

        let sessionID = hookPayload["session_id"] as? String
        let cwd = hookPayload["cwd"] as? String

        switch hookEventName {
        case "post_agent_turn":
            return postAgentTurnPayloads(hookPayload: hookPayload, sessionID: sessionID, cwd: cwd)

        case "before_tool":
            return beforeToolPayloads(hookPayload: hookPayload, sessionID: sessionID, cwd: cwd)

        case "after_tool":
            return afterToolPayloads(hookPayload: hookPayload, sessionID: sessionID, cwd: cwd)

        default:
            vibeReEmitterLogger.debug("Unknown Vibe hook event: \(hookEventName)")
            return []
        }
    }

    // MARK: - Event Handlers

    /// Handles `post_agent_turn` hook events.
    /// Vibe fires this after every assistant turn that ends without pending tool
    /// calls — i.e. the agent has finished responding and is now waiting for the
    /// user. We map it to `agent.idle`, NOT running: it fires at the *end* of a
    /// turn, so treating it as running would leave the pane stuck "running"
    /// after the agent stopped. Vibe has no turn-start hook, so "running" at the
    /// start of a turn is supplied by Zentty's terminal-activity heuristic.
    private static func postAgentTurnPayloads(
        hookPayload: [String: Any],
        sessionID: String?,
        cwd: String?
    ) -> [[String: Any]] {
        return [idlePayload(sessionID: sessionID, cwd: cwd)]
    }

    /// Handles `before_tool` hook events.
    /// Vibe fires this before a tool call, before the user permission prompt.
    /// We check for AskUserQuestion and permission-related tools to emit needs-input.
    private static func beforeToolPayloads(
        hookPayload: [String: Any],
        sessionID: String?,
        cwd: String?
    ) -> [[String: Any]] {
        guard let toolName = hookPayload["tool_name"] as? String else {
            return []
        }

        let toolInput = hookPayload["tool_input"] as? [String: Any]

        // AskUserQuestion is the only Vibe tool that blocks on the user.
        if isAskUserQuestionTool(toolName) {
            let questionText = extractQuestionText(from: toolInput) ?? "Vibe needs your input"
            return [needsInputPayload(kind: "question", text: questionText, sessionID: sessionID, cwd: cwd)]
        }

        // Any other tool call means the agent is actively working.
        return [runningPayload(sessionID: sessionID, cwd: cwd)]
    }

    /// Handles `after_tool` hook events.
    /// Vibe fires this after a tool call if and only if the tool body actually ran.
    /// We check for AskUserQuestion to emit input-resolved.
    private static func afterToolPayloads(
        hookPayload: [String: Any],
        sessionID: String?,
        cwd: String?
    ) -> [[String: Any]] {
        guard let toolName = hookPayload["tool_name"] as? String else {
            return []
        }

        let toolOutput = hookPayload["tool_output"] as? [String: Any]

        // The user answered an AskUserQuestion (success or cancelled alike) —
        // the agent resumes work.
        if isAskUserQuestionTool(toolName) {
            return [inputResolvedPayload(sessionID: sessionID, cwd: cwd)]
        }

        // The todo tool carries progress (completed / total).
        if isTaskTool(toolName), let progress = extractTaskProgress(from: toolOutput) {
            return [taskProgressPayload(done: progress.done, total: progress.total, sessionID: sessionID)]
        }

        // Any other tool completion means the agent is still working.
        return [runningPayload(sessionID: sessionID, cwd: cwd)]
    }

    // MARK: - Payload Builders

    private static func needsInputPayload(
        kind: String,
        text: String,
        sessionID: String?,
        cwd: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "event": "agent.needs-input",
            "agent": ["name": "Mistral Vibe"],
            "state": [
                "text": text,
                "interaction": [
                    "kind": kind,
                    "text": text,
                ]
            ]
        ]

        if let sessionID {
            payload["session"] = ["id": sessionID]
        }

        if let cwd {
            payload["context"] = ["workingDirectory": cwd]
        }

        return payload
    }

    private static func runningPayload(
        sessionID: String?,
        cwd: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "event": "agent.running",
            "agent": ["name": "Mistral Vibe"],
        ]

        if let sessionID {
            payload["session"] = ["id": sessionID]
        }

        if let cwd {
            payload["context"] = ["workingDirectory": cwd]
        }

        return payload
    }

    private static func idlePayload(
        sessionID: String?,
        cwd: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "event": "agent.idle",
            "agent": ["name": "Mistral Vibe"],
        ]

        if let sessionID {
            payload["session"] = ["id": sessionID]
        }

        if let cwd {
            payload["context"] = ["workingDirectory": cwd]
        }

        return payload
    }

    private static func inputResolvedPayload(
        sessionID: String?,
        cwd: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "event": "agent.input-resolved",
            "agent": ["name": "Mistral Vibe"],
        ]

        if let sessionID {
            payload["session"] = ["id": sessionID]
        }

        if let cwd {
            payload["context"] = ["workingDirectory": cwd]
        }

        return payload
    }

    private static func taskProgressPayload(
        done: Int,
        total: Int,
        sessionID: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "event": "task.progress",
            "agent": ["name": "Mistral Vibe"],
            "progress": [
                "done": done,
                "total": total,
            ]
        ]

        if let sessionID {
            payload["session"] = ["id": sessionID]
        }

        return payload
    }

    // MARK: - Tool Detection

    /// Returns true if the tool is AskUserQuestion (case-insensitive). Vibe's
    /// tool name is `ask_user_question`.
    private static func isAskUserQuestionTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("ask_user_question")
    }

    /// Returns true if the tool reports task progress. Vibe's tool name is
    /// `todo`.
    private static func isTaskTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("todo")
            || normalized.contains("task")
    }

    // MARK: - Input Extraction

    /// Extracts the question text from AskUserQuestion tool input.
    private static func extractQuestionText(from toolInput: [String: Any]?) -> String? {
        guard let toolInput else { return nil }

        // Try common question field names
        if let question = toolInput["question"] as? String {
            return question
        }

        if let questions = toolInput["questions"] as? [[String: Any]], let first = questions.first {
            if let question = first["question"] as? String {
                return question
            }
        }

        if let text = toolInput["text"] as? String {
            return text
        }

        if let prompt = toolInput["prompt"] as? String {
            return prompt
        }

        return nil
    }

    /// Extracts task progress from the `todo` tool's output:
    /// `{"todos": [{"status": "pending|in_progress|completed|cancelled", ...}],
    /// "total_count": N}`. done = completed todos, total = total_count.
    private static func extractTaskProgress(from toolOutput: [String: Any]?) -> (done: Int, total: Int)? {
        guard let toolOutput,
              let todos = toolOutput["todos"] as? [[String: Any]] else {
            return nil
        }
        let total = (toolOutput["total_count"] as? Int) ?? todos.count
        let done = todos.filter {
            ($0["status"] as? String)?.lowercased() == "completed"
        }.count
        return (done, total)
    }
}
