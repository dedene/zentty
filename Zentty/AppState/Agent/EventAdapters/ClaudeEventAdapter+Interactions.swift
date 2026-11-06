import Foundation

// MARK: - Claude Adapter: prompts and pending interactions

extension AgentEventBridge {
    /// Whether a PostToolUse belongs to a tool *other* than the one whose
    /// permission / question prompt is open, in which case the prompt stays.
    /// Prefers `tool_use_id`; falls back to `tool_name` because Claude Code's
    /// PermissionRequest payload has no id and the PreToolUse matcher only
    /// covers Bash/Write/Edit, so the id is often unknown.
    static func claudeShouldKeepPendingInteraction(
        existing: ClaudeHookSessionRecord?,
        completedToolUseID: String?,
        completedToolName: String? = nil,
        completedAgentID: String? = nil
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true
        else {
            return false
        }
        // A tool finishing inside another agent context (a subagent while the
        // parent's prompt is open, or vice versa) says nothing about the
        // prompt.
        if AgentInteractionClassifier.trimmed(existing.lastStructuredInteractionAgentID)
            != AgentInteractionClassifier.trimmed(completedAgentID) {
            return true
        }
        if let pendingToolUseID = existing.lastStructuredInteractionToolUseID,
           let completedToolUseID = AgentInteractionClassifier.trimmed(completedToolUseID) {
            return pendingToolUseID != completedToolUseID
        }
        if let pendingToolName = existing.lastStructuredInteractionToolName,
           let completedToolName = AgentInteractionClassifier.trimmed(completedToolName) {
            return pendingToolName != completedToolName
        }
        return false
    }

    /// `tool_use_id` for a PermissionRequest, taken from the oldest unclaimed
    /// PreToolUse that announced the same tool in the same agent context.
    /// Oldest because Claude Code fires PreToolUse for a whole parallel batch
    /// before the first prompt: the call that needs approval was announced
    /// before the allowlisted siblings that followed it.
    static func claudeInheritedPreToolUseID(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> String? {
        guard let existing,
              let toolName = AgentInteractionClassifier.trimmed(input.toolName)
        else {
            return nil
        }
        return existing.preToolUseSlots(agentID: input.agentID)
            .first(where: { $0.toolName == toolName })?
            .toolUseID
    }

    /// Whether a PreToolUse fired from another agent context while a prompt
    /// is open. A subagent's Edit must not wipe the parent's permission
    /// dialog (nor the parent's Bash a subagent's AskUserQuestion).
    static func claudePreToolUseBelongsToOtherAgent(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true
        else {
            return false
        }
        return AgentInteractionClassifier.trimmed(existing.lastStructuredInteractionAgentID)
            != AgentInteractionClassifier.trimmed(input.agentID)
    }

    /// Whether the open prompt is a dialog from a worker that is still
    /// running, which the parent's `Stop` says nothing about.
    static func claudePromptBelongsToLiveWorker(
        existing: ClaudeHookSessionRecord?,
        subagents: PaneAgentSubagentSummary?
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true,
              let promptAgentID = AgentInteractionClassifier.trimmed(existing.lastStructuredInteractionAgentID)
        else {
            return false
        }
        return subagents?.entries.contains { $0.id == promptAgentID } == true
    }

    /// Whether a `SubagentStop` ends the open prompt: the dialog was the
    /// stopping worker's own, so it went away with the worker.
    static func claudeSubagentStopResolvesPrompt(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> Bool {
        guard let existing,
              existing.structuredInteractionKind?.requiresHumanAttention == true,
              let promptAgentID = AgentInteractionClassifier.trimmed(existing.lastStructuredInteractionAgentID)
        else {
            return false
        }
        return promptAgentID == AgentInteractionClassifier.trimmed(input.agentID)
    }

    /// `tool_use_id` already stored for the open prompt when a PermissionRequest
    /// re-describes the same tool call: PreToolUse(AskUserQuestion) carries the
    /// id, the PermissionRequest that follows it does not, and no PreToolUse
    /// slot exists for it (AskUserQuestion is not in the Bash/Write/Edit
    /// matcher set). Losing the id here would drop the sibling check back to
    /// tool-name matching.
    static func claudeRetainedStructuredToolUseID(
        input: ClaudeAdapterInput,
        existing: ClaudeHookSessionRecord?
    ) -> String? {
        guard let existing,
              let toolName = AgentInteractionClassifier.trimmed(input.toolName),
              existing.lastStructuredInteractionToolName == toolName,
              AgentInteractionClassifier.trimmed(existing.lastStructuredInteractionAgentID)
                == AgentInteractionClassifier.trimmed(input.agentID)
        else {
            return nil
        }
        return existing.lastStructuredInteractionToolUseID
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
}
