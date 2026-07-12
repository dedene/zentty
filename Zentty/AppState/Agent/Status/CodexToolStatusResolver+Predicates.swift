import Foundation

/// Shared static Codex status/title predicates used across both the
/// running-title and idle-title reconciliation paths (hence `internal`,
/// not `private`: the split forces cross-file visibility). Split out of
/// `CodexToolStatusResolver.swift`'s "Static Codex predicates" MARK
/// section.
extension CodexToolStatusResolver {
    static func readyTitleMayClearStatus(_ status: PaneAgentStatus?) -> Bool {
        guard let status else {
            return true
        }

        guard status.state == .needsInput else {
            return true
        }

        return statusMayClearFromReadyTitle(status)
    }

    static func runningTitleMayClearBlockedStatus(
        _ status: PaneAgentStatus,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind.requiresHumanAttention else {
            return false
        }

        if auxiliaryState.terminalProgress?.state.indicatesActivity == true {
            return true
        }

        switch status.origin {
        case .explicitHook, .explicitAPI:
            return status.interactionKind == .approval
                || statusIsStalePlanModePrompt(status)
        case .heuristic, .inferred, .compatibility, .shell:
            return statusIsStalePlanModePrompt(status)
        }
    }

    static func statusShouldBlockTitleDrivenResume(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.interactionKind.requiresHumanAttention else {
            return false
        }

        return !statusIsStaleGenericNeedsInput(status)
            && !statusIsStalePlanModePrompt(status)
    }

    static func statusIsStalePlanModePrompt(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              let text = AgentInteractionClassifier.trimmed(status.text) else {
            return false
        }

        let lowered = text.lowercased()
        guard lowered.contains("plan-mode-prompt") || lowered.contains("plan mode prompt") else {
            return false
        }

        switch status.origin {
        case .heuristic, .inferred, .compatibility, .explicitAPI:
            return true
        case .explicitHook, .shell:
            return false
        }
    }

    static func statusIsStaleGenericNeedsInput(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind == .genericInput else {
            return false
        }

        switch status.origin {
        case .heuristic:
            return true
        case .inferred, .compatibility:
            guard let text = AgentInteractionClassifier.trimmed(status.text) else {
                return false
            }
            let lowered = text.lowercased()
            return lowered.contains("waiting for your input")
                || TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: text) != nil
                || TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: text) == .needsInput
                || TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                    text,
                    recognizedTool: .codex
                )?.phase == .needsInput
        case .explicitAPI, .explicitHook, .shell:
            return false
        }
    }

    static func statusMayClearFromReadyTitle(_ status: PaneAgentStatus) -> Bool {
        guard status.tool == .codex,
              status.state == .needsInput,
              status.interactionKind == .genericInput else {
            return false
        }

        if statusIsStaleGenericNeedsInput(status) {
            return true
        }

        guard status.confidence == .weak else {
            return false
        }

        switch status.origin {
        case .heuristic, .inferred, .compatibility:
            return true
        case .explicitAPI, .explicitHook, .shell:
            return false
        }
    }

    static func previousMetadataCanBeStaleCodexRunningTail(_ previousMetadata: TerminalMetadata?) -> Bool {
        guard let previousMetadata else {
            return true
        }

        return AgentToolRecognizer.recognize(metadata: previousMetadata) == .codex
    }
}
