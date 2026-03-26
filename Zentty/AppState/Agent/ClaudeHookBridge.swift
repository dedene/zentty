import Darwin
import Foundation

struct ClaudeHookInput {
    let hookEventName: String
    let sessionID: String?
    let message: String?
    let cwd: String?
    let toolName: String?
    let toolInput: [String: Any]
}

struct ClaudeHookSessionRecord: Codable, Equatable {
    let sessionID: String
    var worklaneIDRawValue: String
    var paneIDRawValue: String
    var cwd: String?
    var pid: Int32?
    var lastHumanMessage: String?
    var lastInteractionKindRawValue: String?
    var lastStructuredInteractionText: String?
    var lastStructuredInteractionKindRawValue: String?
    var lastStructuredInteractionConfidenceRawValue: String?
    var lastNotificationText: String?
    var updatedAt: TimeInterval

    var worklaneID: WorklaneID {
        WorklaneID(worklaneIDRawValue)
    }

    var paneID: PaneID {
        PaneID(paneIDRawValue)
    }

    var lastInteractionKind: PaneAgentInteractionKind? {
        get { lastInteractionKindRawValue.flatMap(PaneAgentInteractionKind.init(rawValue:)) }
        set { lastInteractionKindRawValue = newValue?.rawValue }
    }

    var structuredInteractionText: String? {
        get { lastStructuredInteractionText ?? lastHumanMessage }
        set {
            lastStructuredInteractionText = newValue
            lastHumanMessage = newValue
        }
    }

    var structuredInteractionKind: PaneAgentInteractionKind? {
        get {
            lastStructuredInteractionKindRawValue
                .flatMap(PaneAgentInteractionKind.init(rawValue:))
                ?? lastInteractionKind
        }
        set {
            lastStructuredInteractionKindRawValue = newValue?.rawValue
            lastInteractionKind = newValue
        }
    }

    var structuredInteractionConfidence: AgentSignalConfidence? {
        get { lastStructuredInteractionConfidenceRawValue.flatMap(AgentSignalConfidence.init(rawValue:)) }
        set { lastStructuredInteractionConfidenceRawValue = newValue?.rawValue }
    }
}

