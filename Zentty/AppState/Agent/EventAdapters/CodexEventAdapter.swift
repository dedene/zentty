import Foundation

// MARK: - Codex Adapter

extension AgentEventBridge {
    static func codexAdapter(
        data: Data,
        defaultEventName: String?,
        environment: [String: String],
        subagentStore: AgentSubagentRegistryStore = AgentSubagentRegistryStore()
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
        let subagentKey = AgentSubagentRegistryStore.Key(tool: "codex", worklaneID: target.worklaneID, paneID: target.paneID)

        switch hookEventName {
        case "SubagentStart", "SubagentStop":
            // Sub-threads report their own thread id; attribute the update to
            // the parent session the pane already knows about.
            let rootSessionID = try subagentStore.rootSessionID(key: subagentKey) ?? sessionID
            let subagents: PaneAgentSubagentSummary
            if hookEventName == "SubagentStart" {
                subagents = try subagentStore.start(key: subagentKey, entry: codexSubagentEntry(from: jsonObject))
            } else {
                subagents = try subagentStore.stop(key: subagentKey, subagentID: codexSubagentID(from: jsonObject))
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                lifecycleEvent: .toolActivity,
                sessionID: rootSessionID,
                cwd: cwd,
                subagents: subagents,
                transcriptPath: transcriptPath
            )]
        case "SessionStart":
            try subagentStore.recordRootSession(key: subagentKey, sessionID: sessionID)
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
                try subagentStore.recordRootSession(key: subagentKey, sessionID: sessionID)
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
            return try attachSubagents(
                to: [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    lifecycleEvent: .toolActivity,
                    sessionID: sessionID,
                    cwd: cwd,
                    transcriptPath: transcriptPath
                )],
                key: subagentKey,
                subagentStore: subagentStore
            ) { entry in
                guard let info = AgentSubagentModelResolver.codexThreadInfo(rolloutPath: entry.transcriptPath),
                      info.model != nil else {
                    return nil
                }
                return entry.with(model: info.model, nickname: info.nickname)
            }
        case "UserPromptSubmit":
            try subagentStore.recordRootSession(key: subagentKey, sessionID: sessionID)
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
            // Only the parent's turn end retires the subagent set; a sub-thread
            // reporting its own Stop must not blank the badge mid-run.
            let rootSessionID = try subagentStore.rootSessionID(key: subagentKey)
            let subagents: PaneAgentSubagentSummary? = (rootSessionID == nil || rootSessionID == sessionID)
                ? try subagentStore.clear(key: subagentKey)
                : nil
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .idle,
                lifecycleEvent: .turnComplete,
                sessionID: sessionID,
                cwd: cwd,
                subagents: subagents,
                transcriptPath: transcriptPath
            )]
        default:
            return []
        }
    }

    // MARK: - Codex Subagents

    static func codexSubagentID(from jsonObject: [String: Any]) -> String? {
        if let path = JSONKeyAccess.firstString(in: jsonObject, keys: ["agent_transcript_path", "agentTranscriptPath"]) {
            return codexThreadID(fromRolloutPath: path) ?? path
        }
        return JSONKeyAccess.firstString(in: jsonObject, keys: ["agent_id", "agentId", "thread_id", "threadId", "turn_id", "turnId"])
    }

    /// `rollout-2026-09-05T12-52-37-01a07132-eb9a-7222-ad53-819ccda4db3c.jsonl` → the trailing UUID.
    static func codexThreadID(fromRolloutPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    static func codexSubagentEntry(from jsonObject: [String: Any]) -> PaneAgentSubagentEntry {
        let rolloutPath = JSONKeyAccess.firstString(in: jsonObject, keys: ["agent_transcript_path", "agentTranscriptPath"])
        let info = AgentSubagentModelResolver.codexThreadInfo(rolloutPath: rolloutPath)
        let agentType = JSONKeyAccess.firstString(in: jsonObject, keys: ["agent_type", "agentType", "agent_role", "agentRole"])
            ?? info?.role
        return PaneAgentSubagentEntry(
            id: codexSubagentID(from: jsonObject) ?? UUID().uuidString,
            agentType: agentType,
            model: info?.model ?? JSONKeyAccess.firstString(in: jsonObject, keys: ["model"]),
            nickname: JSONKeyAccess.firstString(in: jsonObject, keys: ["agent_nickname", "agentNickname"]) ?? info?.nickname,
            transcriptPath: rolloutPath
        )
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
        case "subagent-start": return "SubagentStart"
        case "subagent-stop": return "SubagentStop"
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

// MARK: - Adapter conformance

enum CodexEventAdapter: AgentEventAdapting {
    static let adapterName = "codex"
    static let suppressesErrors = false
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.codexAdapter(
            data: data,
            defaultEventName: positionalArguments.first,
            environment: environment
        )
    }
}

// MARK: - Adapter conformance

enum SmallHarnessEventAdapter: AgentEventAdapting {
    static let adapterName = "small-harness"
    static let suppressesErrors = false
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.smallHarnessAdapter(
            data: data,
            defaultEventName: positionalArguments.first,
            environment: environment
        )
    }
}
