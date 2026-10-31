import Foundation

// MARK: - Copilot Adapter

extension AgentEventBridge {
    static func copilotAdapter(
        data: Data,
        defaultEventName: String?,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let rawEvent = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? copilotMappedEvent(defaultEventName)
            ?? defaultEventName

        guard let rawEvent, let event = copilotParseEvent(rawEvent) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"])
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID"])
        let toolName = AgentTool.copilot.displayName

        func statusPayload(
            _ state: PaneAgentState,
            interactionKind: PaneAgentInteractionKind? = nil,
            text: String? = nil,
            lifecycleEvent: AgentLifecycleEvent = .update,
            confidence: AgentSignalConfidence = .explicit
        ) -> AgentStatusPayload {
            lifecyclePayload(
                target: target,
                toolName: toolName,
                state: state,
                text: text,
                lifecycleEvent: lifecycleEvent,
                interactionKind: interactionKind,
                confidence: confidence,
                sessionID: sessionID,
                cwd: cwd
            )
        }

        switch event {
        case .sessionStart:
            var payloads: [AgentStatusPayload] = []
            if let pid = parseAgentPID(from: environment, key: "ZENTTY_COPILOT_PID") {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            // Seed at .idle so CopilotOSCProgressReducer can promote to .running
            // when libghostty reports OSC 9;4 activity.
            payloads.append(statusPayload(.idle))
            return payloads

        case .userPromptSubmitted:
            return [statusPayload(.running)]

        case .preToolUse:
            // Tool approval prompts arrive as a `notification` (permission_prompt):
            // preToolUse fires before Copilot decides whether to ask, so only
            // the question tool is a reliable needs-input signal here.
            let toolArg = JSONKeyAccess.firstString(in: jsonObject, keys: ["toolName", "tool_name"])
            guard copilotIsUserQuestionTool(toolArg) else {
                return []
            }
            let questionText = copilotExtractQuestionText(from: jsonObject) ?? "Copilot is asking a question"
            return [statusPayload(.needsInput, interactionKind: .question, text: questionText)]

        case .postToolUse, .postToolUseFailure:
            // A finished tool means the turn is moving again: an approved
            // permission prompt or an answered question is over. Tool
            // activity, because subagents fire these too: the reducer keeps
            // them from waking a session that agentStop already idled.
            return [statusPayload(.running, lifecycleEvent: .toolActivity)]

        case .notification:
            let notificationType = JSONKeyAccess.firstString(
                in: jsonObject,
                keys: ["notification_type", "notificationType"]
            )?.lowercased()
            let message = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "title"])
            // Notification hooks are fire-and-forget, so one can land after
            // the agentStop that ended its turn. `.strong` (not `.explicit`)
            // lets the reducer's post-stop grace drop such a straggler.
            switch notificationType {
            case "permission_prompt":
                return [statusPayload(
                    .needsInput,
                    interactionKind: .approval,
                    text: message ?? "Copilot needs your approval",
                    confidence: .strong
                )]
            case "elicitation_dialog":
                return [statusPayload(
                    .needsInput,
                    interactionKind: .question,
                    text: message ?? "Copilot is asking a question",
                    confidence: .strong
                )]
            default:
                // shell_completed, agent_completed, agent_idle, … report
                // background work, not a change in the foreground turn.
                return []
            }

        case .agentStop:
            return [statusPayload(.idle)]

        case .errorOccurred:
            return []

        case .sessionEnd:
            return [
                AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: nil,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: nil,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                ),
                pidPayload(target: target, toolName: toolName, pid: nil, event: .clear, sessionID: sessionID),
            ]
        }
    }

    private enum CopilotEvent {
        case sessionStart, sessionEnd, userPromptSubmitted
        case preToolUse, postToolUse, postToolUseFailure
        case notification, agentStop, errorOccurred
    }

    private static func copilotMappedEvent(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "session-start": return "sessionStart"
        case "session-end": return "sessionEnd"
        case "user-prompt-submitted": return "userPromptSubmitted"
        case "pre-tool-use": return "preToolUse"
        case "post-tool-use": return "postToolUse"
        case "post-tool-use-failure": return "postToolUseFailure"
        case "notification": return "notification"
        case "agent-stop": return "agentStop"
        case "error-occurred": return "errorOccurred"
        default: return nil
        }
    }

    private static func copilotParseEvent(_ rawValue: String) -> CopilotEvent? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "sessionstart": return .sessionStart
        case "sessionend": return .sessionEnd
        case "userpromptsubmitted", "userpromptsubmit": return .userPromptSubmitted
        case "pretooluse": return .preToolUse
        case "posttooluse": return .postToolUse
        case "posttoolusefailure": return .postToolUseFailure
        case "notification": return .notification
        case "agentstop", "stop": return .agentStop
        case "erroroccurred": return .errorOccurred
        default: return nil
        }
    }

    /// Copilot's built-in question tool is `ask_user`; Claude-format plugin
    /// payloads name it `AskUserQuestion`.
    private static func copilotIsUserQuestionTool(_ name: String?) -> Bool {
        guard let normalized = name?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") else {
            return false
        }
        return normalized.hasPrefix("askuser")
    }

    /// camelCase payloads carry `toolArgs` as a JSON string (an object is
    /// tolerated); snake_case payloads carry a `tool_input` object.
    private static func copilotExtractQuestionText(from payload: [String: Any]) -> String? {
        let questionKeys = ["question", "prompt", "message", "title"]
        for key in ["toolArgs", "tool_args", "tool_input", "toolInput"] {
            if let object = payload[key] as? [String: Any],
               let text = JSONKeyAccess.firstString(in: object, keys: questionKeys) {
                return text
            }
            if let string = payload[key] as? String,
               let data = string.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let text = JSONKeyAccess.firstString(in: object, keys: questionKeys) {
                return text
            }
        }
        return nil
    }
}

// MARK: - Adapter conformance

enum CopilotEventAdapter: AgentEventAdapting {
    static let adapterName = "copilot"
    static let suppressesErrors = false
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.copilotAdapter(
            data: data,
            defaultEventName: positionalArguments.first,
            environment: environment
        )
    }
}
