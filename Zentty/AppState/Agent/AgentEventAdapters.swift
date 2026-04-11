import Foundation

// MARK: - Gemini Adapter

extension AgentEventBridge {
    static func geminiAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let notificationType = firstString(in: jsonObject, keys: ["notification_type", "notificationType"])
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
            firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
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

        let tool = firstString(in: details, keys: ["tool_name", "toolName", "tool", "name"])
        let path = firstString(in: details, keys: ["file_path", "filePath", "path"])

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

// MARK: - Codex Adapter

extension AgentEventBridge {
    static func codexAdapter(
        data: Data,
        defaultEventName: String?,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let hookEventName = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? codexMappedEvent(defaultEventName)

        guard let hookEventName else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_CODEX_PID")
        let toolName = AgentTool.codex.displayName

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
        default:
            return []
        }
    }

    private static func codexMappedEvent(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "session-start": return "SessionStart"
        case "prompt-submit": return "UserPromptSubmit"
        case "stop": return "Stop"
        default: return nil
        }
    }

    static func codexNotifyAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let payloadType = firstString(in: jsonObject, keys: ["type", "event_type", "eventType"]) ?? ""
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let target = try currentTarget(from: environment)
        let toolName = AgentTool.codex.displayName

        if payloadType == "agent-turn-complete" {
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: toolName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )]
        }

        var message = firstString(in: jsonObject, keys: [
            "title",
            "message",
            "body",
            "text",
            "prompt",
            "description",
            "last_assistant_message",
            "lastAssistantMessage",
        ])

        if message == nil {
            if payloadType.localizedCaseInsensitiveContains("permission") {
                message = "Codex needs your approval"
            } else if payloadType.localizedCaseInsensitiveContains("question") {
                message = "Codex is waiting for your input"
            }
        }

        guard let normalizedMessage = AgentInteractionClassifier.trimmed(message),
              let interactionKind = codexNotifyInteractionKind(message: normalizedMessage, payloadType: payloadType) else {
            return []
        }

        return [AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: .needsInput,
            origin: .explicitAPI,
            toolName: toolName,
            text: normalizedMessage,
            lifecycleEvent: .update,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )]
    }

    private static func codexNotifyInteractionKind(
        message: String,
        payloadType: String
    ) -> PaneAgentInteractionKind? {
        let normalized = message.lowercased()
        let normalizedPayloadType = payloadType.lowercased()

        if normalized.contains("log in") || normalized.contains("login") || normalized.contains("sign in") || normalized.contains("sign-in") {
            return .auth
        }
        if normalizedPayloadType.contains("permission") {
            return .approval
        }
        if [
            "plan-mode-prompt",
            "plan mode prompt",
            "approval requested",
            "approval-requested",
            "approval",
            "permission",
            "approve",
            "allow ",
            "grant access",
            "wants to edit",
        ].contains(where: normalized.contains) {
            return .approval
        }
        if normalizedPayloadType.contains("question") || normalized.contains("?") {
            return codexNotifyContainsDecisionOptions(message) ? .decision : .question
        }
        if [
            "waiting for your input",
            "waiting for input",
            "needs your input",
            "needs input",
            "press enter",
        ].contains(where: normalized.contains) {
            return .genericInput
        }
        return nil
    }

    private static func codexNotifyContainsDecisionOptions(_ message: String) -> Bool {
        if message.contains("[") && message.contains("]") {
            return true
        }
        for line in message.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let components = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2, Int(components[0]) != nil, !components[1].trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
        }
        return false
    }
}

// MARK: - Copilot Adapter

extension AgentEventBridge {
    static func copilotAdapter(
        data: Data,
        defaultEventName: String?,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let rawEvent = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? copilotMappedEvent(defaultEventName)
            ?? defaultEventName

        guard let rawEvent, let event = copilotParseEvent(rawEvent) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let cwd = firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"])
        let toolName = AgentTool.copilot.displayName

        switch event {
        case .sessionStart:
            var payloads: [AgentStatusPayload] = []
            if let pid = parseAgentPID(from: environment, key: "ZENTTY_COPILOT_PID") {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: nil))
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
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            ))
            return payloads

        case .userPromptSubmitted:
            return []

        case .preToolUse:
            let toolArg = firstString(in: jsonObject, keys: ["toolName", "tool_name"])
            guard copilotIsUserQuestionTool(toolArg) else {
                return []
            }
            let toolArgs = firstString(in: jsonObject, keys: ["toolArgs", "tool_args"])
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
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case .postToolUse:
            let toolArg = firstString(in: jsonObject, keys: ["toolName", "tool_name"])
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
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case .errorOccurred:
            return []

        case .sessionEnd:
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: nil,
                origin: .explicitHook,
                toolName: toolName,
                text: nil,
                lifecycleEvent: .update,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]
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
        return firstString(in: object, keys: ["question", "prompt", "message", "title"])
    }
}

