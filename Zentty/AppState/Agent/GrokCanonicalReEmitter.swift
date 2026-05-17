import Foundation

/// Decides which canonical Agent Status Protocol events to *additionally* send
/// when forwarding a Grok hook payload.
///
/// Grok's hook scripts pipe a single `zentty ipc agent-event --adapter=grok`
/// invocation. The bench (and the app's IPC server) treat that as one record
/// with `event_name` set to the raw hook event (`PreToolUse`, `Notification`,
/// `SessionStart`, …). The bench validation profile also expects discrete
/// `task.progress`, `agent.needs-input`, and `session.start` records — those
/// used to be minted in bash with `jq`. This type mints them in Swift so the
/// hook script can stay as a single `exec` line with zero runtime dependencies.
///
/// This file is intentionally Foundation-only so it can be compiled into both
/// the app and the CLI target without dragging in `AgentStatusPayload` and the
/// rest of the state graph.
enum GrokCanonicalReEmitter: HookCanonicalReEmitter {

    /// Returns canonical JSON envelopes (one per IPC request) to emit alongside
    /// the raw `--adapter=grok` forward. Returns an empty array when the payload
    /// contains nothing worth re-emitting (or is already canonical itself).
    static func reEmissions(forHookPayload data: Data) -> [String] {
        guard !data.isEmpty,
              let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        // Already-canonical v1 payloads get forwarded as-is; re-emitting would duplicate.
        if (jsonObject["version"] as? Int) == 1,
           let event = jsonObject["event"] as? String, !event.isEmpty {
            return []
        }

        let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName", "event", "type"])?.lowercased()

        var hookToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
        var toolInput = JSONKeyAccess.firstObject(in: jsonObject, keys: ["tool_input", "toolInput", "input"])
        if hookToolName == nil || toolInput == nil {
            for nestKey in ["tool_use", "toolUse", "tool_use_input", "input"] {
                if let nested = jsonObject[nestKey] as? [String: Any] {
                    if hookToolName == nil {
                        hookToolName = JSONKeyAccess.firstString(in: nested, keys: ["name", "tool_name", "toolName", "tool"])
                    }
                    if toolInput == nil {
                        toolInput = JSONKeyAccess.firstObject(in: nested, keys: ["input", "tool_input", "toolInput"]) ?? nested
                    }
                    if hookToolName != nil && toolInput != nil { break }
                }
            }
        }

        var emissions: [String] = []

        switch hookEventName {
        case "pretooluse", "pre_tool_use", "pretool":
            let lowerTool = hookToolName?.lowercased() ?? ""
            if isTodoToolName(lowerTool), let progress = todoProgress(in: toolInput) {
                emissions.append(taskProgressEnvelope(done: progress.done, total: progress.total))
            }
            if isAskToolName(lowerTool) {
                let text = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description", "question"])
                    ?? JSONKeyAccess.firstString(in: toolInput, keys: ["question", "prompt", "message", "text"])
                    ?? "Grok needs your input"
                emissions.append(needsInputEnvelope(text: text, kind: "question"))
            }

        case "notification", "permission", "approval":
            let text = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "title", "description", "question"])
                ?? "Grok needs your input"
            let notificationType = (JSONKeyAccess.firstString(in: jsonObject, keys: ["notification_type", "notificationType"]) ?? hookEventName ?? "").lowercased()
            if shouldClassifyAsNeedsInput(notificationType: notificationType, text: text) {
                let kind = classifyInteraction(notificationType: notificationType, text: text)
                emissions.append(needsInputEnvelope(text: text, kind: kind))
            }

        case "sessionstart", "session_start", "start":
            if let sessionID = resolveSessionID(in: jsonObject) {
                emissions.append(sessionStartEnvelope(sessionID: sessionID))
            }

