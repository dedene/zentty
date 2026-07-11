import Foundation

// MARK: - Kimi Adapter

extension AgentEventBridge {
    static func kimiAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.kimi.displayName
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let notificationType = JSONKeyAccess.firstString(in: jsonObject, keys: ["notification_type", "notificationType"])
        let payloadToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName"])
        let toolInput = jsonObject["tool_input"] as? [String: Any]
        let pid = parseAgentPID(from: environment, key: "ZENTTY_KIMI_PID")

        switch hookEventName {
        case "SessionStart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd))
            return payloads

        case "UserPromptSubmit":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "Stop":
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd)]

        case "SessionEnd":
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
                pidPayload(target: target, toolName: toolName, pid: nil, event: .clear, sessionID: sessionID),
            ]

        case "Notification":
            guard notificationType?.caseInsensitiveCompare("permission_prompt") == .orderedSame else {
                return []
            }
            let message = AgentInteractionClassifier.trimmed(
                JSONKeyAccess.firstString(in: jsonObject, keys: ["title", "body", "message", "text"])
            ) ?? "Kimi needs your approval"
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
                agentWorkingDirectory: cwd
            )]

        case "PreToolUse":
            if payloadToolName == "AskUserQuestion" {
                let question = kimiQuestionText(from: toolInput) ?? "Kimi is waiting for your input"
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: question,
                    lifecycleEvent: .update,
                    interactionKind: .question,
                    confidence: .explicit,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                )]
            }

            if kimiToolRequiresApproval(payloadToolName) {
                let message = kimiApprovalText(toolName: payloadToolName, toolInput: toolInput)
                    ?? "Kimi needs your approval"
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
                    agentWorkingDirectory: cwd
                )]
            }
            return []

        case "PostToolUse":
            guard payloadToolName == "AskUserQuestion" || kimiToolRequiresApproval(payloadToolName) else {
                return []
            }
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
        default:
            return []
        }
    }

    private static func kimiQuestionText(from toolInput: [String: Any]?) -> String? {
        guard let toolInput else {
            return nil
        }
        return JSONKeyAccess.firstString(in: toolInput, keys: ["question", "prompt", "message", "title"])
    }

    private static func kimiToolRequiresApproval(_ toolName: String?) -> Bool {
        guard let normalized = AgentInteractionClassifier.trimmed(toolName)?.lowercased() else {
            return false
        }

        return [
            "shell",
            "writefile",
            "strreplacefile",
        ].contains(normalized)
    }

    private static func kimiApprovalText(toolName: String?, toolInput: [String: Any]?) -> String? {
        guard let normalized = AgentInteractionClassifier.trimmed(toolName)?.lowercased() else {
            return nil
        }

        switch normalized {
        case "strreplacefile":
            if let path = JSONKeyAccess.firstString(in: toolInput ?? [:], keys: ["path", "file_path", "filePath"]) {
                return "StrReplaceFile is requesting approval to edit file: \(path)"
            }
            return "StrReplaceFile is requesting approval to edit a file"
        case "writefile":
            if let path = JSONKeyAccess.firstString(in: toolInput ?? [:], keys: ["path", "file_path", "filePath"]) {
                return "WriteFile is requesting approval to write file: \(path)"
            }
            return "WriteFile is requesting approval to write a file"
        case "shell":
            if let command = JSONKeyAccess.firstString(in: toolInput ?? [:], keys: ["command", "cmd"]) {
                return "Shell is requesting approval to run command: \(command)"
            }
            return "Shell is requesting approval to run a command"
        default:
            return nil
        }
    }
}
