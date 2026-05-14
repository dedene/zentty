import Foundation
import os

private let cursorAdapterLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CursorAdapter")
private let droidAdapterLogger = Logger(subsystem: "be.zenjoy.zentty", category: "DroidAdapter")

// MARK: - Droid Adapter

extension AgentEventBridge {
    static func droidAdapter(
        data: Data,
        environment: [String: String],
        taskStore: DroidTaskStore = DroidTaskStore()
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.droid.displayName
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let message = firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
        let hookToolName = firstString(in: jsonObject, keys: ["tool_name", "toolName"])
        let permissionMode = firstString(in: jsonObject, keys: ["permission_mode", "permissionMode"])
        let toolInput = (jsonObject["tool_input"] as? [String: Any])
            ?? (jsonObject["toolInput"] as? [String: Any])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_DROID_PID")

        switch hookEventName {
        case "SessionStart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(target: target, toolName: toolName, state: .starting, sessionID: sessionID, cwd: cwd))
            return payloads

        case "PreToolUse":
            if hookToolName == "TodoWrite",
               let sessionID,
               let todoProgress = droidTodoProgress(toolInput: toolInput) {
                let taskProgress = try taskStore.updateProgress(
                    sessionID: sessionID,
                    doneCount: todoProgress.doneCount,
                    totalCount: todoProgress.totalCount
                )
                return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]
            }
            if hookToolName == "Task", let sessionID {
                let taskProgress = try taskStore.taskCreated(sessionID: sessionID)
                return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]
            }
            if hookToolName == "AskUser" {
                let askUserInteraction = droidAskUserInteraction(toolInput: toolInput)
                let interactionText = askUserInteraction.text ?? message ?? "Droid needs your input"
                let interactionKind = askUserInteraction.kind
                    ?? AgentInteractionClassifier.interactionKind(forWaitingMessage: interactionText)
                    ?? .question
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: interactionText,
                    lifecycleEvent: .update,
                    interactionKind: interactionKind,
                    confidence: .explicit,
                    sessionID: sessionID,
                    taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                )]
            }
            if hookToolName == "ExitSpecMode" {
                let specText = droidSpecProposalText(toolInput: toolInput)
                    ?? message
                    ?? "Droid drafted a specification for your approval"
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: specText,
                    lifecycleEvent: .update,
                    interactionKind: .approval,
                    confidence: .explicit,
                    sessionID: sessionID,
                    taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                )]
            }
            if droidManualModeRequiresApproval(permissionMode: permissionMode, toolName: hookToolName) {
                let interactionText = droidApprovalText(toolName: hookToolName, toolInput: toolInput)
                return [AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: interactionText,
                    lifecycleEvent: .update,
                    interactionKind: .approval,
                    confidence: .explicit,
                    sessionID: sessionID,
                    taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd
                )]
            }
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]

        case "PostToolUse":
            if hookToolName == "ExitSpecMode" {
                return []
            }
            if hookToolName == "TodoWrite",
               let sessionID,
               let todoProgress = droidTodoProgress(toolInput: toolInput) {
                let taskProgress = try taskStore.updateProgress(
                    sessionID: sessionID,
                    doneCount: todoProgress.doneCount,
                    totalCount: todoProgress.totalCount
                )
                return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]
            }
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]

        case "UserPromptSubmit":
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]

        case "Notification":
            let interactionText = message ?? "Droid needs your input"
            let interactionKind: PaneAgentInteractionKind
            let normalized = interactionText.lowercased()
            if normalized.contains("permission") || normalized.contains("approval") || normalized.contains("approve") {
                interactionKind = .approval
            } else if normalized.contains("?") {
                interactionKind = .question
            } else {
                interactionKind = .genericInput
            }
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: interactionText,
                lifecycleEvent: .update,
                interactionKind: interactionKind,
                confidence: .explicit,
                sessionID: sessionID,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd
            )]

        case "SubagentStop":
            if let sessionID {
                let taskProgress = try taskStore.taskCompleted(sessionID: sessionID)
                return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]
            }
            return [lifecyclePayload(target: target, toolName: toolName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "Stop":
            if permissionMode?.caseInsensitiveCompare("spec") == .orderedSame {
                return []
            }
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(target: target, toolName: toolName, state: .idle, sessionID: sessionID, cwd: cwd, taskProgress: taskProgress)]

        case "SessionEnd":
            try taskStore.clearSession(sessionID: sessionID)
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

        default:
            droidAdapterLogger.debug("Unhandled droid hook event: \(hookEventName, privacy: .public)")
            return []
        }
    }

    private static func droidManualModeRequiresApproval(permissionMode: String?, toolName: String?) -> Bool {
        guard permissionMode?.caseInsensitiveCompare("off") == .orderedSame,
              let toolName else {
            return false
        }

        let approvalTools: Set<String> = [
            "Create",
            "Edit",
            "Execute",
            "MultiEdit",
            "NotebookEdit",
            "Write",
        ]
        return approvalTools.contains(toolName)
    }

    private static func droidAskUserInteraction(toolInput: [String: Any]?) -> (
        text: String?,
        kind: PaneAgentInteractionKind?
    ) {
        let text = firstString(in: toolInput, keys: ["question", "prompt", "message", "text"])
        let options = droidStringArray(in: toolInput, keys: ["options", "choices"])
        guard let text, !options.isEmpty else {
            return (text, nil)
        }

        return (([text] + options.map { "- \($0)" }).joined(separator: "\n"), .decision)
    }

    private static func droidApprovalText(toolName: String?, toolInput: [String: Any]?) -> String {
        let tool = toolName ?? "tool"
        if let command = firstString(in: toolInput, keys: ["command"]) {
            return "Allow \(tool): \(command)"
        }
        if let path = firstString(in: toolInput, keys: ["file_path", "filePath", "path"]) {
            return "Allow \(tool) on \(path)?"
        }
        return "Droid needs your permission to use \(tool)"
    }

    private static func droidSpecProposalText(toolInput: [String: Any]?) -> String? {
        guard let plan = firstString(in: toolInput, keys: ["plan", "spec", "proposal"]) else {
            return nil
        }
        let firstLine = plan
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else { return nil }
        return "Droid proposed a spec: \(firstLine)"
    }

    private static func droidStringArray(in object: [String: Any]?, keys: [String]) -> [String] {
        guard let object else { return [] }
        for key in keys {
            if let values = object[key] as? [String] {
                return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let values = object[key] as? [[String: Any]] {
                return values.compactMap { firstString(in: $0, keys: ["label", "text", "value", "name"]) }
            }
        }
        return []
    }

    private struct DroidTodoProgressSnapshot {
        let doneCount: Int
        let totalCount: Int
    }

    private static func droidTodoProgress(toolInput: [String: Any]?) -> DroidTodoProgressSnapshot? {
        guard let toolInput, let todos = toolInput["todos"] else {
            return nil
        }

        if let todoObjects = todos as? [[String: Any]] {
            return droidTodoProgress(todoObjects: todoObjects)
        }

        if let todoLines = todos as? [String] {
            return droidTodoProgress(todoText: todoLines.joined(separator: "\n"))
        }

        if let todoText = todos as? String {
            return droidTodoProgress(todoText: todoText)
        }

        return nil
    }

    private static func droidTodoProgress(todoObjects: [[String: Any]]) -> DroidTodoProgressSnapshot? {
        guard !todoObjects.isEmpty else {
            return DroidTodoProgressSnapshot(doneCount: 0, totalCount: 0)
        }

        let statuses = todoObjects.compactMap { todo in
            firstString(in: todo, keys: ["status", "state"])
        }
        guard !statuses.isEmpty else { return nil }

        let doneCount = statuses.filter { droidTodoStatusIsComplete($0) }.count
        return DroidTodoProgressSnapshot(doneCount: doneCount, totalCount: statuses.count)
    }

    private static func droidTodoProgress(todoText: String) -> DroidTodoProgressSnapshot? {
        var totalCount = 0
        var doneCount = 0
        var sawTodoLine = false

        for rawLine in todoText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty else { continue }
            sawTodoLine = true

            if line.contains("[completed]") || line.contains("[done]") {
                totalCount += 1
                doneCount += 1
            } else if line.contains("[in_progress]")
                || line.contains("[in-progress]")
                || line.contains("[pending]") {
                totalCount += 1
            } else if line.contains("[x]") {
                totalCount += 1
                doneCount += 1
            } else if line.contains("[ ]") {
                totalCount += 1
            }
        }

        guard totalCount > 0 || !sawTodoLine else {
            return nil
        }
        return DroidTodoProgressSnapshot(doneCount: doneCount, totalCount: totalCount)
    }

    private static func droidTodoStatusIsComplete(_ status: String) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done":
            return true
        default:
            return false
        }
    }
}

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

