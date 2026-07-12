import Foundation
import os

private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")

/// Stale Codex state clearing after a shell prompt returns (pane exits
/// Codex back to a plain shell), plus the shell/non-Codex-prompt
/// predicates it alone relies on. Split out of
/// `CodexToolStatusResolver.swift` along its MARK sections.
extension CodexToolStatusResolver {
    // MARK: - Shell-return stale-state clearing

    func clearStaleStateAfterShellReturn(
        _ aux: inout PaneAuxiliaryState,
        paneID: PaneID,
        metadata: TerminalMetadata?,
        allowsNonCodexPromptFallback: Bool
    ) -> ShellReturnOutcome {
        var working = aux

        let hasActiveCodexStatus = working.agentStatus?.tool == .codex
            && working.agentStatus?.state != .idle
        let hasActiveCodexSession = working.agentReducerState.sessionsByID.values.contains { session in
            session.tool == .codex
                && (session.state != .idle || session.interactionKind.requiresHumanAttention)
        }
        let hasCodexSuppression = working.raw.codexInterruptSuppressionUntil != nil
        guard hasActiveCodexStatus || hasActiveCodexSession || hasCodexSuppression else {
            codexRestartLogger.notice(
                "shellReturn.skip noStaleCodex pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(working.agentStatus), privacy: .public) sessions=\(working.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(working.raw), privacy: .public)"
            )
            return ShellReturnOutcome()
        }
        let shouldClear = Self.metadataIndicatesShellReturnFromCodex(metadata)
            || (
                allowsNonCodexPromptFallback
                && (
                    Self.metadataIndicatesWeakCodexFallbackEnded(
                        metadata,
                        auxiliaryState: working
                    )
                    || (
                        Self.metadataIndicatesNonCodexPrompt(metadata)
                        && (hasActiveCodexStatus || hasActiveCodexSession)
                    )
                )
            )
        guard shouldClear else {
            return ShellReturnOutcome()
        }

        codexRestartLogger.notice(
            "shellReturn.clear pane=\(paneID.rawValue, privacy: .public) title=\(metadata?.title ?? "<nil>", privacy: .public) process=\(metadata?.processName ?? "<nil>", privacy: .public) status=\(WorklaneStore.codexRestartStatusDescription(working.agentStatus), privacy: .public) sessions=\(working.agentReducerState.sessionsByID.count, privacy: .public) suppression=\(WorklaneStore.codexRestartSuppressionDescription(working.raw), privacy: .public)"
        )
        _ = working.agentReducerState.clearCodexSessionsFromUserInterrupt()
        if working.agentStatus?.tool == .codex {
            working.agentStatus = nil
        }
        working.terminalProgress = nil
        working.raw.wantsReadyStatus = false
        working.raw.showsReadyStatus = false
        working.raw.codexCurrentRunHasObservedActivity = false
        working.raw.codexInterruptSuppressionUntil = nil
        working.raw.codexTitleIdleSuppressionUntil = nil
        working.raw.codexTranscriptContext = nil
        working.raw.lastDesktopNotificationText = nil
        working.raw.lastDesktopNotificationDate = nil
        aux = working
        return ShellReturnOutcome(didClear: true, cancelPendingQuestionTasks: true)
    }

    // MARK: - Static Codex predicates

    private static func metadataIndicatesShellReturnFromCodex(_ metadata: TerminalMetadata?) -> Bool {
        guard let metadata,
              AgentToolRecognizer.recognize(metadata: metadata) != .codex else {
            return false
        }

        if let processName = WorklaneContextFormatter.trimmed(metadata.processName),
           isKnownShellName(processName) {
            return true
        }

        if let title = WorklaneContextFormatter.trimmed(metadata.title),
           isKnownShellName(title) {
            return true
        }

        return false
    }

    private static func metadataIndicatesWeakCodexFallbackEnded(
        _ metadata: TerminalMetadata?,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard metadataIndicatesNonCodexPrompt(metadata),
              let status = auxiliaryState.agentStatus,
              status.tool == .codex else {
            return false
        }

        return status.origin == .shell
            || status.source == .inferred
            || auxiliaryState.shellActivityState == .promptIdle
    }

    private static func metadataIndicatesNonCodexPrompt(_ metadata: TerminalMetadata?) -> Bool {
        guard let metadata else {
            return false
        }

        return AgentToolRecognizer.recognize(metadata: metadata) != .codex
    }

    private static func isKnownShellName(_ value: String) -> Bool {
        let basename = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        switch basename {
        case "zsh", "bash", "fish", "sh", "pwsh", "nu":
            return true
        default:
            return false
        }
    }
}
