import Foundation

// MARK: - Hermes Agent Adapter

extension AgentEventBridge {
    static func hermesAdapter(
        data: Data,
        defaultEventName: String? = nil,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        if (jsonObject["version"] as? Int) == 1,
           let eventName = jsonObject["event"] as? String, !eventName.isEmpty {
            let input = try parseInput(data)
            var payloads = try makePayloads(from: input, environment: environment)
            if input.sessionID != nil,
               payloads.contains(where: { $0.signalKind == .pid }) == false,
               let pid = parseAgentPID(from: environment, key: "ZENTTY_HERMES_PID") {
                let target = try currentTarget(from: environment)
                payloads.insert(
                    pidPayload(
                        target: target,
                        toolName: AgentTool.hermes.displayName,
                        pid: pid,
                        event: .attach,
                        sessionID: input.sessionID
                    ),
                    at: 0
                )
            }
            return payloads
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.hermes.displayName
        let sessionID = hermesSessionID(in: jsonObject)
        let cwd = hermesWorkingDirectory(in: jsonObject)
        let pid = parseAgentPID(from: environment, key: "ZENTTY_HERMES_PID")
        let resolvedEvent = (defaultEventName
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName", "event", "type"])
            ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch resolvedEvent {
        case "on_session_start", "on_session_reset", "session_start", "start":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd))
            return payloads

        case "pre_llm_call", "post_tool_call", "post_approval_response":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "pre_tool_call":
            if hermesIsClarifyTool(in: jsonObject) {
                let (message, kind) = hermesClarifyInteraction(in: jsonObject)
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: message,
                    lifecycleEvent: .update,
                    interactionKind: kind,
                    confidence: .explicit,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                )]
            }
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "post_llm_call":
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd)]

        case "pre_approval_request":
            let (message, kind) = hermesApprovalInteraction(in: jsonObject)
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: message,
                lifecycleEvent: .update,
                interactionKind: kind,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case "on_session_end", "on_session_finalize", "session_end", "end":
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd)]

        default:
            return []
        }
    }

    private static func hermesSessionID(in jsonObject: [String: Any]) -> String? {
        JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID", "id"])
            ?? JSONKeyAccess.firstStringPath(in: jsonObject, paths: [
                ["session", "id"],
                ["session", "session_id"],
                ["context", "session_id"],
                ["context", "sessionId"],
            ])
    }

    private static func hermesWorkingDirectory(in jsonObject: [String: Any]) -> String? {
        JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
            ?? JSONKeyAccess.firstStringPath(in: jsonObject, paths: [
                ["context", "cwd"],
                ["context", "workingDirectory"],
                ["context", "working_directory"],
            ])
    }

    private static func hermesApprovalInteraction(in jsonObject: [String: Any]) -> (String, PaneAgentInteractionKind) {
        let toolInput = JSONKeyAccess.firstObject(in: jsonObject, keys: ["tool_input", "toolInput", "input", "args", "arguments"])
        if let message = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"]) {
            return (message, .approval)
        }
        if let command = JSONKeyAccess.firstString(in: toolInput, keys: ["command", "cmd"]) {
            return ("Hermes needs approval to run: \(command)", .approval)
        }

        let message = JSONKeyAccess.firstString(in: toolInput, keys: ["message", "body", "text", "prompt", "description"])
            ?? "Hermes needs your approval"
        return (message, .approval)
    }

    private static func hermesIsClarifyTool(in jsonObject: [String: Any]) -> Bool {
        let toolCall = JSONKeyAccess.firstObject(in: jsonObject, keys: ["tool_call", "toolCall", "tool"])
        let rawName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool", "name"])
            ?? JSONKeyAccess.firstString(in: toolCall, keys: ["tool_name", "toolName", "name"])
        return rawName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clarify"
    }

    private static func hermesClarifyInteraction(in jsonObject: [String: Any]) -> (String, PaneAgentInteractionKind) {
        let toolInput = hermesToolInput(in: jsonObject)
        let question = JSONKeyAccess.firstString(in: toolInput, keys: ["question", "prompt", "message", "text", "description"])
            ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["question", "prompt", "message", "text", "description"])
            ?? "Hermes needs your input"
        let choices = hermesStringArray(in: toolInput, keys: ["choices", "options"])
        guard !choices.isEmpty else {
            return (question, .question)
        }
        return (([question] + choices.map { "- \($0)" }).joined(separator: "\n"), .decision)
    }

    private static func hermesToolInput(in jsonObject: [String: Any]) -> [String: Any]? {
        if let toolInput = JSONKeyAccess.firstObject(in: jsonObject, keys: ["tool_input", "toolInput", "input", "args", "arguments"]) {
            return toolInput
        }
        let toolCall = JSONKeyAccess.firstObject(in: jsonObject, keys: ["tool_call", "toolCall", "tool"])
        return JSONKeyAccess.firstObject(in: toolCall, keys: ["tool_input", "toolInput", "input", "args", "arguments"])
    }

    private static func hermesStringArray(in object: [String: Any]?, keys: [String]) -> [String] {
        guard let object else { return [] }
        for key in keys {
            if let values = object[key] as? [String] {
                return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let values = object[key] as? [[String: Any]] {
                let labels = values.compactMap {
                    JSONKeyAccess.firstString(in: $0, keys: ["label", "text", "value", "name"])
                }
                if !labels.isEmpty {
                    return labels
                }
            }
        }
        return []
    }
}

// MARK: - Adapter conformance

enum HermesEventAdapter: AgentEventAdapting {
    static let adapterName = "hermes"
    static let suppressesErrors = true
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.hermesAdapter(
            data: data,
            defaultEventName: positionalArguments.first,
            environment: environment
        )
    }
}
