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
        guard let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.droid.displayName
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
        let message = JSONKeyAccess.firstString(in: jsonObject, keys: ["message", "body", "text", "prompt", "description"])
        let hookToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName"])
        let permissionMode = JSONKeyAccess.firstString(in: jsonObject, keys: ["permission_mode", "permissionMode"])
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
        let text = JSONKeyAccess.firstString(in: toolInput, keys: ["question", "prompt", "message", "text"])
        let options = droidStringArray(in: toolInput, keys: ["options", "choices"])
        guard let text, !options.isEmpty else {
            return (text, nil)
        }

        return (([text] + options.map { "- \($0)" }).joined(separator: "\n"), .decision)
    }

    private static func droidApprovalText(toolName: String?, toolInput: [String: Any]?) -> String {
        let tool = toolName ?? "tool"
        if let command = JSONKeyAccess.firstString(in: toolInput, keys: ["command"]) {
            return "Allow \(tool): \(command)"
        }
        if let path = JSONKeyAccess.firstString(in: toolInput, keys: ["file_path", "filePath", "path"]) {
            return "Allow \(tool) on \(path)?"
        }
        return "Droid needs your permission to use \(tool)"
    }

    private static func droidSpecProposalText(toolInput: [String: Any]?) -> String? {
        guard let plan = JSONKeyAccess.firstString(in: toolInput, keys: ["plan", "spec", "proposal"]) else {
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
                return values.compactMap { JSONKeyAccess.firstString(in: $0, keys: ["label", "text", "value", "name"]) }
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
            JSONKeyAccess.firstString(in: todo, keys: ["status", "state"])
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

// MARK: - Cursor Adapter

extension AgentEventBridge {
    static func cursorAdapter(
        data: Data,
        environment: [String: String],
        taskStore: CursorTaskStore = CursorTaskStore()
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.cursor.displayName
        let sessionID = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["conversation_id", "conversationId", "session_id", "sessionId"]
        )
        let cwd = cursorWorkspaceRoot(from: jsonObject)
        let transcriptPath = JSONKeyAccess.firstString(in: jsonObject, keys: ["transcript_path", "transcriptPath"])
        let hookToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
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
                cwd: cwd,
                transcriptPath: transcriptPath
            ))
            return payloads

        case "beforesubmitprompt":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
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
            let status = JSONKeyAccess.firstString(in: jsonObject, keys: ["status"])?.lowercased()
            let taskProgress = try cursorTaskProgress(
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                taskStore: taskStore
            )
            switch status {
            case "error":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .unresolvedStop,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            case "aborted":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .stopCandidate,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            case "completed", nil:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            default:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            }

        case "subagentstart", "subagentstop":
            return []

        case "pretooluse", "posttooluse":
            if cursorToolNameIsTodoWrite(hookToolName),
               let sessionID,
               let taskProgress = try cursorApplyTodoWrite(
                sessionID: sessionID,
                toolInput: toolInput,
                taskStore: taskStore
               ) {
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
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
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                transcriptPath: transcriptPath
            )]

        case "aftershellexecution":
            let taskProgress = try cursorTaskProgress(
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                taskStore: taskStore
            )
            return [
                lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    lifecycleEvent: .toolActivity,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                ),
                lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .stopCandidate,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                ),
            ]

        case "posttoolusefailure", "beforeshellexecution":
            guard environment["ZENTTY_CURSOR_VERBOSE_HOOKS"] == "1" else {
                return []
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                transcriptPath: transcriptPath
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

    private static func cursorTaskProgress(
        sessionID: String?,
        transcriptPath: String?,
        taskStore: CursorTaskStore
    ) throws -> PaneAgentTaskProgress? {
        if let sessionID,
           let transcriptPath,
           let updates = cursorTranscriptTodoUpdates(transcriptPath: transcriptPath, attempts: 5),
           !updates.isEmpty {
            var taskProgress: PaneAgentTaskProgress?
            for update in updates {
                taskProgress = try taskStore.applyTodoWrite(sessionID: sessionID, update: update)
            }
            return taskProgress
        }
        return try taskStore.taskProgress(sessionID: sessionID)
    }

    private static func cursorApplyTodoWrite(
        sessionID: String,
        toolInput: [String: Any]?,
        taskStore: CursorTaskStore
    ) throws -> PaneAgentTaskProgress? {
        if let update = cursorTodoWriteUpdate(toolInput: toolInput) {
            return try taskStore.applyTodoWrite(sessionID: sessionID, update: update)
        }
        guard let todoProgress = droidTodoProgress(toolInput: toolInput) else {
            return nil
        }
        return try taskStore.updateProgress(
            sessionID: sessionID,
            doneCount: todoProgress.doneCount,
            totalCount: todoProgress.totalCount
        )
    }

    private static func cursorTranscriptTodoUpdates(transcriptPath: String, attempts: Int = 1) -> [CursorTodoWriteUpdate]? {
        let attemptCount = max(attempts, 1)
        for attempt in 0..<attemptCount {
            if let updates = cursorTranscriptTodoUpdatesOnce(transcriptPath: transcriptPath), !updates.isEmpty {
                return updates
            }
            if attempt < attemptCount - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }

    private static func cursorTranscriptTodoUpdatesOnce(transcriptPath: String) -> [CursorTodoWriteUpdate]? {
        guard let text = cursorReadTextFileTail(path: transcriptPath, maxBytes: 256 * 1024) else {
            return nil
        }
        var updates: [CursorTodoWriteUpdate] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            updates.append(contentsOf: cursorTodoWriteUpdates(in: object, depth: 0))
        }
        return updates
    }

    private static func cursorTodoWriteUpdates(in object: [String: Any], depth: Int) -> [CursorTodoWriteUpdate] {
        guard depth < 6 else { return [] }

        if cursorToolNameIsTodoWrite(JSONKeyAccess.firstString(in: object, keys: ["name", "tool_name", "toolName", "tool"])) {
            let toolInput = (object["input"] as? [String: Any])
                ?? (object["tool_input"] as? [String: Any])
                ?? (object["toolInput"] as? [String: Any])
                ?? (object["todos"] == nil ? nil : object)
            if let update = cursorTodoWriteUpdate(toolInput: toolInput) {
                return [update]
            }
        }

        var updates: [CursorTodoWriteUpdate] = []
        for key in ["message", "tool_use", "toolUse", "tool_use_input", "input"] {
            if let nested = object[key] as? [String: Any] {
                updates.append(contentsOf: cursorTodoWriteUpdates(in: nested, depth: depth + 1))
            }
        }

        for key in ["content", "messages"] {
            guard let items = object[key] as? [Any] else { continue }
            for item in items {
                if let nested = item as? [String: Any] {
                    updates.append(contentsOf: cursorTodoWriteUpdates(in: nested, depth: depth + 1))
                }
            }
        }

        return updates
    }

    private static func cursorTodoWriteUpdate(toolInput: [String: Any]?) -> CursorTodoWriteUpdate? {
        guard let toolInput, let todoObjects = toolInput["todos"] as? [[String: Any]] else {
            return nil
        }

        let todos = todoObjects.compactMap { cursorTodoWriteTodo(from: $0) }
        guard !todos.isEmpty || todoObjects.isEmpty else {
            return nil
        }
        let merge = (toolInput["merge"] as? Bool) ?? false
        return CursorTodoWriteUpdate(merge: merge, todos: todos)
    }

    private static func cursorTodoWriteTodo(from object: [String: Any]) -> CursorTodoWriteTodo? {
        let id = JSONKeyAccess.firstString(in: object, keys: ["id"])
        let content = JSONKeyAccess.firstString(in: object, keys: ["content", "text", "title"])
        let status = JSONKeyAccess.firstString(in: object, keys: ["status", "state"]) ?? "pending"
        guard let key = id ?? content else {
            return nil
        }
        return CursorTodoWriteTodo(key: key, content: content, status: status)
    }

    private static func cursorReadTextFileTail(path: String, maxBytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            let fileSize = try handle.seekToEnd()
            let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            cursorAdapterLogger.debug("Failed to read cursor transcript tail: \(error.localizedDescription, privacy: .public)")
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
        let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? codexMappedEvent(defaultEventName)

        guard let hookEventName else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId"])
        let cwd = JSONKeyAccess.firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"])
        let transcriptPath = JSONKeyAccess.firstString(in: jsonObject, keys: ["transcript_path", "transcriptPath"])
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
            let requestedToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
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
                let requestedToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
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
        case "PreCompact":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                text: "Compacting",
                lifecycleEvent: .toolActivity,
                interactionKind: .none,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )]
        case "PostCompact":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .update,
                interactionKind: .none,
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
        case "pre-compact": return "PreCompact"
        case "post-compact": return "PostCompact"
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
            guard let string = JSONKeyAccess.firstString(in: jsonObject, keys: [key]),
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
        let payloadType = JSONKeyAccess.firstString(in: jsonObject, keys: ["type", "event_type", "eventType"]) ?? ""
        let sessionID = JSONKeyAccess.firstString(in: jsonObject, keys: ["session_id", "sessionId"])
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

        var message = JSONKeyAccess.firstString(in: jsonObject, keys: [
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

        guard let normalizedMessage = AgentInteractionClassifier.trimmed(message) else {
            return []
        }

        if AgentInteractionClassifier.isCodexAutoApprovalLifecycleMessage(normalizedMessage, payloadType: payloadType) {
            return []
        }

        guard let interactionKind = codexNotifyInteractionKind(message: normalizedMessage, payloadType: payloadType) else {
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
              let hookEventName = JSONKeyAccess.firstString(in: json, keys: ["hook_event_name"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return ClaudeAdapterInput(
            hookEventName: hookEventName,
            sessionID: JSONKeyAccess.firstString(in: json, keys: ["session_id", "sessionId"]),
            message: JSONKeyAccess.firstString(in: json, keys: ["message", "body", "text", "prompt", "error", "description"]),
            notificationType: JSONKeyAccess.firstString(in: json, keys: ["notification_type", "notificationType"]),
            cwd: JSONKeyAccess.firstString(in: json, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]),
            transcriptPath: JSONKeyAccess.firstString(in: json, keys: ["transcript_path", "transcriptPath"]),
            toolName: JSONKeyAccess.firstString(in: json, keys: ["tool_name", "toolName"]),
            toolInput: (json["tool_input"] as? [String: Any]) ?? [:],
            taskID: JSONKeyAccess.firstString(in: json, keys: ["task_id", "taskId"]),
            taskSubject: JSONKeyAccess.firstString(in: json, keys: ["task", "task_subject", "taskSubject", "title"])
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

        case "PreCompact":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            return [claudeLifecyclePayload(
                target: target, state: .running, text: "Compacting", cwd: input.cwd ?? existing?.cwd,
                interactionKind: .none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID)
            )]

        case "PostCompact":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? existing?.cwd,
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
        text: String? = nil,
        lifecycleEvent: AgentLifecycleEvent = .update,
        interactionKind: PaneAgentInteractionKind? = nil,
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
            text: text,
            lifecycleEvent: lifecycleEvent,
            interactionKind: interactionKind,
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

    // MARK: - Antigravity Adapter

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

    // MARK: - Hermes Agent Adapter

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

// MARK: - Vibe Adapter

extension AgentEventBridge {
    static func vibeAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])

        // Only emit status when the agent runs inside a known Zentty pane;
        // outside that context there is nothing to attribute events to.
        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        // Already-canonical Agent Status Protocol envelopes are forwarded
        // straight through the shared pipeline. The most important one is the
        // `session.start` the launch bootstrap pre-sends (Vibe has no
        // session-start hook of its own); without this passthrough that
        // envelope is rejected and no Vibe session is ever created. These
        // envelopes carry `version`/`event`, not a raw `hook_event_name`.
        if (jsonObject["version"] as? Int) == 1,
           let eventName = jsonObject["event"] as? String, !eventName.isEmpty {
            let input = try parseInput(data)
            return try makePayloads(from: input, environment: environment)
        }

        // Otherwise this is a raw Vibe hook payload. Translate it into canonical
        // envelopes and run each through the shared makePayloads pipeline. No
        // fallback is needed: every handled event yields at least one canonical
        // envelope, and unknown events are intentionally dropped.
        guard jsonObject["hook_event_name"] is String else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        let canonicalPayloads = VibeCanonicalReEmitter.canonicalPayloads(from: jsonObject)
        var payloads: [AgentStatusPayload] = []
        for canonicalPayload in canonicalPayloads {
            let input = try parseInput(try JSONSerialization.data(withJSONObject: canonicalPayload))
            payloads.append(contentsOf: try makePayloads(from: input, environment: environment))
        }
        return payloads
    }

}
