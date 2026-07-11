import Foundation

// MARK: - Grok Build Adapter

extension AgentEventBridge {
    /// Adapter for Grok Build (`grok`) hooks.
    ///
    /// Grok Build is in early beta. It supports both:
    /// - Direct canonical Agent Status Protocol payloads (preferred for new integrations)
    /// - Raw hook event payloads (`PreToolUse`, `Notification`, etc.) that this
    ///   adapter maps to coarse lifecycle transitions.
    ///
    /// Payload-derived signals (`task.progress`, `agent.needs-input`,
    /// `session.start` with id) are minted as canonical events by
    /// `GrokCanonicalReEmitter` in the CLI fan-out. The adapter intentionally
    /// does **not** parse `tool_name` / `tool_input` itself — the re-emitter is
    /// the single source of truth so detection logic lives in one place.
    static func grokAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.grok.displayName
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID"])
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName", "event", "type"])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_GROK_PID")

        // Fast path: if this is already a canonical Agent Status Protocol payload, defer to
        // the shared makePayloads. The tool label resolves to "Grok" either because the hook
        // included "agent":{"name":"Grok"} or, when the name is omitted, because process/title
        // recognition (now that .grok is in AgentTool) picks it up from the wrapped binary name.
        if let version = jsonObject["version"] as? Int, version == 1,
           let eventName = jsonObject["event"] as? String, !eventName.isEmpty {
            return try makePayloads(from: parseInput(data), environment: environment)
        }

        // Hook-style path: coarse lifecycle only. Fine-grained state (task
        // progress, needs-input, session id for resume) arrives via the
        // canonical re-emit from `GrokCanonicalReEmitter`.
        switch hookEventName?.lowercased() {
        case "sessionstart", "session_start", "start":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd))
            return payloads

        case "userpromptsubmit", "user_prompt_submit", "promptsubmit", "prompt_submit":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "stop", "turncomplete", "turn_complete":
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd)]

        case "sessionend", "session_end", "end":
            return [
                AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: nil,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                pidPayload(target: target, toolName: toolName, pid: nil, event: .clear, sessionID: sessionID)
            ]

        case "pretooluse", "pre_tool_use", "pretool",
             "posttooluse", "post_tool_use":
            // Real tool activity. Canonical re-emit upgrades to needs-input
            // for ask_user_question and attaches taskProgress for todo writes.
            let lowerToolName = GrokCanonicalReEmitter
                .hookToolName(in: jsonObject)?
                .lowercased() ?? ""
            if GrokCanonicalReEmitter.isAskToolName(lowerToolName) {
                return []
            }
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "notification", "permission", "approval":
            // No-op for the lifecycle channel. Grok fires Notification after
            // Stop (e.g. "turn complete") and during needs-input waits;
            // emitting .running here would downgrade .idle or .needsInput.
            // The canonical re-emit (GrokCanonicalReEmitter) is the source of
            // truth for any legitimate state change derived from these.
            return []

        default:
            return []
        }
    }
}
