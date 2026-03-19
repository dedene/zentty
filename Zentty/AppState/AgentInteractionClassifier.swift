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
            "needs your input",
            "needs your attention",
            "permission",
            "approve",
            "approval",
            "allow ",
            "confirm",
            "select ",
            "choose ",
            "grant access",
            "press enter",
            "log in",
            "login",
        ]

        return markers.contains { message.contains($0) }
    }

    static func isGenericNeedsInputMessage(_ message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        return [
            "claude needs your input",
            "claude is waiting for your input",
            "claude needs your attention",
        ].contains(message)
    }

    static func specificity(forWaitingMessage message: String?) -> WaitingMessageSpecificity? {
        guard let normalized = normalized(message) else {
            return nil
        }

        if isGenericNeedsInputMessage(normalized) {
            return .generic
        }

        let approvalMarkers = [
            "permission",
            "approve",
            "approval",
            "allow ",
            "grant access",
        ]
        if approvalMarkers.contains(where: normalized.contains) {
            return .approval
        }

        if requiresHumanInput(message: normalized) {
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
}
