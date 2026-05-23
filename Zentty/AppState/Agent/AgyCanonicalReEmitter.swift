import Foundation

/// Translates raw Antigravity hook payloads into additional canonical
/// Agent Status Protocol v1 events.
///
/// Most agents emit hook events under their own naming scheme (`SessionStart`,
/// `PreInvocation`, `Stop`, ...). Downstream consumers — the bench harness,
/// telemetry, the worklane UI — speak the canonical protocol
/// (`session.start`, `agent.running`, `agent.idle`, `agent.needs-input`,
/// `session.end`). This re-emitter mints the canonical events alongside the
/// raw forward so both audiences are served from a single hook invocation.
///
/// The re-emitter is intentionally narrow: it only emits canonical events
/// for state transitions a consumer cannot reconstruct from the raw payload
/// alone. Events the adapter already turns into local
/// `AgentStatusPayload`s — e.g. `PostToolUse` or progress-only Notifications
/// — are deliberately omitted.
enum AgyCanonicalReEmitter: HookCanonicalReEmitter {

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

        let hookEventName = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["hook_event_name", "hookEventName", "event", "type"]
        )?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        var emissions: [String] = []

        switch hookEventName {
        case "sessionstart", "session_start", "start", "preinvocation", "pre_invocation":
            if let sessionID = resolveSessionID(in: jsonObject) {
                emissions.append(sessionStartEnvelope(
                    sessionID: sessionID,
                    cwd: resolveCWD(in: jsonObject)
                ))
            }

        case "stop", "turncompletion", "turn_completion":
            // Only surface `agent.idle` when the Antigravity CLI confirms
            // no background work is pending. `fullyIdle == false` means
            // tools are still running; in that case we stay silent and let
            // a later Stop / Notification advance the state.
            if !isBackgroundWorkPending(in: jsonObject), let sessionID = resolveSessionID(in: jsonObject) {
                emissions.append(idleEnvelope(
                    sessionID: sessionID,
                    cwd: resolveCWD(in: jsonObject)
                ))
            }

        case "sessionend", "session_end", "end":
            if let sessionID = resolveSessionID(in: jsonObject) {
                emissions.append(sessionEndEnvelope(
                    sessionID: sessionID,
                    cwd: resolveCWD(in: jsonObject)
                ))
            }

        case "pretooluse", "pre_tool_use", "pretool", "pre_tool":
            if let needsInput = needsInputEnvelope(in: jsonObject) {
                emissions.append(needsInput)
            }

        case "notification", "permission", "approval":
            if let needsInput = notificationNeedsInputEnvelope(in: jsonObject) {
                emissions.append(needsInput)
            }

        default:
            break
        }

        return emissions
    }

    // MARK: - Field resolution

    private static func resolveSessionID(in jsonObject: [String: Any]) -> String? {
        JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["session_id", "sessionId", "sessionID", "conversation_id", "conversationId"]
        )
    }

    private static func resolveCWD(in jsonObject: [String: Any]) -> String? {
        if let cwd = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        ) {
            return cwd
        }
        return JSONKeyAccess.firstStringArray(in: jsonObject, keys: ["workspacePaths"])?.first
    }

    private static func isBackgroundWorkPending(in jsonObject: [String: Any]) -> Bool {
        for key in ["fullyIdle", "fully_idle"] {
            if let value = jsonObject[key] as? Bool {
                return !value
            }
            if let value = jsonObject[key] as? NSNumber {
                return !value.boolValue
            }
        }
        return false
    }

    // MARK: - Canonical envelopes

    private static func sessionStartEnvelope(sessionID: String, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "session.start",
            "agent": ["name": "Antigravity"],
            "session": ["id": sessionID],
        ]
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func idleEnvelope(sessionID: String, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "agent.idle",
            "agent": ["name": "Antigravity"],
            "session": ["id": sessionID],
        ]
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func sessionEndEnvelope(sessionID: String, cwd: String?) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "session.end",
            "agent": ["name": "Antigravity"],
            "session": ["id": sessionID],
        ]
        if let cwd {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    private static func needsInputEnvelope(in jsonObject: [String: Any]) -> String? {
        let toolCall = JSONKeyAccess.firstObject(in: jsonObject, keys: ["toolCall", "tool_call"])
        let toolName = JSONKeyAccess.firstString(in: toolCall, keys: ["name", "tool_name", "toolName"])
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
        guard isAskTool(toolName) else { return nil }

        let args = JSONKeyAccess.firstObject(in: toolCall, keys: ["args", "arguments"])
            ?? JSONKeyAccess.firstObject(in: jsonObject, keys: ["args", "arguments", "tool_input", "toolInput"])
        let text = JSONKeyAccess.firstString(in: args, keys: ["question", "prompt", "message", "text", "description"])
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
            ?? "Antigravity needs your input"
        let kind = normalized(toolName) == "ask_question" ? "decision" : "approval"

        return buildNeedsInputEnvelope(text: text, kind: kind, jsonObject: jsonObject)
    }

    private static func notificationNeedsInputEnvelope(in jsonObject: [String: Any]) -> String? {
        // Antigravity Notification events arrive both for purely informational
        // updates and for approval/question prompts. Treat them as needs-input
        // only when the payload contains text — otherwise the UI shouldn't
        // change state.
        let text = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["message", "body", "text", "prompt", "description"]
        )
        guard let text, !text.isEmpty else { return nil }

        let inferredKind: String = {
            switch JSONKeyAccess.firstString(in: jsonObject, keys: ["kind", "type", "notification_type"])?.lowercased() {
            case "question", "decision":
                return "decision"
            default:
                return "approval"
            }
        }()

        return buildNeedsInputEnvelope(text: text, kind: inferredKind, jsonObject: jsonObject)
    }

    private static func buildNeedsInputEnvelope(text: String, kind: String, jsonObject: [String: Any]) -> String {
        var object: [String: Any] = [
            "version": 1,
            "event": "agent.needs-input",
            "agent": ["name": "Antigravity"],
            "state": ["interaction": ["kind": kind, "text": text]],
        ]
        if let sessionID = resolveSessionID(in: jsonObject) {
            object["session"] = ["id": sessionID]
        }
        if let cwd = resolveCWD(in: jsonObject) {
            object["context"] = ["workingDirectory": cwd]
        }
        return serialize(object)
    }

    // MARK: - Misc

    private static func isAskTool(_ name: String?) -> Bool {
        switch normalized(name) {
        case "ask_permission", "ask_question":
            return true
        default:
            return false
        }
    }

    private static func normalized(_ name: String?) -> String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func serialize(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
