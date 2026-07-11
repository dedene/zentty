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

        switch event {
        case .sessionStart:
            var payloads: [AgentStatusPayload] = []
            if let pid = parseAgentPID(from: environment, key: "ZENTTY_COPILOT_PID") {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            // Seed at .idle so CopilotOSCProgressReducer can promote to .running
            // when libghostty reports OSC 9;4 activity.
            payloads.append(AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: toolName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            ))
            return payloads

        case .userPromptSubmitted:
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .running,
                origin: .explicitHook,
                toolName: toolName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case .preToolUse:
            let toolArg = JSONKeyAccess.firstString(in: jsonObject, keys: ["toolName", "tool_name"])
            guard copilotIsUserQuestionTool(toolArg) else {
                return []
            }
            let toolArgs = JSONKeyAccess.firstString(in: jsonObject, keys: ["toolArgs", "tool_args"])
            let questionText = copilotExtractQuestionText(from: toolArgs) ?? "Copilot is asking a question"
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: questionText,
                lifecycleEvent: .update,
                interactionKind: .question,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case .postToolUse:
            let toolArg = JSONKeyAccess.firstString(in: jsonObject, keys: ["toolName", "tool_name"])
            guard copilotIsUserQuestionTool(toolArg) else {
                return []
            }
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: toolName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

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
        case sessionStart, sessionEnd, userPromptSubmitted, preToolUse, postToolUse, errorOccurred
    }

    private static func copilotMappedEvent(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "session-start": return "sessionStart"
        case "session-end": return "sessionEnd"
        case "user-prompt-submitted": return "userPromptSubmitted"
        case "pre-tool-use": return "preToolUse"
        case "post-tool-use": return "postToolUse"
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
        case "userpromptsubmitted": return .userPromptSubmitted
        case "pretooluse": return .preToolUse
        case "posttooluse": return .postToolUse
        case "erroroccurred": return .errorOccurred
        default: return nil
        }
    }

    private static func copilotIsUserQuestionTool(_ name: String?) -> Bool {
        guard let normalized = name?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") else {
            return false
        }
        return normalized.contains("askuserquestion")
    }

    private static func copilotExtractQuestionText(from toolArgs: String?) -> String? {
        guard let toolArgs,
              let data = toolArgs.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let object = jsonObject as? [String: Any] else {
            return nil
        }
        return JSONKeyAccess.firstString(in: object, keys: ["question", "prompt", "message", "title"])
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
