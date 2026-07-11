import Foundation

// MARK: - Antigravity Adapter

extension AgentEventBridge {
    static func agyAdapter(
        data: Data,
        defaultEventName: String? = nil,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.agy.displayName
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID", "conversation_id", "conversationId"])
        let cwd = agyWorkingDirectory(in: jsonObject)
        let transcriptPath = JSONKeyAccess.firstString(in: jsonObject, keys: ["transcript_path", "transcriptPath"])
        let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName", "event", "type"])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_AGY_PID")
        let toolCall = JSONKeyAccess.firstObject(in: jsonObject, keys: ["toolCall", "tool_call"])
        let rawToolName = JSONKeyAccess.firstString(in: toolCall, keys: ["name", "tool_name", "toolName"])
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])

        // 1. Canonical Agent Status Protocol check
        if (jsonObject["version"] as? Int) == 1,
           let eventName = jsonObject["event"] as? String, !eventName.isEmpty {
            return try makePayloads(from: parseInput(data), environment: environment)
        }

        // 2. Fallback hook names. The explicit `defaultEventName` (passed via
        // `--adapter=agy <event>` from the installed shell hook) wins so we
        // are not at the mercy of which JSON field name the Antigravity CLI
        // happens to use today; only if it's absent do we fall back to the
        // payload itself.
        let resolvedEvent = (defaultEventName ?? hookEventName ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch resolvedEvent {
        case "sessionstart", "session_start", "start":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath))
            return payloads

        case "preinvocation", "pre_invocation":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath))
            return payloads

        case "userpromptsubmit", "user_prompt_submit", "promptsubmit", "prompt_submit":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath)]

        case "postinvocation", "post_invocation":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath)]

        case "stop", "turncompletion", "turn_completion":
            // The Antigravity CLI emits `Stop` / `turn-completion` whenever a
            // turn ends, but background tool work may still be running. The
            // `fullyIdle` field disambiguates: only when it's true (or
            // absent) is the agent truly idle. When it's explicitly false we
            // surface `.unresolvedStop` so the UI doesn't flap into idle
            // while work continues in the background.
            guard agyBool(in: jsonObject, keys: ["fullyIdle", "fully_idle"]) != false else {
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .unresolvedStop,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: JSONKeyAccess.firstString(in: jsonObject, keys: ["error", "message", "terminationReason", "termination_reason"]),
                    lifecycleEvent: .update,
                    confidence: .explicit,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd,
                    agentTranscriptPath: transcriptPath
                )]
            }
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath)]

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

        case "pretool", "pre_tool", "pretooluse", "pre_tool_use":
            if agyIsAskTool(rawToolName) {
                let (message, interactionKind) = agyInteraction(in: jsonObject, toolCall: toolCall, toolName: rawToolName)
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: message,
                    lifecycleEvent: .update,
                    interactionKind: interactionKind,
                    confidence: .explicit,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd,
                    agentTranscriptPath: transcriptPath
                )]
            }
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath)]

        case "posttool", "post_tool", "posttooluse", "post_tool_use":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, transcriptPath: transcriptPath)]

        case "notification", "permission", "approval":
            let message = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
                ?? "Antigravity needs your input"
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: message,
                lifecycleEvent: .update,
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd,
                agentTranscriptPath: transcriptPath
            )]

        default:
            return []
        }
    }

    private static func agyWorkingDirectory(in jsonObject: [String: Any]) -> String? {
        JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
            ?? JSONKeyAccess.firstStringArray(in: jsonObject, keys: ["workspacePaths"])?.first
    }

    private static func agyBool(in jsonObject: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = jsonObject[key] as? Bool {
                return value
            }
            if let value = jsonObject[key] as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }

    private static func agyIsAskTool(_ name: String?) -> Bool {
        switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ask_permission", "ask_question":
            return true
        default:
            return false
        }
    }

    private static func agyInteraction(
        in jsonObject: [String: Any],
        toolCall: [String: Any]?,
        toolName: String?
    ) -> (String, PaneAgentInteractionKind) {
        let args = JSONKeyAccess.firstObject(in: toolCall, keys: ["args", "arguments"])
            ?? JSONKeyAccess.firstObject(in: jsonObject, keys: ["args", "arguments", "tool_input", "toolInput"])
        let message = JSONKeyAccess.firstString(in: args, keys: ["question", "prompt", "message", "text", "description"])
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
            ?? "Antigravity needs your input"
        let kind: PaneAgentInteractionKind = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ask_question"
            ? .decision
            : .approval
        return (message, kind)
    }
}

// MARK: - Adapter conformance

enum AgyEventAdapter: AgentEventAdapting {
    static let adapterName = "agy"
    static let suppressesErrors = true
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.agyAdapter(
            data: data,
            defaultEventName: positionalArguments.first,
            environment: environment
        )
    }
}
