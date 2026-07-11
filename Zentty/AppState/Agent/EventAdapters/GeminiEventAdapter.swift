import Foundation

// MARK: - Gemini Adapter

extension AgentEventBridge {
    static func geminiAdapter(
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
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let notificationType = JSONKeyAccess.firstString(in: jsonObject, keys: ["notification_type", "notificationType"])
        let message = geminiNotificationMessage(from: jsonObject)
        let pid = parseAgentPID(from: environment, key: "ZENTTY_GEMINI_PID")
        let toolName = AgentTool.gemini.displayName

        switch hookEventName {
        case "SessionStart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd))
            return payloads

        case "BeforeAgent", "BeforeTool":
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "AfterAgent":
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
            guard notificationType?.caseInsensitiveCompare("ToolPermission") == .orderedSame else {
                return []
            }
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: message ?? "Gemini needs your approval",
                lifecycleEvent: .update,
                interactionKind: .approval,
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

    private static func geminiNotificationMessage(from jsonObject: [String: Any]) -> String? {
        let summary = AgentInteractionClassifier.trimmed(
            JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
        )

        guard let details = jsonObject["details"] else {
            return summary
        }

        if let summary, AgentInteractionClassifier.isGenericApprovalMessage(summary) == false {
            return summary
        }

        if let derived = geminiPermissionDetailsText(from: details) {
            return derived
        }

        return summary
    }

    private static func geminiPermissionDetailsText(from details: Any) -> String? {
        guard let details = details as? [String: Any] else {
            return AgentInteractionClassifier.trimmed(details as? String)
        }

        let tool = JSONKeyAccess.firstString(in: details, keys: ["tool_name", "toolName", "tool", "name"])
        let path = JSONKeyAccess.firstString(in: details, keys: ["file_path", "filePath", "path"])

        switch (AgentInteractionClassifier.trimmed(tool), AgentInteractionClassifier.trimmed(path)) {
        case let (tool?, path?):
            return "Allow \(tool) on \(path)?"
        case let (tool?, nil):
            return "Allow \(tool)?"
        case let (nil, path?):
            return "Allow access to \(path)?"
        case (nil, nil):
            return nil
        }
    }
}
