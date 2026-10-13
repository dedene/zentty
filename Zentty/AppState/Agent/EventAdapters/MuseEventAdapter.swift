import Foundation

// MARK: - Muse Code Adapter

/// Muse Code (Meta's `muse` CLI) hooks are Claude Code-format compatible
/// (`hook_event_name`, `session_id`, `tool_name`, `tool_input`,
/// `tool_use_id`, `tool_response`) with these differences:
///
/// 1. Hooks fire for every thread, not just the root session. Delegated
///    subagents and Muse's internal reminder agents (`skill-reminder`,
///    `scope-reminder`, … — they keep running after the root `Stop`) report
///    their own thread id as `session_id`. The root id is always in
///    `MUSE_SESSION_ID`, so only events from that thread drive the pane.
/// 2. Real subagents announce themselves with `SubagentStart`/`SubagentStop`
///    (`subagent_id` is a UUID, `model` is the child's model). Reminder
///    agents use the same events with an id ending in `-reminder`.
/// 3. Muse's own tools — the todo list (`write_todos`, items
///    `{text, status}`) and questions (`request_user_input`) — never fire
///    `PreToolUse`/`PostToolUse`; they only surface in `PostToolBatch`. A
///    question is announced by `Notification` (`question_prompt`) and answered
///    when its call shows up in a batch.
/// 4. `ToolUseStart` fires once an approved call actually starts executing —
///    the moment an approval prompt is answered.
extension AgentEventBridge {
    /// Slot-queue key marking the open root turn (set on `UserPromptSubmit`
    /// with the turn id, dropped at turn end), so a background subagent that
    /// stops after the parent went idle keeps the pane idle, and a late async
    /// `Interrupt` for an earlier turn can be told apart.
    private static let museTurnSlotAgentID = "muse:turn"
    private static let museTurnSlotFallbackID = "muse:turn"
    /// Slot-queue key holding the `role` of each `subagent_spawn` call until
    /// its `SubagentStart` (which carries no agent type) claims it.
    private static let museSpawnSlotAgentID = "muse:spawn"
    private static let museReminderDecisionToolName = "submit_reminder_decision"