// MARK: - Claude Adapter

extension AgentEventBridge {
    static func claudeAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let input = try claudeParseInput(data)
        let sessionStore = ClaudeHookSessionStore()
        return try claudeMakePayloads(from: input, environment: environment, sessionStore: sessionStore)
    }
}

// MARK: - Claude Adapter Internals

struct ClaudeAdapterInput {
    let hookEventName: String
    let sessionID: String?
    let message: String?
    let notificationType: String?
    let cwd: String?
    let toolName: String?
    let toolInput: [String: Any]
    let taskID: String?
    let taskSubject: String?
}

extension AgentEventBridge {

    static func claudeParseInput(_ data: Data) throws -> ClaudeAdapterInput {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = firstString(in: json, keys: ["hook_event_name"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return ClaudeAdapterInput(
            hookEventName: hookEventName,
            sessionID: firstString(in: json, keys: ["session_id", "sessionId"]),
            message: firstString(in: json, keys: ["message", "body", "text", "prompt", "error", "description"]),
            notificationType: firstString(in: json, keys: ["notification_type", "notificationType"]),
            cwd: firstString(in: json, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]),
            toolName: firstString(in: json, keys: ["tool_name", "toolName"]),
            toolInput: (json["tool_input"] as? [String: Any]) ?? [:],
            taskID: firstString(in: json, keys: ["task_id", "taskId"]),
            taskSubject: firstString(in: json, keys: ["task", "task_subject", "taskSubject", "title"])
        )
    }

    static func claudeMakePayloads(
        from input: ClaudeAdapterInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> [AgentStatusPayload] {
        let toolName = AgentTool.claudeCode.displayName

        switch input.hookEventName {
        case "SessionStart":
            let target = try currentTarget(from: environment)
            let pid = parseAgentPID(from: environment, key: "ZENTTY_CLAUDE_PID")
            if let sessionID = input.sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: input.cwd,
                    pid: pid
                )
            }
            guard let pid else { return [] }
            return [pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: input.sessionID)]

        case "Notification":
            if input.notificationType == "idle_prompt" {
                let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
                return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID)]
            }
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let sessionRecord = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let originalMessage = AgentInteractionClassifier.trimmed(input.message)
            let hasExplicitStructuredInteraction = sessionRecord?.structuredInteractionKind?.requiresHumanAttention == true
            let isGenericMessage = AgentInteractionClassifier.isGenericNeedsInputMessage(originalMessage)
            let requiresAttention = AgentInteractionClassifier.requiresHumanInput(message: originalMessage)

            guard requiresAttention || (hasExplicitStructuredInteraction && isGenericMessage) else { return [] }

            if let sessionID = input.sessionID, let originalMessage {
                try sessionStore.recordNotificationText(sessionID: sessionID, text: originalMessage)
            }

            if let structuredKind = sessionRecord?.structuredInteractionKind,
               let structuredConfidence = sessionRecord?.structuredInteractionConfidence ?? sessionRecord.map({ _ in AgentSignalConfidence.explicit }),
               structuredKind.requiresHumanAttention {
                let message: String
                if let originalMessage,
                   claudeShouldReplaceStructuredInteractionText(with: originalMessage, structuredKind: structuredKind) {
                    message = originalMessage
                } else {
                    message = sessionRecord?.structuredInteractionText
                        ?? AgentInteractionClassifier.preferredWaitingMessage(existing: sessionRecord?.lastNotificationText, candidate: originalMessage)
                        ?? "Claude is waiting for your input"
                }
                return [claudeLifecyclePayload(target: target, state: .needsInput, text: message, interactionKind: structuredKind, confidence: structuredConfidence, sessionID: input.sessionID)]
            }

            let message: String
            if let originalMessage, !AgentInteractionClassifier.isGenericNeedsInputMessage(originalMessage) {
                message = originalMessage
            } else {
                message = AgentInteractionClassifier.preferredWaitingMessage(existing: sessionRecord?.lastNotificationText, candidate: originalMessage)
                    ?? "Claude is waiting for your input"
            }
            return [claudeLifecyclePayload(target: target, state: .needsInput, text: message, interactionKind: .genericInput, confidence: .strong, sessionID: input.sessionID)]

        case "PermissionRequest":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let interaction = claudeDescribePermissionRequest(input: input, existing: existing)
            let message = claudePreferredStructuredInteractionText(
                existingText: existing?.structuredInteractionText,
                existingKind: existing?.structuredInteractionKind,
                candidateText: interaction.text,
                candidateKind: interaction.interactionKind
            )
            if let sessionID = input.sessionID {
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    windowID: existing?.windowID ?? target.windowID,
                    worklaneID: existing?.worklaneID ?? target.worklaneID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    text: message,
                    kind: interaction.interactionKind,
                    confidence: .explicit
                )
            }
            return [claudeLifecyclePayload(target: target, state: .needsInput, text: message, interactionKind: interaction.interactionKind, confidence: .explicit, sessionID: input.sessionID)]

        case "PreToolUse":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if input.toolName == "AskUserQuestion",
               let sessionID = input.sessionID,
               let prompt = claudeDescribeAskUserQuestion(toolInput: input.toolInput) {
                let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
                let message = claudePreferredStructuredInteractionText(
                    existingText: existing?.structuredInteractionText,
                    existingKind: existing?.structuredInteractionKind,
                    candidateText: prompt.text,
                    candidateKind: prompt.interactionKind
                )
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    windowID: existing?.windowID ?? target.windowID,
                    worklaneID: existing?.worklaneID ?? target.worklaneID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    text: message,
                    kind: prompt.interactionKind,
                    confidence: .explicit
                )
                return [claudeLifecyclePayload(target: target, state: .needsInput, text: message, interactionKind: prompt.interactionKind, confidence: .explicit, sessionID: input.sessionID)]
            }
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let preToolExisting = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? preToolExisting?.cwd,
                interactionKind: .none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID)
            )]

        case "UserPromptSubmit", "SubagentStart":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let promptExisting = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? promptExisting?.cwd,
                interactionKind: .none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID)
            )]

        case "TaskCreated":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            guard let sessionID = input.sessionID, let taskID = input.taskID else { return [] }
            let taskProgress = try sessionStore.updateTask(sessionID: sessionID, taskID: taskID, isCompleted: false)
            return [claudeLifecyclePayload(target: target, state: .running, cwd: input.cwd, interactionKind: .none, confidence: .explicit, sessionID: sessionID, taskProgress: taskProgress)]

        case "TaskCompleted":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            guard let sessionID = input.sessionID, let taskID = input.taskID else { return [] }
            let taskProgress = try sessionStore.updateTask(sessionID: sessionID, taskID: taskID, isCompleted: true)
            return [claudeLifecyclePayload(target: target, state: .running, cwd: input.cwd, interactionKind: .none, confidence: .explicit, sessionID: sessionID, taskProgress: taskProgress)]

        case "Stop":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID)]

        case "SubagentStop":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID)]

        case "SessionEnd":
            let current = currentTargetIfAvailable(from: environment)
            let record = try sessionStore.consume(
                sessionID: input.sessionID,
                fallbackWindowID: current?.windowID,
                fallbackWorklaneID: current?.worklaneID,
                fallbackPaneID: current?.paneID
            )
            guard let record else { return [] }
            let target = (record.windowID, record.worklaneID, record.paneID)
            return [
                AgentStatusPayload(
                    windowID: target.0, worklaneID: target.1, paneID: target.2,
                    state: nil, origin: .explicitHook, toolName: toolName, text: nil,
                    sessionID: record.sessionID, artifactKind: nil, artifactLabel: nil, artifactURL: nil
                ),
                pidPayload(target: target, toolName: toolName, pid: nil, event: .clear, sessionID: record.sessionID),
            ]

        default:
            return []
        }
    }

    // MARK: - Claude Helpers

    static func claudeResolvedTarget(
        for input: ClaudeAdapterInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        if let sessionID = input.sessionID,
           let record = try sessionStore.lookup(sessionID: sessionID) {
            return (record.windowID, record.worklaneID, record.paneID)
        }
        return try currentTarget(from: environment)
    }

    static func claudeLookupRecord(
        for input: ClaudeAdapterInput,
        sessionStore: ClaudeHookSessionStore
    ) throws -> ClaudeHookSessionRecord? {
        guard let sessionID = input.sessionID else { return nil }
        return try sessionStore.lookup(sessionID: sessionID)
    }

    static func claudeDescribePermissionRequest(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> (text: String, interactionKind: PaneAgentInteractionKind) {
        if input.toolName == "AskUserQuestion" {
            if let prompt = claudeDescribeAskUserQuestion(toolInput: input.toolInput) {
                return prompt
            }
            if let existingText = existing?.structuredInteractionText,
               existing?.structuredInteractionKind == .decision {
                return (existingText, .decision)
            }
            return ("Claude is waiting for your decision", .decision)
        }
        return (
            AgentInteractionClassifier.trimmed(input.message) ?? "Claude needs your approval",
            .approval
        )
    }

    static func claudeDescribeAskUserQuestion(toolInput: [String: Any]) -> (text: String, interactionKind: PaneAgentInteractionKind)? {
        guard let questions = toolInput["questions"] as? [[String: Any]],
              let first = questions.first else {
            return nil
        }
        var lines: [String] = []
        if let question = first["question"] as? String, !question.isEmpty {
            lines.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            lines.append(header)
        }
        let options = first["options"] as? [[String: Any]]
        if let options {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                lines.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }
        guard !lines.isEmpty else { return nil }
        return (text: lines.joined(separator: "\n"), interactionKind: .decision)
    }

    static func claudePreferredStructuredInteractionText(
        existingText: String?,
        existingKind: PaneAgentInteractionKind?,
        candidateText: String,
        candidateKind: PaneAgentInteractionKind
    ) -> String {
        guard existingKind == candidateKind else { return candidateText }
        return AgentInteractionClassifier.preferredWaitingMessage(existing: existingText, candidate: candidateText) ?? candidateText
    }

    static func claudeShouldReplaceStructuredInteractionText(
        with notificationText: String,
        structuredKind: PaneAgentInteractionKind
    ) -> Bool {
        if AgentInteractionClassifier.isGenericNeedsInputMessage(notificationText)
            || AgentInteractionClassifier.isGenericApprovalMessage(notificationText) {
            return false
        }
        switch structuredKind {
        case .approval, .auth, .genericInput:
            return AgentInteractionClassifier.requiresHumanInput(message: notificationText)
        case .question, .decision, .none:
            return false
        }
    }

    static func claudeLifecyclePayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        state: PaneAgentState?,
        text: String? = nil,
        cwd: String? = nil,
        lifecycleEvent: AgentLifecycleEvent? = .update,
        interactionKind: PaneAgentInteractionKind? = nil,
        confidence: AgentSignalConfidence? = nil,
        sessionID: String? = nil,
        taskProgress: PaneAgentTaskProgress? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.claudeCode.displayName,
            text: text,
            lifecycleEvent: lifecycleEvent,
            interactionKind: interactionKind,
            confidence: confidence,
            sessionID: sessionID,
            taskProgress: taskProgress,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }
}

// MARK: - Shared Adapter Helpers

extension AgentEventBridge {
    static func currentTargetIfAvailable(
        from environment: [String: String]
    ) -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (environment["ZENTTY_WINDOW_ID"].map(WindowID.init), WorklaneID(worklaneID), PaneID(paneID))
    }

    static func parseAgentPID(from environment: [String: String], key: String) -> Int32? {
        guard let rawPID = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    static func lifecyclePayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        toolName: String,
        state: PaneAgentState,
        lifecycleEvent: AgentLifecycleEvent = .update,
        sessionID: String? = nil,
        cwd: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: state,
            origin: .explicitHook,
            toolName: toolName,
            text: nil,
            lifecycleEvent: lifecycleEvent,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    static func pidPayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        toolName: String,
        pid: Int32?,
        event: AgentPIDSignalEvent,
        sessionID: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: event,
            origin: .explicitHook,
            toolName: toolName,
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}
