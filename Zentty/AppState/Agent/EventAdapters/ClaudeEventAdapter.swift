import Foundation

// MARK: - Claude Adapter

extension AgentEventBridge {
    static func claudeAdapter(
        data: Data,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let input = try claudeParseInput(data)
        let sessionStore = ClaudeHookSessionStore()
        return try claudeMakePayloads(
            from: input,
            environment: environment,
            sessionStore: sessionStore,
            subagentStore: AgentSubagentRegistryStore()
        )
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
    let toolUseID: String?
    let taskID: String?
    let taskSubject: String?
    /// Present on `SubagentStart` / `SubagentStop` and on every hook fired
    /// from inside a subagent.
    let agentID: String?
    let agentType: String?
    let agentTranscriptPath: String?

    init(
        hookEventName: String,
        sessionID: String?,
        message: String?,
        notificationType: String?,
        cwd: String?,
        transcriptPath: String?,
        toolName: String?,
        toolInput: [String: Any],
        toolUseID: String?,
        taskID: String?,
        taskSubject: String?,
        agentID: String? = nil,
        agentType: String? = nil,
        agentTranscriptPath: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.message = message
        self.notificationType = notificationType
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.taskID = taskID
        self.taskSubject = taskSubject
        self.agentID = agentID
        self.agentType = agentType
        self.agentTranscriptPath = agentTranscriptPath
    }
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
            toolUseID: JSONKeyAccess.firstString(in: json, keys: ["tool_use_id", "toolUseId"]),
            taskID: JSONKeyAccess.firstString(in: json, keys: ["task_id", "taskId"]),
            taskSubject: JSONKeyAccess.firstString(in: json, keys: ["task", "task_subject", "taskSubject", "title"]),
            agentID: JSONKeyAccess.firstString(in: json, keys: ["agent_id", "agentId"]),
            agentType: JSONKeyAccess.firstString(in: json, keys: ["agent_type", "agentType", "agent_name", "agentName"]),
            agentTranscriptPath: JSONKeyAccess.firstString(in: json, keys: ["agent_transcript_path", "agentTranscriptPath"])
        )
    }

    static func claudeMakePayloads(
        from input: ClaudeAdapterInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore,
        subagentStore: AgentSubagentRegistryStore = AgentSubagentRegistryStore()
    ) throws -> [AgentStatusPayload] {
        let payloads = try claudeMakeLifecyclePayloads(
            from: input,
            environment: environment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        return try claudeAttachSubagents(to: payloads, input: input, subagentStore: subagentStore)
    }

    private static func claudeMakeLifecyclePayloads(
        from input: ClaudeAdapterInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore,
        subagentStore: AgentSubagentRegistryStore
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
                let subagents = try subagentStore.clear(key: claudeSubagentKey(target))
                return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID, subagents: subagents)]
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
                    confidence: .explicit,
                    toolUseID: input.toolUseID
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
                    confidence: .explicit,
                    toolUseID: input.toolUseID
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

        case "PostToolUse", "PostToolUseFailure":
            // The only hooks Claude Code emits between an approved tool and the
            // next Bash/Write/Edit call. Without them an approval prompt
            // answered with `1`/`y` (no Enter) stayed "Needs input" while
            // Claude worked through Read/Grep/Agent tools (agent-bench
            // claude/approval_then_work: 11 s of silence after approval).
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            if claudeShouldKeepPendingInteraction(existing: existing, completedToolUseID: input.toolUseID) {
                // A sibling tool from the same parallel batch finished while
                // another tool's permission / question dialog is still open.
                return []
            }
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? existing?.cwd,
                interactionKind: PaneAgentInteractionKind.none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID)
            )]

        case "UserPromptSubmit":
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

        case "SubagentStart":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let entry = claudeSubagentEntry(for: input, sessionTranscriptPath: existing?.transcriptPath)
            let subagents = try subagentStore.start(key: claudeSubagentKey(target), entry: entry)
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? existing?.cwd,
                interactionKind: .none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID),
                subagents: subagents
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
            // The main agent finished its turn, so no subagent can still be
            // running under it: broadcast the explicit empty set.
            let subagents = try subagentStore.clear(key: claudeSubagentKey(target))
            return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID, subagents: subagents)]

        case "SubagentStop":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            // The parent keeps working (it still has to read the subagent's
            // result), so this is a running update, not an idle transition.
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let subagents = try subagentStore.stop(
                key: claudeSubagentKey(target),
                subagentID: claudeSubagentID(for: input, sessionTranscriptPath: existing?.transcriptPath)
            )
            return [claudeLifecyclePayload(
                target: target, state: .running, cwd: input.cwd ?? existing?.cwd,
                interactionKind: .none, confidence: .explicit, sessionID: input.sessionID,
                taskProgress: try sessionStore.taskProgress(sessionID: input.sessionID),
                subagents: subagents
            )]

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
            try subagentStore.remove(key: claudeSubagentKey((record.windowID, record.worklaneID, record.paneID)))
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

    // MARK: - Claude Subagents

    static func claudeSubagentKey(
        _ target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)
    ) -> AgentSubagentRegistryStore.Key {
        AgentSubagentRegistryStore.Key(tool: "claude", worklaneID: target.worklaneID, paneID: target.paneID)
    }

    static func claudeSubagentID(for input: ClaudeAdapterInput, sessionTranscriptPath: String?) -> String? {
        if let agentID = AgentInteractionClassifier.trimmed(input.agentID) {
            return agentID
        }
        if let path = AgentInteractionClassifier.trimmed(input.agentTranscriptPath) {
            return path
        }
        return nil
    }

    static func claudeSubagentEntry(for input: ClaudeAdapterInput, sessionTranscriptPath: String?) -> PaneAgentSubagentEntry {
        let transcriptPath = AgentInteractionClassifier.trimmed(input.agentTranscriptPath)
            ?? AgentSubagentModelResolver.claudeAgentTranscriptPath(
                sessionTranscriptPath: sessionTranscriptPath,
                agentID: input.agentID
            )
        let id = claudeSubagentID(for: input, sessionTranscriptPath: sessionTranscriptPath)
            ?? transcriptPath
            ?? UUID().uuidString
        return PaneAgentSubagentEntry(
            id: id,
            agentType: AgentInteractionClassifier.trimmed(input.agentType),
            model: AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath),
            nickname: nil,
            transcriptPath: transcriptPath
        )
    }

    /// Hooks fired from inside a subagent (`PreToolUse`, `PostToolUse`, …)
    /// arrive after the subagent's first model response, which is the moment
    /// its transcript reveals the model. Fill in what `SubagentStart` could
    /// not know yet and carry the current set on the outgoing payload.
    private static func claudeAttachSubagents(
        to payloads: [AgentStatusPayload],
        input: ClaudeAdapterInput,
        subagentStore: AgentSubagentRegistryStore
    ) throws -> [AgentStatusPayload] {
        switch input.hookEventName {
        case "SubagentStart", "SubagentStop", "Stop", "SessionEnd", "SessionStart":
            return payloads
        default:
            break
        }
        guard let first = payloads.first(where: { $0.signalKind == .lifecycle }) else {
            return payloads
        }
        let key = AgentSubagentRegistryStore.Key(tool: "claude", worklaneID: first.worklaneID, paneID: first.paneID)
        return try attachSubagents(to: payloads, key: key, subagentStore: subagentStore) { entry in
            let transcriptPath = entry.transcriptPath
                ?? (input.agentID == entry.id ? AgentInteractionClassifier.trimmed(input.agentTranscriptPath) : nil)
            guard let model = AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath) else {
                return nil
            }
            return entry.with(model: model)
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

    static func claudeShouldKeepPendingInteraction(
        existing: ClaudeHookSessionRecord?,
        completedToolUseID: String?
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true,
              let pendingToolUseID = existing.lastStructuredInteractionToolUseID,
              let completedToolUseID = AgentInteractionClassifier.trimmed(completedToolUseID)
        else {
            return false
        }
        return pendingToolUseID != completedToolUseID
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
        taskProgress: PaneAgentTaskProgress? = nil,
        subagents: PaneAgentSubagentSummary? = nil
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
            subagents: subagents,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }
}

// MARK: - Adapter conformance

enum ClaudeEventAdapter: AgentEventAdapting {
    static let adapterName = "claude"
    static let suppressesErrors = true
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.claudeAdapter(data: data, environment: environment)
    }
}
