import Foundation

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

    static func smallHarnessAdapter(
        data: Data,
        defaultEventName: String?,
        environment: [String: String],
        taskStore: DroidTaskStore = DroidTaskStore.smallHarness()
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? defaultEventName

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
        let requestedToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_SMALL_HARNESS_PID")
        let toolName = AgentTool.smallHarness.displayName

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
            let interaction = smallHarnessPermissionRequestInteraction(toolName: requestedToolName)
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
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: cwd,
                agentTranscriptPath: transcriptPath
            )]

        case "PreToolUse":
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
                    taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: cwd,
                    agentTranscriptPath: transcriptPath
                )]
            }
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: taskProgress,
                transcriptPath: transcriptPath
            )]

        case "PostToolUse", "UserPromptSubmit":
            let taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: taskProgress,
                transcriptPath: transcriptPath
            )]

        case "PlanUpdated":
            let taskProgress: PaneAgentTaskProgress?
            if let planProgress = smallHarnessPlanProgress(from: jsonObject) {
                taskProgress = planProgress
            } else {
                taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            }
            if let progress = taskProgress, let sessionID {
                _ = try taskStore.updateProgress(
                    sessionID: sessionID,
                    doneCount: progress.doneCount,
                    totalCount: progress.totalCount
                )
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: taskProgress,
                transcriptPath: transcriptPath
            )]

        case "SubagentStart":
            let taskProgress: PaneAgentTaskProgress?
            if let sessionID, let createdProgress = try taskStore.taskCreated(sessionID: sessionID) {
                taskProgress = createdProgress
            } else {
                taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: taskProgress,
                transcriptPath: transcriptPath
            )]

        case "SubagentStop":
            let taskProgress: PaneAgentTaskProgress?
            if let sessionID, let completedProgress = try taskStore.taskCompleted(sessionID: sessionID) {
                taskProgress = completedProgress
            } else {
                taskProgress = try taskStore.taskProgress(sessionID: sessionID)
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: taskProgress,
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
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
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
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
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
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                transcriptPath: transcriptPath
            )]

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
            return []
        }
    }

    private static func smallHarnessPermissionRequestInteraction(toolName: String?) -> (
        text: String,
        kind: PaneAgentInteractionKind
    ) {
        if codexPermissionRequestIsUserInput(toolName) {
            return ("Small Harness needs your input", .genericInput)
        }

        return ("Small Harness needs your approval", .approval)
    }

    private static func smallHarnessPlanProgress(from jsonObject: [String: Any]) -> PaneAgentTaskProgress? {
        guard let progress = jsonObject["progress"] as? [String: Any],
              let done = JSONKeyAccess.firstInt(in: progress, keys: ["done", "doneCount"]),
              let total = JSONKeyAccess.firstInt(in: progress, keys: ["total", "totalCount"]) else {
            return nil
        }

        return PaneAgentTaskProgress(doneCount: done, totalCount: total)
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
}