// MARK: - Kimi Adapter

extension AgentEventBridge {
    static func kimiAdapter(
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
        let toolName = AgentTool.kimi.displayName
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let notificationType = firstString(in: jsonObject, keys: ["notification_type", "notificationType"])
        let payloadToolName = firstString(in: jsonObject, keys: ["tool_name", "toolName"])
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
                firstString(in: jsonObject, keys: ["title", "body", "message", "text"])
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
        return firstString(in: toolInput, keys: ["question", "prompt", "message", "title"])
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
            if let path = firstString(in: toolInput ?? [:], keys: ["path", "file_path", "filePath"]) {
                return "StrReplaceFile is requesting approval to edit file: \(path)"
            }
            return "StrReplaceFile is requesting approval to edit a file"
        case "writefile":
            if let path = firstString(in: toolInput ?? [:], keys: ["path", "file_path", "filePath"]) {
                return "WriteFile is requesting approval to write file: \(path)"
            }
            return "WriteFile is requesting approval to write a file"
        case "shell":
            if let command = firstString(in: toolInput ?? [:], keys: ["command", "cmd"]) {
                return "Shell is requesting approval to run command: \(command)"
            }
            return "Shell is requesting approval to run a command"
        default:
            return nil
        }
    }
}

// MARK: - Cursor Adapter

