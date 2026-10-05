import Foundation

// MARK: - Claude Adapter

extension AgentEventBridge {
    static func claudeAdapter(
        data: Data,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        subagentStore: AgentSubagentRegistryStore = AgentSubagentRegistryStore()
    ) throws -> [AgentStatusPayload] {
        let input = try claudeParseInput(data)
        return try claudeMakePayloads(
            from: input,
            environment: environment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
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
    let toolResponse: [String: Any]?
    let toolUseID: String?
    let taskID: String?
    let taskSubject: String?
    /// Present on `SubagentStart` / `SubagentStop` and on every hook fired
    /// from inside a subagent.
    let agentID: String?
    let agentType: String?
    let agentTranscriptPath: String?
    /// `PostToolUseFailure` sets this when the user interrupted the tool
    /// (Escape / Ctrl-C). No Stop hook follows such an interrupt.
    let isInterrupt: Bool
    /// `SessionStart` only: `startup`, `resume`, `clear` or `compact`.
    let source: String?

    init(
        hookEventName: String,
        sessionID: String?,
        message: String?,
        notificationType: String?,
        cwd: String?,
        transcriptPath: String?,
        toolName: String?,
        toolInput: [String: Any],
        toolResponse: [String: Any]? = nil,
        toolUseID: String?,
        taskID: String?,
        taskSubject: String?,
        agentID: String? = nil,
        agentType: String? = nil,
        agentTranscriptPath: String? = nil,
        isInterrupt: Bool = false,
        source: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.message = message
        self.notificationType = notificationType
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolResponse = toolResponse
        self.toolUseID = toolUseID
        self.taskID = taskID
        self.taskSubject = taskSubject
        self.agentID = agentID
        self.agentType = agentType
        self.agentTranscriptPath = agentTranscriptPath
        self.isInterrupt = isInterrupt
        self.source = source
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
            toolResponse: (json["tool_response"] as? [String: Any]) ?? (json["toolResponse"] as? [String: Any]),
            toolUseID: JSONKeyAccess.firstString(in: json, keys: ["tool_use_id", "toolUseId"]),
            taskID: JSONKeyAccess.firstString(in: json, keys: ["task_id", "taskId"]),
            taskSubject: JSONKeyAccess.firstString(in: json, keys: ["task", "task_subject", "taskSubject", "title"]),
            agentID: JSONKeyAccess.firstString(in: json, keys: ["agent_id", "agentId"]),
            agentType: JSONKeyAccess.firstString(in: json, keys: ["agent_type", "agentType", "agent_name", "agentName"]),
            agentTranscriptPath: JSONKeyAccess.firstString(in: json, keys: ["agent_transcript_path", "agentTranscriptPath"]),
            isInterrupt: claudeParseBool(in: json, keys: ["is_interrupt", "isInterrupt"]),
            source: JSONKeyAccess.firstString(in: json, keys: ["source"])
        )
    }

    private static func claudeParseBool(in json: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            if let value = json[key] as? Bool {
                return value
            }
            if let number = json[key] as? NSNumber {
                return number.boolValue
            }
            if let string = json[key] as? String {
                return ["true", "1", "yes"].contains(string.lowercased())
            }
        }
        return false
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
            let startsFresh = claudeSessionStartResetsSubagents(source: input.source)
            if startsFresh {
                // A killed session never sent SubagentStop for its children;
                // a fresh (or resumed / cleared) session in the same pane must
                // not inherit those phantom entries. `compact` keeps the same
                // session and its live subagents.
                try subagentStore.remove(key: claudeSubagentKey(target))
            }
            if let sessionID = input.sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: input.cwd,
                    transcriptPath: input.transcriptPath,
                    pid: pid,
                    // SessionStart(compact) follows PreCompact mid-turn; a
                    // PreToolUse announced before the compaction still prompts
                    // after it and needs its queued id.
                    resetsPreToolUseSlots: startsFresh
                )
            }
            guard let pid else { return [] }
            return [pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: input.sessionID)]

        case "Notification":
            if input.notificationType == "idle_prompt" {
                let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
                let subagents = try subagentStore.summary(key: claudeSubagentKey(target))
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
            let inheritedToolUseID = input.toolUseID == nil
                ? claudeInheritedPreToolUseID(input: input, existing: existing)
                : nil
            let toolUseID = input.toolUseID
                ?? inheritedToolUseID
                ?? claudeRetainedStructuredToolUseID(input: input, existing: existing)
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
                    toolUseID: toolUseID,
                    toolName: input.toolName,
                    agentID: input.agentID,
                    // An announcement serves one prompt; a later
                    // PermissionRequest whose PreToolUse got dropped must not
                    // reuse it.
                    consumedPreToolUseID: inheritedToolUseID
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
                    toolUseID: input.toolUseID,
                    toolName: input.toolName,
                    agentID: input.agentID
                )
                return [claudeLifecyclePayload(target: target, state: .needsInput, text: message, interactionKind: prompt.interactionKind, confidence: .explicit, sessionID: input.sessionID)]
            }
            let preToolExisting = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                if claudePreToolUseBelongsToOtherAgent(input: input, existing: preToolExisting) {
                    // Another agent context keeps working while this one's
                    // dialog is open (a subagent editing while the parent
                    // waits for approval). Remember the call, leave the
                    // prompt alone and say nothing: the pane stays on
                    // needsInput.
                    try sessionStore.rememberPreToolUse(
                        sessionID: sessionID,
                        toolUseID: input.toolUseID,
                        toolName: input.toolName,
                        agentID: input.agentID
                    )
                    return []
                }
                // Keep the other agent contexts' slots: a subagent's PreToolUse
                // must not forget the parent's announced call.
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
                // PermissionRequest carries no tool_use_id; remember this call so
                // the prompt that may follow can be tied to it.
                try sessionStore.rememberPreToolUse(
                    sessionID: sessionID,
                    toolUseID: input.toolUseID,
                    toolName: input.toolName,
                    agentID: input.agentID
                )
            }
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
            if input.hookEventName == "PostToolUseFailure", input.isInterrupt {
                // The user pressed Escape / Ctrl-C during the tool. Claude is
                // back at its prompt and no Stop hook will follow; the terminal
                // title ("✳") already drove the pane to idle, so forcing
                // `.running` here would stick until the next prompt.
                if let sessionID = input.sessionID {
                    try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
                }
                guard existing?.structuredInteractionKind != nil else {
                    return []
                }
                // Escape on an open permission / question dialog: the title
                // already showed "✳" while the dialog was up, so nothing else
                // moves the pane off needsInput. Say idle explicitly.
                let subagents = try subagentStore.summary(key: claudeSubagentKey(target))
                return [claudeLifecyclePayload(
                    target: target, state: .idle,
                    interactionKind: PaneAgentInteractionKind.none, confidence: .explicit,
                    sessionID: input.sessionID, subagents: subagents
                )]
            }
            if let sessionID = input.sessionID {
                // Finished calls leave the queue whether or not they prompted.
                try sessionStore.forgetPreToolUse(sessionID: sessionID, toolUseID: input.toolUseID, agentID: input.agentID)
                if input.hookEventName == "PostToolUse" {
                    // TaskCreate/TaskUpdate PostToolUse carries the task list
                    // changes TaskCreated/TaskCompleted do not (the id join for
                    // `in_progress` lives only here).
                    try claudeApplyTaskToolUse(input: input, sessionID: sessionID, sessionStore: sessionStore)
                }
            }
            if claudeShouldKeepPendingInteraction(
                existing: existing,
                completedToolUseID: input.toolUseID,
                completedToolName: input.toolName,
                completedAgentID: input.agentID
            ) {
                // A sibling tool from the same parallel batch finished while
                // another tool's permission / question dialog is still open.
                return []
            }
            if let sessionID = input.sessionID {
                // The batch's other announcements stay queued: the next
                // PermissionRequest in the same turn still needs its id.
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
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
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
            }
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let entry = claudeSubagentEntry(
                for: input,
                sessionTranscriptPath: input.transcriptPath ?? existing?.transcriptPath
            )
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
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
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
            let taskProgress = try sessionStore.updateTask(sessionID: sessionID, taskID: taskID, subject: input.taskSubject, status: .pending)
            return [claudeLifecyclePayload(target: target, state: .running, cwd: input.cwd, interactionKind: .none, confidence: .explicit, sessionID: sessionID, taskProgress: taskProgress)]

        case "TaskCompleted":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            guard let sessionID = input.sessionID, let taskID = input.taskID else { return [] }
            let taskProgress = try sessionStore.updateTask(sessionID: sessionID, taskID: taskID, subject: input.taskSubject, status: .done)
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
            // Agent tool calls run asynchronously: the parent ends its turn
            // while its subagents keep working and is re-woken when they
            // finish. Carry the live (liveness-pruned) set rather than
            // blanking it; SubagentStop retires entries one by one.
            let subagents = try subagentStore.summary(key: claudeSubagentKey(target))
            return [claudeLifecyclePayload(target: target, state: .idle, confidence: .explicit, sessionID: input.sessionID, subagents: subagents)]

        case "SubagentStop":
            let target = try claudeResolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let key = claudeSubagentKey(target)
            let existing = try claudeLookupRecord(for: input, sessionStore: sessionStore)
            let subagentID = claudeSubagentID(for: input, sessionTranscriptPath: existing?.transcriptPath)
            guard let subagents = try subagentStore.stopIfTracked(key: key, subagentID: subagentID) else {
                // Claude's internal forks (for example an away recap) emit
                // SubagentStop without SubagentStart. Their completion does
                // not resume the parent or answer its pending prompt. The
                // same applies to a duplicate worker stop.
                return []
            }
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
            }
            // The parent keeps working (it still has to read the subagent's
            // result), so this is a running update, not an idle transition.
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

    /// `startup`, `resume` and `clear` all begin from an empty subagent set;
    /// `compact` continues the running session. An absent `source` (older
    /// Claude Code) is treated as a fresh start.
    static func claudeSessionStartResetsSubagents(source: String?) -> Bool {
        guard let source = AgentInteractionClassifier.trimmed(source)?.lowercased() else {
            return true
        }
        return ["startup", "resume", "clear"].contains(source)
    }

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
        // A hook fired from inside a subagent proves it is alive: re-register
        // it in case liveness pruning retired it during a long tool call.
        if AgentInteractionClassifier.trimmed(input.agentID) != nil {
            try subagentStore.start(key: key, entry: claudeSubagentEntry(for: input, sessionTranscriptPath: input.transcriptPath))
        }
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

    /// `PostToolUse` for `TaskCreate` carries `tool_response.task.{id,subject}`
    /// (a fallback for sessions where `TaskCreated` never fired); `TaskUpdate`
    /// carries `tool_input.{taskId,status}` joined onto the earlier `task_id`,
    /// with `tool_response.statusChange.to` as a fallback status source.
    private static func claudeApplyTaskToolUse(
        input: ClaudeAdapterInput,
        sessionID: String,
        sessionStore: ClaudeHookSessionStore
    ) throws {
        switch input.toolName {
        case "TaskCreate":
            let task = input.toolResponse?["task"] as? [String: Any]
            guard let taskID = JSONKeyAccess.firstString(in: task, keys: ["id"])
                ?? JSONKeyAccess.firstString(in: input.toolResponse, keys: ["taskId", "task_id", "id"]) else {
                return
            }
            let subject = JSONKeyAccess.firstString(in: task, keys: ["subject", "title"])
                ?? JSONKeyAccess.firstString(in: input.toolInput, keys: ["subject", "title"])
            _ = try sessionStore.registerTask(sessionID: sessionID, taskID: taskID, subject: subject)

        case "TaskUpdate":
            guard let taskID = JSONKeyAccess.firstString(in: input.toolInput, keys: ["taskId", "task_id", "id"])
                ?? JSONKeyAccess.firstString(in: input.toolResponse, keys: ["taskId", "task_id", "id"]) else {
                return
            }
            let statusChange = input.toolResponse?["statusChange"] as? [String: Any]
            let status = JSONKeyAccess.firstString(in: input.toolInput, keys: ["status", "state"])
                ?? JSONKeyAccess.firstString(in: statusChange, keys: ["to"])
                ?? JSONKeyAccess.firstString(in: input.toolResponse, keys: ["status", "state"])
            _ = try sessionStore.updateTask(
                sessionID: sessionID,
                taskID: taskID,
                subject: JSONKeyAccess.firstString(in: input.toolInput, keys: ["subject", "title"]),
                status: status.map { PaneAgentTaskItemStatus(rawHarnessStatus: $0) }
            )

        default:
            return
        }
    }

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
