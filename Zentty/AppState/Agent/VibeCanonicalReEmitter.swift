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

        let normalizedToolName = toolName.lowercased()
        let toolInput = hookPayload["tool_input"] as? [String: Any]

        // Check for AskUserQuestion tool
        if isAskUserQuestionTool(normalizedToolName) {
            let questionText = extractQuestionText(from: toolInput) ?? "Vibe needs your input"
            return [needsInputPayload(kind: "question", text: questionText, sessionID: sessionID, cwd: cwd)]
        }

        // Check for permission-related tools
        if isPermissionTool(normalizedToolName) {
            let permissionText = extractPermissionText(from: toolInput) ?? "Vibe requests permission"
            return [needsInputPayload(kind: "approval", text: permissionText, sessionID: sessionID, cwd: cwd)]
        }

        // For other tools, just indicate running
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

        let normalizedToolName = toolName.lowercased()
        let toolStatus = hookPayload["tool_status"] as? String
        let toolOutput = hookPayload["tool_output"] as? [String: Any]

        // Check for AskUserQuestion completion
        if isAskUserQuestionTool(normalizedToolName) {
            // User responded to question - transition back to running
            if toolStatus == "success" {
                return [inputResolvedPayload(sessionID: sessionID, cwd: cwd)]
            }
            // If failed/cancelled, still resolve but with error context
            return [inputResolvedPayload(sessionID: sessionID, cwd: cwd)]
        }

        // Check for task/todo tools
        if isTaskTool(normalizedToolName) {
            if let progress = extractTaskProgress(from: toolOutput) {
                return [taskProgressPayload(done: progress.done, total: progress.total, sessionID: sessionID)]
            }
        }

        // For other tools, continue running
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

    /// Returns true if the tool is AskUserQuestion (case-insensitive).
    private static func isAskUserQuestionTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("ask_user_question")
            || normalized == "askuserquestion"
            || normalized == "ask_user_question"
    }

    /// Returns true if the tool appears to be a permission request.
    private static func isPermissionTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("permission")
            || normalized.contains("approve")
            || normalized.contains("approval")
    }

    /// Returns true if the tool appears to be a task/todo tool.
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

    /// Extracts permission text from tool input.
    private static func extractPermissionText(from toolInput: [String: Any]?) -> String? {
        guard let toolInput else { return nil }

        // Try to extract a meaningful permission message
        if let message = toolInput["message"] as? String {
            return message
        }

        if let prompt = toolInput["prompt"] as? String {
            return prompt
        }

        if let text = toolInput["text"] as? String {
            return text
        }

        if let description = toolInput["description"] as? String {
            return description
        }

        return nil
    }

    /// Extracts task progress from tool output.
    /// Returns (done, total) tuple if progress can be determined.
    private static func extractTaskProgress(from toolOutput: [String: Any]?) -> (done: Int, total: Int)? {
        guard let toolOutput else { return nil }

        // Mistral Vibe's `todo` tool returns its full list rather than a
        // done/total pair: {"todos": [{"status": "pending|in_progress|
        // completed|cancelled", ...}], "total_count": N}. Derive progress as
        // done = completed todos, total = total_count (falling back to count).
        if let todos = toolOutput["todos"] as? [[String: Any]] {
            let total = (toolOutput["total_count"] as? Int) ?? todos.count
            let done = todos.filter {
                ($0["status"] as? String)?.lowercased() == "completed"
            }.count
            return (done, total)
        }

        // Generic done/total shapes, kept for forward compatibility.
        if let done = toolOutput["done"] as? Int, let total = toolOutput["total"] as? Int {
            return (done, total)
        }

        if let progress = toolOutput["progress"] as? [String: Any] {
            if let done = progress["done"] as? Int, let total = progress["total"] as? Int {
                return (done, total)
            }
        }

        if let result = toolOutput["result"] as? [String: Any] {
            if let done = result["done"] as? Int, let total = result["total"] as? Int {
                return (done, total)
            }
        }

        return nil
    }
}
