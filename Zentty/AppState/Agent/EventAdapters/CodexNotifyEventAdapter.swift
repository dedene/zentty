import Foundation

// MARK: - Codex Notify Adapter

extension AgentEventBridge {
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

// MARK: - Adapter conformance

enum CodexNotifyEventAdapter: AgentEventAdapting {
    static let adapterName = "codex-notify"
    static let suppressesErrors = false
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.codexNotifyAdapter(data: data, environment: environment)
    }
}