        default:
            break
        }

        return emissions
    }

    // MARK: - Detection

    private static func isTodoToolName(_ lowered: String) -> Bool {
        guard !lowered.isEmpty else { return false }
        return lowered.contains("todowrite")
            || lowered.contains("todo_write")
            || lowered.contains("writetodos")
            || lowered == "todo"
    }

    private static func isAskToolName(_ lowered: String) -> Bool {
        guard !lowered.isEmpty else { return false }
        return lowered.contains("askuser")
            || lowered.contains("ask_user")
            || lowered.contains("askquestion")
    }

    /// Structured allowlist of notification_type values that signal an input
    /// request, plus a narrow message-content fallback. Mirrors the old shell
    /// allowlist, but with word-boundary matching so "Task completed" never
    /// gets misclassified as needs-input (the substring "ask" lives inside
    /// "task" and the old regex flagged it).
    private static func shouldClassifyAsNeedsInput(notificationType: String, text: String) -> Bool {
        let typeAllowlist: Set<String> = [
            "permission",
            "permission_request",
            "permissionrequest",
            "ask",
            "askuser",
            "ask_user_question",
            "askuserquestion",
            "question",
            "approval",
        ]
        if typeAllowlist.contains(notificationType) {
            return true
        }
        let lower = text.lowercased()
        // Only unambiguous words. Never the bare "ask" alternative (matches "task").
        if containsWord(lower, "permission") || containsWord(lower, "approve")
            || containsWord(lower, "approval") || containsWord(lower, "needs input")
            || containsWord(lower, "need input") {
            return true
        }
        return false
    }

    private static func classifyInteraction(notificationType: String, text: String) -> String {
        let questionTypes: Set<String> = [
            "ask", "askuser", "ask_user_question", "askuserquestion", "question",
        ]
        if questionTypes.contains(notificationType) {
            return "question"
        }
        let lower = text.lowercased()
        if containsWord(lower, "question") {
            return "question"
        }
        // Trailing "?" suggests a question even when the type field is generic.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            return "question"
        }
        return "approval"
    }

    /// Word-boundary substring check: `lowerHaystack` must contain `needle`
    /// flanked by non-letter characters (or string boundaries). Prevents
    /// "ask" from matching inside "task" and similar false positives.
    private static func containsWord(_ lowerHaystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = lowerHaystack.startIndex
        while let range = lowerHaystack.range(of: needle, range: searchStart..<lowerHaystack.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound > lowerHaystack.startIndex else { return true }
                let prev = lowerHaystack[lowerHaystack.index(before: range.lowerBound)]
                return !prev.isLetter
            }()
            let afterOK: Bool = {
                guard range.upperBound < lowerHaystack.endIndex else { return true }
                let next = lowerHaystack[range.upperBound]
                return !next.isLetter
            }()
            if beforeOK && afterOK {
                return true
            }
            searchStart = lowerHaystack.index(after: range.lowerBound)
        }
        return false
    }

    /// Resolves a Grok session identifier from any of the shapes the beta has
    /// been observed to emit.
    private static func resolveSessionID(in jsonObject: [String: Any]) -> String? {
        if let direct = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID", "id"]) {
            return direct
        }
        return JSONKeyAccess.firstStringPath(in: jsonObject, paths: [
            ["session", "id"],
            ["session", "sessionId"],
            ["context", "session_id"],
            ["context", "sessionId"],
            ["data", "session_id"],
            ["data", "sessionId"],
            ["data", "id"],
        ])
    }

    /// Extracts `(done, total)` from a TodoWrite-shaped tool input, supporting
    /// the variants Grok and Claude-compat agents have been seen to send.
    static func todoProgress(in input: [String: Any]?) -> (done: Int, total: Int)? {
        guard let input else { return nil }

        if let done = JSONKeyAccess.firstInt(in: input, keys: ["done", "completedCount", "completed_count"]),
           let total = JSONKeyAccess.firstInt(in: input, keys: ["total", "totalCount", "total_count"]),
           total > 0 {
            return (done, total)
        }

        let candidates: [[[String: Any]]?] = [
            input["todos"] as? [[String: Any]],
            (input["input"] as? [String: Any])?["todos"] as? [[String: Any]],
            input["tasks"] as? [[String: Any]],
            (input["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]],
            (input["toolInput"] as? [String: Any])?["todos"] as? [[String: Any]],
            (input["tool_use"] as? [String: Any])?["todos"] as? [[String: Any]],
            (input["toolUse"] as? [String: Any])?["todos"] as? [[String: Any]],
        ]
        // `.first(where: { !$0.isEmpty })` so an empty primary location (e.g.
        // `tool_input.todos = []` alongside a populated `tool_input.input.todos`)
        // falls through instead of silently producing no progress.
        guard let todos = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }

        let done = todos.filter { todo in
            let status = ((todo["status"] as? String) ?? (todo["state"] as? String) ?? "").lowercased()
            return status.contains("done") || status.contains("complete")
        }.count
        return (done, todos.count)
    }

    // MARK: - Canonical envelopes

    /// Built via `JSONSerialization` (sortedKeys) so the JSON is valid by
    /// construction. `sortedKeys` also makes the bench's text-level assertions
    /// deterministic — keys come out alphabetically (`agent`, `event`,
    /// `progress`/`session`/`state`, `version`).

    static func taskProgressEnvelope(done: Int, total: Int) -> String {
        serialize([
            "version": 1,
            "event": "task.progress",
            "agent": ["name": "Grok"],
            "progress": ["done": done, "total": total],
        ])
    }

    static func needsInputEnvelope(text: String, kind: String) -> String {
        serialize([
            "version": 1,
            "event": "agent.needs-input",
            "agent": ["name": "Grok"],
            "state": [
                "text": text,
                "interaction": ["kind": kind, "text": text],
            ],
        ])
    }

    static func sessionStartEnvelope(sessionID: String) -> String {
        serialize([
            "version": 1,
            "event": "session.start",
            "agent": ["name": "Grok"],
            "session": ["id": sessionID],
        ])
    }

    private static func serialize(_ object: [String: Any]) -> String {
        // `.sortedKeys` makes the bench's text-level `.contains(...)` assertions
        // deterministic. `.withoutEscapingSlashes` keeps file paths like `/tmp/foo`
        // legible — without it JSONSerialization escapes every `/` to `\/`, which
        // is valid JSON but harder to grep and reads strangely in logs.
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
