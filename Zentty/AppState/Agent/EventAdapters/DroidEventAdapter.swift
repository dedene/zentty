import Foundation
import os

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
}