extension AgentEventBridge {
    static func cursorAdapter(
        data: Data,
        environment: [String: String],
        taskStore: CursorTaskStore = CursorTaskStore()
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.cursor.displayName
        let sessionID = firstString(in: jsonObject, keys: ["conversation_id", "conversationId"])
        let cwd = cursorWorkspaceRoot(from: jsonObject)
        let hookToolName = firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
        let toolInput = (jsonObject["tool_input"] as? [String: Any])
            ?? (jsonObject["toolInput"] as? [String: Any])
            ?? (jsonObject["input"] as? [String: Any])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_CURSOR_PID")

        let normalized = hookEventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "sessionstart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .starting,
                sessionID: sessionID,
                cwd: cwd
            ))
            return payloads

        case "beforesubmitprompt":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd
            )]

        case "sessionend":
            try taskStore.clearSession(sessionID: sessionID)
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

        case "stop":
            let status = firstString(in: jsonObject, keys: ["status"])?.lowercased()
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            switch status {
            case "error":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .unresolvedStop,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress
                )]
            case "aborted":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .stopCandidate,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress
                )]
            case "completed", nil:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress
                )]
            default:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress
                )]
            }

        case "subagentstart", "subagentstop":
            return []

        case "pretooluse", "posttooluse":
            if cursorToolNameIsTodoWrite(hookToolName),
               let sessionID,
               let todoProgress = droidTodoProgress(toolInput: toolInput) {
                let taskProgress = try taskStore.updateProgress(
                    sessionID: sessionID,
                    doneCount: todoProgress.doneCount,
                    totalCount: todoProgress.totalCount
                )
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress
                )]
            }
            guard environment["ZENTTY_CURSOR_VERBOSE_HOOKS"] == "1" else {
                return []
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID)
            )]

        case "posttoolusefailure", "beforeshellexecution", "aftershellexecution":
            guard environment["ZENTTY_CURSOR_VERBOSE_HOOKS"] == "1" else {
                return []
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID)
            )]

        default:
            cursorAdapterLogger.debug("Unhandled cursor hook event: \(normalized, privacy: .public)")
            return []
        }
    }

    private static func cursorWorkspaceRoot(from jsonObject: [String: Any]) -> String? {
        let roots = (jsonObject["workspace_roots"] as? [String]) ?? (jsonObject["workspaceRoots"] as? [String])
        guard let first = roots?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            return nil
        }
        return first
    }

    private static func cursorToolNameIsTodoWrite(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("TodoWrite") == .orderedSame
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
        let transcriptPath = firstString(in: jsonObject, keys: ["transcript_path", "transcriptPath"])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_CODEX_PID")
        let toolName = AgentTool.codex.displayName

        switch hookEventName {
        case "SessionStart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .starting,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            ))
            return payloads
        case "PermissionRequest":
            let requestedToolName = firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
            let interaction = codexPermissionRequestInteraction(toolName: requestedToolName)
            let prompt = codexPermissionRequestIsUserInput(requestedToolName)
                ? codexQuestionPrompt(from: jsonObject)
                : nil
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: prompt?.text ?? interaction.text,
                lifecycleEvent: .update,
                interactionKind: prompt?.interactionKind ?? interaction.kind,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: transcriptPath
            )]
        case "PreToolUse", "PostToolUse":
            if hookEventName == "PreToolUse" {
                let requestedToolName = firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
                if codexPermissionRequestIsUserInput(requestedToolName),
                   let prompt = codexQuestionPrompt(from: jsonObject) {
                    return [AgentStatusPayload(
                        windowID: target.windowID,
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        state: .needsInput,
                        origin: .explicitHook,
                        toolName: toolName,
                        text: prompt.text,
                        lifecycleEvent: .update,
                        interactionKind: prompt.interactionKind,
                        confidence: .explicit,
                        sessionID: sessionID,
                        artifactKind: nil,
                        artifactLabel: nil,
                        artifactURL: nil,
                        agentWorkingDirectory: cwd,
                        agentTranscriptPath: transcriptPath
                    )]
                }
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )]
        case "UserPromptSubmit":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )]
        case "Stop":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .idle,
                lifecycleEvent: .turnComplete,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )]
        default:
            return []
        }
    }

    private static func codexMappedEvent(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "session-start": return "SessionStart"
        case "pre-tool-use": return "PreToolUse"
        case "permission-request": return "PermissionRequest"
        case "post-tool-use": return "PostToolUse"
        case "prompt-submit": return "UserPromptSubmit"
        case "stop": return "Stop"
        default: return nil
        }
    }

    private static func codexPermissionRequestInteraction(toolName: String?) -> (
        text: String,
        kind: PaneAgentInteractionKind
    ) {
        if codexPermissionRequestIsUserInput(toolName) {
            return ("Codex needs your input", .genericInput)
        }

        return ("Codex needs your approval", .approval)
    }

    private static func codexPermissionRequestIsUserInput(_ toolName: String?) -> Bool {
        guard let toolName = AgentInteractionClassifier.trimmed(toolName) else {
            return false
        }

        let normalized = toolName.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("askuserquestion")
            || normalized.contains("askuser")
            || normalized.contains("requestuserinput")
    }

    private static func codexQuestionPrompt(from jsonObject: [String: Any]) -> CodexTranscriptQuestion? {
        if let toolInput = jsonObject["tool_input"] as? [String: Any] {
            return CodexTranscriptQuestionExtractor.question(fromToolInput: toolInput)
        }
        if let toolInput = jsonObject["toolInput"] as? [String: Any] {
            return CodexTranscriptQuestionExtractor.question(fromToolInput: toolInput)
        }
        for key in ["tool_args", "toolArgs", "arguments"] {
            guard let string = firstString(in: jsonObject, keys: [key]),
                  let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let question = CodexTranscriptQuestionExtractor.question(fromToolInput: object) else {
                continue
            }
            return question
        }
        return nil
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
                lifecycleEvent: .turnComplete,
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

        if codexNotifyIsAutoApprovalSuccessMessage(normalizedMessage) {
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

    private static func codexNotifyIsAutoApprovalSuccessMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let compact = normalized.filter { $0.isLetter || $0.isNumber }

        let mentionsAutoApprovalSuccess = [
            "automaticapprovalreviewapproved",
            "autoreviewerapproved",
            "autoreviewreturned",
        ].contains(where: compact.contains)

        guard mentionsAutoApprovalSuccess else {
            return false
        }

        return compact.contains("approved")
            || compact.contains("allowdecision")
            || compact.contains("allowed")
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
            return codexNotifyContainsDecisionOptions(message) ? .decision : .genericInput
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
        let sessionID = firstString(in: jsonObject, keys: ["session_id", "sessionId", "sessionID"])
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
                sessionID: sessionID,
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
    let transcriptPath: String?
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
            transcriptPath: firstString(in: json, keys: ["transcript_path", "transcriptPath"]),
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
                    transcriptPath: input.transcriptPath,
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
            // Clear any cached structured interaction (PreToolUse(AskUserQuestion),
            // PermissionRequest) so a late Notification arriving after Stop
            // can't re-enter the structured-cache branch and flip the pane
            // back to needsInput.
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID)]

        case "SubagentStop":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
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
        cwd: String? = nil,
        taskProgress: PaneAgentTaskProgress? = nil,
        transcriptPath: String? = nil
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
            taskProgress: taskProgress,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd,
            agentTranscriptPath: transcriptPath
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
