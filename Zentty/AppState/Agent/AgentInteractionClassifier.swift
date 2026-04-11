import Foundation

enum AgentInteractionClassifier {
    enum WaitingMessageSpecificity: Int, Comparable {
        case generic = 0
        case approval = 1
        case specific = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    static func requiresHumanInput(message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        let markers = [
            "waiting for your input",
            "waiting for input",
            "needs your input",
            "needs input",
            "needs your attention",
            "action required",
            "input-requested",
            "input requested",
            "approval-requested",
            "approval requested",
            "question requested",
            "questions requested",
            "plan-mode-prompt",
            "plan mode prompt",
            "permission",
            "approve",
            "approval",
            "allow ",
            "wants to edit",
            "confirm",
            "select ",
            "choose ",
            "grant access",
            "press enter",
            "log in",
            "login",
        ]

        if markers.contains(where: { message.contains($0) }) {
            return true
        }

        return looksLikeQuestionPrompt(message)
    }

    static func interactionKind(forWaitingMessage message: String?) -> PaneAgentInteractionKind? {
        guard let message = normalized(message) else {
            return nil
        }

        if message.contains("plan-mode-prompt") || message.contains("plan mode prompt") {
            return .approval
        }

        if message.contains("question requested") || message.contains("questions requested") {
            return .decision
        }

        if message.contains("log in") || message.contains("login") {
            return .auth
        }

        let approvalMarkers = [
            "action required",
            "approval-requested",
            "approval requested",
            "permission",
            "approve",
            "approval",
            "allow ",
            "grant access",
            "wants to edit",
        ]
        if approvalMarkers.contains(where: { message.contains($0) }) {
            return .approval
        }

        if looksLikeQuestionPrompt(message) {
            return containsDecisionOptions(message) ? .decision : .question
        }

        if requiresHumanInput(message: message) {
            return .genericInput
        }

        return nil
    }

    static func isGenericNeedsInputMessage(_ message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        return hasAnyPrefix(
            message,
            prefixes: [
                "claude needs your input",
                "claude is waiting for your input",
                "claude needs your attention",
            ]
        )
    }

    static func isGenericNeedsInputContent(_ message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        let markers = [
            "waiting for your input",
            "waiting for input",
            "needs your input",
            "needs input",
        ]
        return markers.contains { message.contains($0) }
    }

    static func isGenericApprovalMessage(_ message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        if message == "action required" {
            return true
        }

        return hasAnyPrefix(
            message,
            prefixes: [
                "claude needs your approval",
                "claude needs your permission",
                "gemini needs your approval",
                "gemini needs your permission",
                "approval needed",
                "permission required",
            ]
        )
    }

    static func specificity(forWaitingMessage message: String?) -> WaitingMessageSpecificity? {
        guard let normalized = normalized(message) else {
            return nil
        }

        if isGenericNeedsInputMessage(normalized) {
            return .generic
        }

        if isGenericApprovalMessage(normalized) {
            return .approval
        }

        if interactionKind(forWaitingMessage: normalized) != nil {
            return .specific
        }

        return nil
    }

    static func preferredWaitingMessage(existing: String?, candidate: String?) -> String? {
        let existingTrimmed = trimmed(existing)
        let candidateTrimmed = trimmed(candidate)

        guard let candidateTrimmed else {
            return existingTrimmed
        }
        guard let existingTrimmed else {
            return candidateTrimmed
        }

        let existingSpecificity = specificity(forWaitingMessage: existingTrimmed) ?? .generic
        let candidateSpecificity = specificity(forWaitingMessage: candidateTrimmed) ?? .generic

        if candidateSpecificity > existingSpecificity {
            return candidateTrimmed
        }

        return existingTrimmed
    }

    static func trimmed(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message
    }

    private static func normalized(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message.lowercased()
    }

    private static func hasAnyPrefix(_ message: String, prefixes: [String]) -> Bool {
        prefixes.contains { message.hasPrefix($0) }
    }

    private static func looksLikeQuestionPrompt(_ message: String) -> Bool {
        message.contains("?")
    }

    private static func containsDecisionOptions(_ message: String) -> Bool {
        if message.contains("[") && message.contains("]") {
            return true
        }

        return message.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dotIndex = trimmed.firstIndex(of: ".") else {
                return false
            }

            let prefix = trimmed[..<dotIndex]
            guard prefix.allSatisfy(\.isNumber) else {
                return false
            }

            let remainder = trimmed[trimmed.index(after: dotIndex)...].trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty == false
        }
    }
}