enum ClaudeHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "claude-hook" else {
            return nil
        }

        do {
            let input = try parseInput(readStandardInput())
            let sessionStore = ClaudeHookSessionStore()
            for payload in try makePayloads(from: input, environment: environment, sessionStore: sessionStore) {
                AgentStatusHelper.post(payload)
            }
            return EXIT_SUCCESS
        } catch {
            AgentStatusHelper.writeError(error)
            return EXIT_FAILURE
        }
    }

    static func parseInput(_ data: Data) throws -> ClaudeHookInput {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = firstString(in: json, keys: ["hook_event_name"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return ClaudeHookInput(
            hookEventName: hookEventName,
            sessionID: firstString(in: json, keys: ["session_id", "sessionId"]),
            message: firstString(in: json, keys: ["message", "body", "text", "prompt", "error", "description"]),
            cwd: extractCurrentWorkingDirectory(from: json),
            toolName: firstString(in: json, keys: ["tool_name", "toolName"]),
            toolInput: (json["tool_input"] as? [String: Any]) ?? [:]
        )
    }

    static func makePayloads(
        from input: ClaudeHookInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> [AgentStatusPayload] {
        switch input.hookEventName {
        case "SessionStart":
            let target = try currentTarget(from: environment)
            let pid = parseClaudePID(from: environment)
            if let sessionID = input.sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: input.cwd,
                    pid: pid
                )
            }
            guard let pid else {
                return []
            }
            return [
                pidPayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    pid: pid,
                    event: .attach,
                    sessionID: input.sessionID
                ),
            ]

        case "Notification":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let sessionRecord = try lookupRecord(for: input, sessionStore: sessionStore)
            let originalMessage = AgentInteractionClassifier.trimmed(input.message)
            let hasExplicitStructuredInteraction = sessionRecord?.structuredInteractionKind?.requiresHumanAttention == true
            let isGenericMessage = AgentInteractionClassifier.isGenericNeedsInputMessage(originalMessage)
            let requiresAttention = AgentInteractionClassifier.requiresHumanInput(message: originalMessage)

            guard requiresAttention || (hasExplicitStructuredInteraction && isGenericMessage) else {
                return []
            }

            if let sessionID = input.sessionID, let originalMessage {
                try sessionStore.recordNotificationText(sessionID: sessionID, text: originalMessage)
            }

            if let structuredKind = sessionRecord?.structuredInteractionKind,
               let structuredConfidence = sessionRecord?.structuredInteractionConfidence ?? sessionRecord.map({ _ in .explicit }),
               structuredKind.requiresHumanAttention {
                let message: String
                if let originalMessage,
                   shouldReplaceStructuredInteractionText(
                    with: originalMessage,
                    structuredKind: structuredKind
                   ) {
                    message = originalMessage
                } else {
                    message = sessionRecord?.structuredInteractionText
                        ?? AgentInteractionClassifier.preferredWaitingMessage(
                            existing: sessionRecord?.lastNotificationText,
                            candidate: originalMessage
                        )
                        ?? "Claude is waiting for your input"
                }

                return [
                    lifecyclePayload(
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        state: .needsInput,
                        text: message,
                        interactionKind: structuredKind,
                        confidence: structuredConfidence,
                        sessionID: input.sessionID
                    ),
                ]
            }

            let message: String
            if let originalMessage, !AgentInteractionClassifier.isGenericNeedsInputMessage(originalMessage) {
                message = originalMessage
            } else {
                message = AgentInteractionClassifier.preferredWaitingMessage(
                    existing: sessionRecord?.lastNotificationText,
                    candidate: originalMessage
                ) ?? "Claude is waiting for your input"
            }

            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: message,
                    interactionKind: .genericInput,
                    confidence: .strong,
                    sessionID: input.sessionID
                ),
            ]

        case "PermissionRequest":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let existing = try lookupRecord(for: input, sessionStore: sessionStore)
            let candidateMessage = AgentInteractionClassifier.trimmed(input.message) ?? "Claude needs your approval"
            let message = preferredStructuredInteractionText(
                existingText: existing?.structuredInteractionText,
                existingKind: existing?.structuredInteractionKind,
                candidateText: candidateMessage,
                candidateKind: .approval
            )
            if let sessionID = input.sessionID {
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    worklaneID: existing?.worklaneID ?? target.worklaneID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    text: message,
                    kind: .approval,
                    confidence: .explicit
                )
            }
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: message,
                    interactionKind: .approval,
                    confidence: .explicit,
                    sessionID: input.sessionID
                ),
            ]

        case "PreToolUse":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if input.toolName == "AskUserQuestion",
               let sessionID = input.sessionID,
               let prompt = describeAskUserQuestion(toolInput: input.toolInput) {
                let existing = try lookupRecord(for: input, sessionStore: sessionStore)
                let message = preferredStructuredInteractionText(
                    existingText: existing?.structuredInteractionText,
                    existingKind: existing?.structuredInteractionKind,
                    candidateText: prompt.text,
                    candidateKind: prompt.interactionKind
                )
                try sessionStore.rememberStructuredInteraction(
                    sessionID: sessionID,
                    worklaneID: existing?.worklaneID ?? target.worklaneID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    text: message ?? prompt.text,
                    kind: prompt.interactionKind,
                    confidence: .explicit
                )
                return [
                    lifecyclePayload(
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        state: .needsInput,
                        text: message,
                        interactionKind: prompt.interactionKind,
                        confidence: .explicit,
                        sessionID: input.sessionID
                    ),
                ]
            }
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let preToolExisting = try lookupRecord(for: input, sessionStore: sessionStore)
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .running,
                    text: nil,
                    cwd: input.cwd ?? preToolExisting?.cwd,
                    interactionKind: .none,
                    confidence: .explicit,
                    sessionID: input.sessionID
                ),
            ]

        case "UserPromptSubmit", "SubagentStart":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearInteractionContext(sessionID: sessionID)
            }
            let promptExisting = try lookupRecord(for: input, sessionStore: sessionStore)
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .running,
                    text: nil,
                    cwd: input.cwd ?? promptExisting?.cwd,
                    interactionKind: .none,
                    confidence: .explicit,
                    sessionID: input.sessionID
                ),
            ]

        case "Stop":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    text: nil,
                    lifecycleEvent: .stopCandidate,
                    confidence: .explicit,
                    sessionID: input.sessionID
                ),
            ]

        case "SubagentStop":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    text: nil,
                    lifecycleEvent: .update,
                    confidence: .explicit,
                    sessionID: input.sessionID
                ),
            ]

        case "SessionEnd":
            let current = currentTargetIfAvailable(from: environment)
            let record = try sessionStore.consume(
                sessionID: input.sessionID,
                fallbackWorklaneID: current?.worklaneID,
                fallbackPaneID: current?.paneID
            )
            guard let record else {
                return []
            }
            return [
                AgentStatusPayload(
                    worklaneID: record.worklaneID,
                    paneID: record.paneID,
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: AgentTool.claudeCode.displayName,
                    text: nil,
                    sessionID: record.sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                pidPayload(
                    worklaneID: record.worklaneID,
                    paneID: record.paneID,
                    pid: nil,
                    event: .clear,
                    sessionID: record.sessionID
                ),
            ]

        default:
            return []
        }
    }

    private static func currentTarget(from environment: [String: String]) throws -> (worklaneID: WorklaneID, paneID: PaneID) {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            throw AgentStatusPayloadError.missingWorklaneID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func currentTargetIfAvailable(from environment: [String: String]) -> (worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func resolvedTarget(
        for input: ClaudeHookInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> (worklaneID: WorklaneID, paneID: PaneID) {
        if let record = try lookupRecord(for: input, sessionStore: sessionStore) {
            return (record.worklaneID, record.paneID)
        }
        return try currentTarget(from: environment)
    }

    private static func lookupRecord(
        for input: ClaudeHookInput,
        sessionStore: ClaudeHookSessionStore
    ) throws -> ClaudeHookSessionRecord? {
        guard let sessionID = input.sessionID else {
            return nil
        }
        return try sessionStore.lookup(sessionID: sessionID)
    }

    private static func parseClaudePID(from environment: [String: String]) -> Int32? {
        guard let rawPID = environment["ZENTTY_CLAUDE_PID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    private static func lifecyclePayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: PaneAgentState?,
        text: String?,
        cwd: String? = nil,
        lifecycleEvent: AgentLifecycleEvent? = .update,
        interactionKind: PaneAgentInteractionKind? = nil,
        confidence: AgentSignalConfidence? = nil,
        sessionID: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.claudeCode.displayName,
            text: text,
            lifecycleEvent: lifecycleEvent,
            interactionKind: interactionKind,
            confidence: confidence,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    private static func pidPayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        pid: Int32?,
        event: AgentPIDSignalEvent,
        sessionID: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: event,
            origin: .explicitHook,
            toolName: AgentTool.claudeCode.displayName,
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private static func preferredStructuredInteractionText(
        existingText: String?,
        existingKind: PaneAgentInteractionKind?,
        candidateText: String,
        candidateKind: PaneAgentInteractionKind
    ) -> String {
        guard existingKind == candidateKind else {
            return candidateText
        }

        return AgentInteractionClassifier.preferredWaitingMessage(
            existing: existingText,
            candidate: candidateText
        ) ?? candidateText
    }

    private static func shouldReplaceStructuredInteractionText(
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

    private static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    private static func describeAskUserQuestion(toolInput: [String: Any]) -> (text: String, interactionKind: PaneAgentInteractionKind)? {
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

        guard !lines.isEmpty else {
            return nil
        }
        return (
            text: lines.joined(separator: "\n"),
            interactionKind: (options?.isEmpty == false) ? .decision : .question
        )
    }

    private static func extractCurrentWorkingDirectory(from object: [String: Any]) -> String? {
        firstString(in: object, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