    static func museAdapter(
        data: Data,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore = ClaudeHookSessionStore(),
        subagentStore: AgentSubagentRegistryStore = AgentSubagentRegistryStore()
    ) throws -> [AgentStatusPayload] {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = JSONKeyAccess.firstString(in: json, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        let threadSessionID = JSONKeyAccess.firstString(in: json, keys: ["session_id", "sessionId"])
        let rootSessionID = environment["MUSE_SESSION_ID"]?.nilIfBlank
        // Without MUSE_SESSION_ID every event counts as the root's.
        let isRootThread = rootSessionID == nil || threadSessionID == rootSessionID
        let sessionID = rootSessionID ?? threadSessionID
        let cwd = JSONKeyAccess.firstString(in: json, keys: ["cwd", "working_directory", "workingDirectory"])
        let toolName = JSONKeyAccess.firstString(in: json, keys: ["tool_name", "toolName"])
        let toolInput = (json["tool_input"] as? [String: Any]) ?? [:]
        let toolUseID = JSONKeyAccess.firstString(in: json, keys: ["tool_use_id", "toolUseId"])
        let turnID = JSONKeyAccess.firstString(in: json, keys: ["turn_id", "turnId"])
        // Interactions raised inside a child thread are keyed by that thread,
        // so the root's own tool traffic cannot answer them (and vice versa).
        let interactionAgentID = isRootThread ? nil : threadSessionID
        let displayName = AgentTool.muse.displayName
        let pid = parseAgentPID(from: environment, key: "ZENTTY_MUSE_PID")

        // Reminder agents' decision tool is internal bookkeeping, never user work.
        if toolName == museReminderDecisionToolName {
            return []
        }

        switch hookEventName {
        case "SessionStart":
            guard isRootThread else { return [] }
            let target = try currentTarget(from: environment)
            // A fresh or resumed session; entries left by a killed run are stale.
            try subagentStore.remove(key: museSubagentKey(target))
            if let sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: cwd,
                    pid: pid,
                    resetsPreToolUseSlots: true
                )
                try subagentStore.recordRootSession(key: museSubagentKey(target), sessionID: sessionID)
            }
            var payloads: [AgentStatusPayload] = [
                lifecyclePayload(target: target, toolName: displayName, state: .starting, sessionID: sessionID, cwd: cwd),
            ]
            if let pid {
                payloads.append(pidPayload(target: target, toolName: displayName, pid: pid, event: .attach, sessionID: sessionID))
            }
            return payloads

        case "UserPromptSubmit":
            guard isRootThread else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
                try sessionStore.rememberPreToolUse(
                    sessionID: sessionID,
                    toolUseID: turnID ?? museTurnSlotFallbackID,
                    toolName: nil,
                    agentID: museTurnSlotAgentID
                )
            }
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "PreToolUse":
            guard isRootThread else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.rememberPreToolUse(sessionID: sessionID, toolUseID: toolUseID, toolName: toolName, agentID: nil)
                if toolName == "subagent_spawn",
                   let role = JSONKeyAccess.firstString(in: toolInput, keys: ["role", "subagent_type", "agent_type"]) {
                    try sessionStore.rememberPreToolUse(sessionID: sessionID, toolUseID: toolUseID, toolName: role, agentID: museSpawnSlotAgentID)
                }
            }
            // PreToolUse fires before the approval check; an open prompt for
            // a sibling call must stay visible.
            if let sessionID,
               try sessionStore.lookup(sessionID: sessionID)?.structuredInteractionKind != nil {
                return []
            }
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "ToolUseStart":
            // The approved call starting answers the prompt. Other threads keep
            // starting tools meanwhile, so it must come from the thread that
            // asked, for the tool that was asked about.
            guard let sessionID,
                  let record = try sessionStore.lookup(sessionID: sessionID),
                  record.structuredInteractionKind == .approval,
                  AgentInteractionClassifier.trimmed(record.lastStructuredInteractionAgentID)
                      == AgentInteractionClassifier.trimmed(interactionAgentID),
                  record.lastStructuredInteractionToolName == nil || record.lastStructuredInteractionToolName == toolName else {
                return []
            }
            let target = (record.windowID, record.worklaneID, record.paneID)
            try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd ?? record.cwd)]

        case "PostToolUse", "PostToolUseFailure":
            guard isRootThread else {
                // A child finishing a tool has moved past its own prompt
                // (approved, or denied and carrying on).
                guard let sessionID,
                      let record = try sessionStore.lookup(sessionID: sessionID),
                      record.structuredInteractionKind != nil,
                      let interactionAgentID,
                      AgentInteractionClassifier.trimmed(record.lastStructuredInteractionAgentID) == interactionAgentID else {
                    return []
                }
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
                return [lifecyclePayload(
                    target: (record.windowID, record.worklaneID, record.paneID), toolName: displayName,
                    state: .running, sessionID: sessionID, cwd: record.cwd
                )]
            }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.forgetPreToolUse(sessionID: sessionID, toolUseID: toolUseID, agentID: nil)
                // A spawn that failed before starting its child leaves its role
                // unclaimed; drop it so the next spawn's child is not mislabelled.
                if toolName == "subagent_spawn" {
                    try sessionStore.forgetPreToolUse(sessionID: sessionID, toolUseID: toolUseID, agentID: museSpawnSlotAgentID)
                }
            }
            // A sibling tool finishing while a question/approval prompt is
            // open must not move the pane off needsInput.
            if let sessionID,
               let existing = try sessionStore.lookup(sessionID: sessionID),
               claudeShouldKeepPendingInteraction(
                   existing: existing,
                   completedToolUseID: toolUseID,
                   completedToolName: toolName
               ) {
                return []
            }
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
            }
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "PostToolBatch":
            let toolCalls = json["tool_calls"] as? [[String: Any]] ?? []
            let batchToolNames = Set(toolCalls.compactMap { JSONKeyAccess.firstString(in: $0, keys: ["tool_name", "toolName"]) })
            // A question is answered once its call completes in a batch from
            // the thread that asked.
            var answeredQuestion = false
            if let sessionID,
               let record = try sessionStore.lookup(sessionID: sessionID),
               record.structuredInteractionKind == .decision,
               AgentInteractionClassifier.trimmed(record.lastStructuredInteractionAgentID)
                   == AgentInteractionClassifier.trimmed(interactionAgentID),
               batchToolNames.contains(where: museIsQuestionTool) {
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
                answeredQuestion = true
            }
            let todos = isRootThread ? museLatestTodos(in: toolCalls) : nil
            guard answeredQuestion || todos != nil else { return [] }
            if let sessionID,
               try sessionStore.lookup(sessionID: sessionID)?.structuredInteractionKind != nil {
                return []
            }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            return [lifecyclePayload(
                target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd,
                taskProgress: todos.flatMap { PaneAgentTaskProgress(items: taskItems(fromTodoObjects: $0)) }
            )]

        case "PermissionRequest":
            // A subagent waiting on approval blocks the session too, so any
            // thread's request counts; it is stored on the root session.
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            let existing = try sessionID.flatMap { try sessionStore.lookup(sessionID: $0) }
            let slots = existing?.preToolUseSlots(agentID: nil) ?? []
            let resolvedToolUseID = toolUseID
                ?? (isRootThread ? slots.first(where: { $0.toolName == toolName })?.toolUseID : nil)
            let message = musePermissionText(toolName: toolName, toolInput: toolInput)
            if let sessionID {
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: cwd ?? existing?.cwd,
                    pid: pid ?? existing?.pid,
                    text: message,
                    kind: .approval,
                    confidence: .explicit,
                    toolUseID: resolvedToolUseID,
                    toolName: toolName,
                    agentID: interactionAgentID,
                    consumedPreToolUseID: resolvedToolUseID
                )
            }
            return [museInteractionPayload(target: target, text: message, kind: .approval, sessionID: sessionID, cwd: cwd)]

        case "Notification":
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            let existing = try sessionID.flatMap { try sessionStore.lookup(sessionID: $0) }
            switch JSONKeyAccess.firstString(in: json, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt":
                // Sent only while an approval is still pending after Muse's
                // grace period; it backstops PermissionRequest.
                let message = existing?.structuredInteractionText
                    ?? JSONKeyAccess.firstString(in: json, keys: ["title", "message"])
                    ?? "Muse Code needs approval"
                return [museInteractionPayload(target: target, text: message, kind: .approval, sessionID: sessionID, cwd: cwd)]
            case "question_prompt":
                // `request_user_input` fires no tool hook until it is answered;
                // this is the only signal that a question is open. The
                // question text itself only arrives with the answer.
                let message = JSONKeyAccess.firstString(in: json, keys: ["title"]) ?? "Muse Code needs your input"
                if let sessionID {
                    try sessionStore.rememberStructuredInteraction(
                        sessionID: sessionID,
                        windowID: target.windowID,
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        cwd: cwd ?? existing?.cwd,
                        pid: pid ?? existing?.pid,
                        text: message,
                        kind: .decision,
                        confidence: .explicit,
                        toolName: "request_user_input",
                        agentID: interactionAgentID
                    )
                }
                return [museInteractionPayload(target: target, text: message, kind: .decision, sessionID: sessionID, cwd: cwd)]
            default:
                return []
            }

        case "SubagentStart":
            guard let subagentID = museRealSubagentID(json) else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            let entry = PaneAgentSubagentEntry(
                id: subagentID,
                agentType: try JSONKeyAccess.firstString(in: json, keys: ["subagent_type", "agent_type", "role"])
                    ?? museClaimSpawnRole(sessionID: sessionID, sessionStore: sessionStore),
                model: JSONKeyAccess.firstString(in: json, keys: ["model"])
            )
            let subagents = try subagentStore.start(key: museSubagentKey(target), entry: entry)
            return [lifecyclePayload(
                target: target, toolName: displayName, state: museParentTurnState(sessionID: sessionID, sessionStore: sessionStore),
                sessionID: sessionID, cwd: cwd, subagents: subagents
            )]

        case "SubagentStop":
            guard let subagentID = museRealSubagentID(json) else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            guard let subagents = try subagentStore.stopIfTracked(key: museSubagentKey(target), subagentID: subagentID) else {
                return []
            }
            var record = try sessionID.flatMap { try sessionStore.lookup(sessionID: $0) }
            // A child that ends with its own approval still open (denied,
            // cancelled) can no longer be waiting on it.
            if let sessionID,
               let pendingAgentID = AgentInteractionClassifier.trimmed(record?.lastStructuredInteractionAgentID),
               pendingAgentID == JSONKeyAccess.firstString(in: json, keys: ["child_session_id", "childSessionId"]) {
                try sessionStore.clearInteractionContext(sessionID: sessionID, keepsPreToolUseSlots: true)
                record = try sessionStore.lookup(sessionID: sessionID)
            }
            if let pendingKind = record?.structuredInteractionKind {
                return [lifecyclePayload(
                    target: target, toolName: displayName, state: .needsInput,
                    text: record?.structuredInteractionText, interactionKind: pendingKind,
                    sessionID: sessionID, cwd: cwd, subagents: subagents
                )]
            }
            return [lifecyclePayload(
                target: target, toolName: displayName, state: museParentTurnState(sessionID: sessionID, sessionStore: sessionStore),
                sessionID: sessionID, cwd: cwd, subagents: subagents
            )]

        case "PreCompact":
            guard isRootThread else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, text: "Compacting", sessionID: sessionID, cwd: cwd)]

        case "PostCompact":
            guard isRootThread else { return [] }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            return [lifecyclePayload(target: target, toolName: displayName, state: .running, sessionID: sessionID, cwd: cwd)]

        case "Stop", "StopFailure", "Interrupt":
            guard isRootThread else { return [] }
            // `Interrupt` is async: one for an earlier turn can land after the
            // next prompt was submitted.
            if hookEventName == "Interrupt",
               let sessionID, let turnID,
               let openTurn = try sessionStore.lookup(sessionID: sessionID)?.preToolUseSlots(agentID: museTurnSlotAgentID).first,
               openTurn.toolUseID != turnID,
               openTurn.toolUseID != museTurnSlotFallbackID {
                return []
            }
            let target = try museResolvedTarget(sessionID: sessionID, environment: environment, sessionStore: sessionStore)
            if let sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            // Subagents may outlive the parent's turn; carry the live set.
            let subagents = try subagentStore.summary(key: museSubagentKey(target))
            return [lifecyclePayload(target: target, toolName: displayName, state: .idle, sessionID: sessionID, cwd: cwd, subagents: subagents)]

        case "SessionEnd":
            guard isRootThread else { return [] }
            let current = currentTargetIfAvailable(from: environment)
            let record = try sessionStore.consume(
                sessionID: sessionID,
                fallbackWindowID: current?.windowID,
                fallbackWorklaneID: current?.worklaneID,
                fallbackPaneID: current?.paneID
            )
            guard let record else { return [] }
            let target = (record.windowID, record.worklaneID, record.paneID)
            try subagentStore.remove(key: museSubagentKey(target))
            return [
                AgentStatusPayload(
                    windowID: target.0, worklaneID: target.1, paneID: target.2,
                    state: nil, origin: .explicitHook, toolName: displayName, text: nil,
                    sessionID: record.sessionID, artifactKind: nil, artifactLabel: nil, artifactURL: nil
                ),
                pidPayload(target: target, toolName: displayName, pid: nil, event: .clear, sessionID: record.sessionID),
            ]

        default:
            return []
        }
    }

    // MARK: - Muse helpers

    private static func museResolvedTarget(
        sessionID: String?,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        if let sessionID,
           let record = try sessionStore.lookup(sessionID: sessionID) {
            return (record.windowID, record.worklaneID, record.paneID)
        }
        return try currentTarget(from: environment)
    }

    private static func museSubagentKey(
        _ target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)
    ) -> AgentSubagentRegistryStore.Key {
        AgentSubagentRegistryStore.Key(tool: "muse", worklaneID: target.worklaneID, paneID: target.paneID)
    }

    /// The `subagent_id` of a delegated subagent, or nil for Muse's internal
    /// reminder agents (`skill-reminder`, `goal-reminder`, …).
    private static func museRealSubagentID(_ json: [String: Any]) -> String? {
        guard let subagentID = JSONKeyAccess.firstString(in: json, keys: ["subagent_id", "subagentId", "agent_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !subagentID.isEmpty,
              !subagentID.hasSuffix("-reminder") else {
            return nil
        }
        return subagentID
    }

    /// The role of the oldest `subagent_spawn` call not yet matched to a
    /// `SubagentStart`; spawns start their child in call order.
    private static func museClaimSpawnRole(sessionID: String?, sessionStore: ClaudeHookSessionStore) throws -> String? {
        guard let sessionID,
              let slot = try sessionStore.lookup(sessionID: sessionID)?.preToolUseSlots(agentID: museSpawnSlotAgentID).first else {
            return nil
        }
        try sessionStore.forgetPreToolUse(sessionID: sessionID, toolUseID: slot.toolUseID, agentID: museSpawnSlotAgentID)
        return slot.toolName
    }

    private static func museParentTurnState(sessionID: String?, sessionStore: ClaudeHookSessionStore) -> PaneAgentState {
        guard let sessionID,
              let record = try? sessionStore.lookup(sessionID: sessionID) else {
            return .running
        }
        return record.preToolUseSlots(agentID: museTurnSlotAgentID).isEmpty ? .idle : .running
    }

    private static func museIsQuestionTool(_ toolName: String?) -> Bool {
        guard let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return name == "request_user_input" || name == "request_user_input_async"
    }

    private static func musePermissionText(toolName: String?, toolInput: [String: Any]) -> String {
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = JSONKeyAccess.firstString(in: toolInput, keys: ["command", "path", "file_path", "filePath", "url", "query"])
        switch (name, detail) {
        case let (name?, detail?):
            return "Muse Code wants to run \(name): \(detail)"
        case let (name?, nil):
            return "Muse Code wants to run \(name)"
        default:
            return "Muse Code needs approval"
        }
    }

    /// The todo list from the last `write_todos` call in a batch, if any.
    private static func museLatestTodos(in toolCalls: [[String: Any]]) -> [[String: Any]]? {
        toolCalls.last { call in
            JSONKeyAccess.firstString(in: call, keys: ["tool_name", "toolName"]) == "write_todos"
        }
        .flatMap { ($0["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]] }
    }

    private static func museInteractionPayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        text: String,
        kind: PaneAgentInteractionKind,
        sessionID: String?,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: AgentTool.muse.displayName,
            text: text,
            lifecycleEvent: .update,
            interactionKind: kind,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }
}

// MARK: - Adapter conformance

enum MuseEventAdapter: AgentEventAdapting {
    static let adapterName = "muse"
    static let suppressesErrors = true
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.museAdapter(data: data, environment: environment)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
