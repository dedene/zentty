import Foundation

/// Re-emits canonical Agent Status Protocol events derived from raw Mistral Vibe
/// hook payloads.
///
/// Mistral Vibe hook invocations provide a JSON payload on stdin containing:
/// - Common: `session_id`, `parent_session_id`, `transcript_path`, `cwd`, `hook_event_name`
/// - `before_tool`: adds `tool_name`, `tool_call_id`, `tool_input`
/// - `after_tool`: adds `tool_name`, `tool_call_id`, `tool_input`, `tool_status`, `tool_output`, `tool_error`, `duration_ms`
/// - `post_agent_turn`: common fields only
///
/// This re-emitter inspects the hook payload and emits canonical Agent Status Protocol
/// envelopes for known semantic events (questions, permissions, task progress).
///
/// See: https://github.com/mistralai/mistral-vibe#hooks-experimental
/// See: HookCanonicalReEmitter protocol
enum VibeHookCanonicalReEmitter: HookCanonicalReEmitter {

    static func reEmissions(forHookPayload data: Data) -> [String] {
        guard !data.isEmpty,
              let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        // Already-canonical v1 payloads get forwarded as-is by the IPC
        // layer; we don't need to add anything.
        if (jsonObject["version"] as? Int) == 1,
           let event = jsonObject["event"] as? String, !event.isEmpty {
            return []
        }

        guard let hookEventName = jsonObject["hook_event_name"] as? String else {
            return []
        }

        let sessionID = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["session_id", "sessionId"]
        )
        let cwd = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["cwd", "working_directory", "workingDirectory"]
        )
        let toolName = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["tool_name", "toolName"]
        )
        let toolInput = jsonObject["tool_input"] as? [String: Any]
        let toolOutput = jsonObject["tool_output"] as? [String: Any]
        let toolStatus = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["tool_status", "toolStatus"]
        )

        var emissions: [String] = []

        switch hookEventName {
        case "post_agent_turn":
            // Agent completed a turn - emit agent.running
            emissions.append(runningEnvelope(sessionID: sessionID, cwd: cwd))

        case "before_tool":
            // Check for AskUserQuestion
            if isAskUserQuestionTool(toolName) {
                let text = extractQuestionText(from: toolInput) ?? "Vibe needs your input"
                emissions.append(needsInputEnvelope(text: text, kind: "question", sessionID: sessionID, cwd: cwd))
            } else if isPermissionTool(toolName) {
                let text = extractPermissionText(from: toolInput) ?? "Vibe requests permission"
                emissions.append(needsInputEnvelope(text: text, kind: "approval", sessionID: sessionID, cwd: cwd))
            } else {
                // For other tools, emit running
                emissions.append(runningEnvelope(sessionID: sessionID, cwd: cwd))
            }

        case "after_tool":
            // Check for AskUserQuestion completion
            if isAskUserQuestionTool(toolName) {
                emissions.append(inputResolvedEnvelope(sessionID: sessionID, cwd: cwd))
            } else if isTaskTool(toolName) {
                if let progress = extractTaskProgress(from: toolOutput) {
                    emissions.append(taskProgressEnvelope(done: progress.done, total: progress.total, sessionID: sessionID))
                }
            } else {
                // For other tools, emit running
                emissions.append(runningEnvelope(sessionID: sessionID, cwd: cwd))
            }

        default:
            break
        }

        return emissions
    }

    // MARK: - Tool Detection

    private static func isAskUserQuestionTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let normalized = toolName.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("ask_user_question")
            || normalized == "askuserquestion"
            || normalized == "ask_user_question"
    }

    private static func isPermissionTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let normalized = toolName.lowercased()
        return normalized.contains("permission")
            || normalized.contains("approve")
            || normalized.contains("approval")
    }

    private static func isTaskTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let normalized = toolName.lowercased()
        return normalized.contains("todo")
            || normalized.contains("task")
    }

    // MARK: - Input Extraction

    private static func extractQuestionText(from toolInput: [String: Any]?) -> String? {
        guard let toolInput else { return nil }

        if let question = toolInput["question"] as? String {
            return question
        }

        if let questions = toolInput["questions"] as? [[String: Any]], let first = questions.first {
            if let question = first["question"] as? String {
                return question
            }
        }

        return JSONKeyAccess.firstString(
            in: toolInput,
            keys: ["text", "prompt", "message"]
        )
    }

    private static func extractPermissionText(from toolInput: [String: Any]?) -> String? {
        guard let toolInput else { return nil }

        return JSONKeyAccess.firstString(
            in: toolInput,
            keys: ["message", "prompt", "text", "description"]
        )
    }

    private static func extractTaskProgress(from toolOutput: [String: Any]?) -> (done: Int, total: Int)? {
        guard let toolOutput else { return nil }

        if let done = toolOutput["done"] as? Int, let total = toolOutput["total"] as? Int {
            return (done, total)
        }

        if let progress = toolOutput["progress"] as? [String: Any],
           let done = progress["done"] as? Int,
           let total = progress["total"] as? Int {
            return (done, total)
        }

        if let result = toolOutput["result"] as? [String: Any],
           let done = result["done"] as? Int,
           let total = result["total"] as? Int {
            return (done, total)
        }

        return nil
    }

    // MARK: - Envelope Builders

    private static func runningEnvelope(sessionID: String?, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "agent.running",
            "agent": ["name": "Mistral Vibe"],
        ]
        if let sessionID {
            object["session"] = ["id": sessionID]
        }
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func needsInputEnvelope(text: String, kind: String, sessionID: String?, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "agent.needs-input",
            "agent": ["name": "Mistral Vibe"],
            "state": ["interaction": ["kind": kind, "text": text]],
        ]
        if let sessionID {
            object["session"] = ["id": sessionID]
        }
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func inputResolvedEnvelope(sessionID: String?, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "agent.input-resolved",
            "agent": ["name": "Mistral Vibe"],
        ]
        if let sessionID {
            object["session"] = ["id": sessionID]
        }
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func taskProgressEnvelope(done: Int, total: Int, sessionID: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "task.progress",
            "agent": ["name": "Mistral Vibe"],
            "progress": [
                "done": done,
                "total": total,
            ],
        ]
        if let sessionID {
            object["session"] = ["id": sessionID]
        }
        return serialize(object)
    }

    private static func serialize(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
