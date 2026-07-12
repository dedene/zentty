import Foundation

enum TerminalMetadataChangeKind: Equatable {
    case noop
    case volatileTitleOnly
    case meaningful
}

enum TerminalMetadataChangeClassifier {
    enum VolatileAgentStatusPhase: Equatable {
        case running
        case starting
        case needsInput
        case idle
    }

    enum CodexWaitingTitleKind: Equatable {
        case backgroundWait
        case needsInput
    }

    struct VolatileAgentStatusTitleSignature: Equatable {
        let phase: VolatileAgentStatusPhase
        let subject: String
    }

    private struct ParsedVolatileAgentStatusTitle: Equatable {
        let phase: VolatileAgentStatusPhase
        let displaySubject: String
    }

    static func classify(previous: TerminalMetadata?, next: TerminalMetadata) -> TerminalMetadataChangeKind {
        guard previous != next else {
            return .noop
        }

        guard let previous else {
            return .meaningful
        }

        guard previous.currentWorkingDirectory == next.currentWorkingDirectory,
              previous.processName == next.processName,
              previous.gitBranch == next.gitBranch else {
            return .meaningful
        }

        let previousTool = AgentToolRecognizer.recognize(metadata: previous)
        let nextTool = AgentToolRecognizer.recognize(metadata: next)
        guard previousTool == nextTool else {
            return .meaningful
        }

        if previousTool == .codex,
           codexTaskProgress(for: previous.title) != codexTaskProgress(for: next.title) {
            return .meaningful
        }

        if let previousSignature = realtimeAgentTitleSignature(
            previous.title,
            recognizedTool: previousTool
        ),
           let nextSignature = realtimeAgentTitleSignature(
            next.title,
            recognizedTool: nextTool
           ),
           previousSignature == nextSignature {
            return .volatileTitleOnly
        }

        return .meaningful
    }

    static func volatileAgentStatusTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        guard let rawNormalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }

        if recognizedTool == .hermes {
            return parseHermesStatusTitle(rawNormalized)
        }

        guard recognizedTool == .codex else {
            return nil
        }

        let normalized = stripTrailingCodexTaskProgress(from: rawNormalized)
        if let threadStatus = parseCodexThreadStatusTitle(normalized) {
            return VolatileAgentStatusTitleSignature(
                phase: .needsInput,
                subject: threadStatus.subject
            )
        }
        if let actionRequired = parseCodexActionRequiredTitle(normalized) {
            return VolatileAgentStatusTitleSignature(
                phase: .needsInput,
                subject: actionRequired.subject
            )
        }

        guard let parsed = parseAgentStatusTitle(
                  normalized,
                  runningWords: ["working", "thinking"],
                  startingWords: ["starting"],
                  needsInputWords: ["waiting"],
                  idleWords: ["ready"]
              ) else {
            return nil
        }

        let phase: VolatileAgentStatusPhase
        switch codexWaitingTitleKind(for: rawNormalized) {
        case .backgroundWait:
            phase = .idle
        case .needsInput:
            phase = .needsInput
        case nil:
            phase = parsed.phase
        }

        return VolatileAgentStatusTitleSignature(
            phase: phase,
            subject: parsed.displaySubject.lowercased()
        )
    }

    static func volatileAgentStatusDisplaySubject(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> String? {
        guard recognizedTool == .codex,
              let rawNormalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }
        let normalized = stripTrailingCodexTaskProgress(from: rawNormalized)
        guard let parsed = parseAgentStatusTitle(
                  normalized,
                  runningWords: ["working", "thinking"],
                  startingWords: ["starting"],
                  needsInputWords: ["waiting"],
                  idleWords: ["ready"]
              ) else {
            return nil
        }

        guard parsed.displaySubject.caseInsensitiveCompare("zentty") != .orderedSame else {
            return nil
        }

        return parsed.displaySubject
    }

    static func diagnosticAgentStatusTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        guard let normalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }

        switch recognizedTool {
        case .codex:
            return volatileAgentStatusTitleSignature(normalized, recognizedTool: .codex)
        case .claudeCode:
            // Claude Code 2.x encodes status in the title glyph: "✳" (U+2733)
            // on the idle prompt, braille spinner glyphs (U+2800…U+28FF) while
            // the agent is thinking. After a user interrupt (Escape) the
            // spinner is replaced by "✳", with the subject left intact — this
            // is what lets us detect the interrupt when no Stop hook fires.
            if let signature = parseClaudeCodeGlyphTitle(normalized) {
                return signature
            }

            // Fallback: older Claude Code builds used English words
            // ("Thinking …", "Interrupted · …") as the title prefix. Keep
            // detection for those so downgrades stay covered.
            guard let parsed = parseAgentStatusTitle(
                normalized,
                runningWords: ["thinking", "working", "responding", "analyzing"],
                startingWords: ["starting"],
                idleWords: ["ready", "waiting", "interrupted"]
            ) else {
                return nil
            }

            return VolatileAgentStatusTitleSignature(
                phase: parsed.phase,
                subject: parsed.displaySubject.lowercased()
            )
        default:
            return nil
        }
    }

    static func realtimeAgentTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        switch recognizedTool {
        case .codex:
            return volatileAgentStatusTitleSignature(value, recognizedTool: .codex)
        case .hermes:
            return volatileAgentStatusTitleSignature(value, recognizedTool: .hermes)
        case .claudeCode:
            return diagnosticAgentStatusTitleSignature(value, recognizedTool: .claudeCode)
        default:
            return nil
        }
    }

    static func wouldTreatAsVolatileClaudeTransition(
        previous: TerminalMetadata?,
        next: TerminalMetadata
    ) -> Bool {
        guard let previous else {
            return false
        }

        let previousTool = AgentToolRecognizer.recognize(metadata: previous)
        let nextTool = AgentToolRecognizer.recognize(metadata: next)
        guard previousTool == .claudeCode, nextTool == .claudeCode else {
            return false
        }

        guard previous.title != next.title else {
            return false
        }

        return diagnosticAgentStatusTitleSignature(previous.title, recognizedTool: previousTool)
            == diagnosticAgentStatusTitleSignature(next.title, recognizedTool: nextTool)
    }

    static func isVolatileAgentStatusTitle(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> Bool {
        volatileAgentStatusTitleSignature(value, recognizedTool: recognizedTool) != nil
    }

    static func isRealtimeAgentStatusTitle(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> Bool {
        realtimeAgentTitleSignature(value, recognizedTool: recognizedTool) != nil
    }

    static func codexWaitingTitleKind(for value: String?) -> CodexWaitingTitleKind? {
        guard let rawNormalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }
        let normalized = stripTrailingCodexTaskProgress(from: rawNormalized)

        let firstWord = normalized.prefix(while: { $0.isLetter }).lowercased()
        guard firstWord == "waiting" else {
            return nil
        }

        if AgentInteractionClassifier.requiresHumanInput(message: normalized) {
            return .needsInput
        }

        return .backgroundWait
    }

    static func codexTitleInteractionKind(for value: String?) -> PaneAgentInteractionKind? {
        guard let rawNormalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }
        let normalized = stripTrailingCodexTaskProgress(from: rawNormalized)

        if let threadStatus = parseCodexThreadStatusTitle(normalized) {
            return threadStatus.interactionKind
        }
        if let actionRequired = parseCodexActionRequiredTitle(normalized) {
            return actionRequired.interactionKind
        }

        guard codexWaitingTitleKind(for: rawNormalized) == .needsInput else {
            return nil
        }

        return AgentInteractionClassifier.interactionKind(forWaitingMessage: normalized)
            ?? .genericInput
    }

    static func codexTaskProgress(for value: String?) -> PaneAgentTaskProgress? {
        guard let normalized = WorklaneContextFormatter.trimmed(value),
              let (_, progress) = splitTrailingCodexTaskProgress(from: normalized) else {
            return nil
        }

        return progress
    }

    private static func parseClaudeCodeGlyphTitle(
        _ normalized: String
    ) -> VolatileAgentStatusTitleSignature? {
        guard let first = normalized.unicodeScalars.first else {
            return nil
        }

        let phase: VolatileAgentStatusPhase
        switch first.value {
        case 0x2733:
            phase = .idle
        case 0x2800...0x28FF:
            phase = .running
        default:
            return nil
        }

        let remainder = normalized
            .dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }

        return VolatileAgentStatusTitleSignature(
            phase: phase,
            subject: remainder.lowercased()
        )
    }

    private static func parseCodexThreadStatusTitle(
        _ normalized: String
    ) -> (subject: String, interactionKind: PaneAgentInteractionKind)? {
        let words = normalized
            .split(whereSeparator: { !$0.isLetter })
            .prefix(3)
            .map { String($0).lowercased() }
        guard words.count == 3,
              ["main", "parent"].contains(words[0]),
              words[1] == "needs" else {
            return nil
        }

        let interactionKind: PaneAgentInteractionKind
        switch words[2] {
        case "approval":
            return nil
        case "input":
            interactionKind = .genericInput
        default:
            return nil
        }

        return (normalized.lowercased(), interactionKind)
    }

    private static func parseCodexActionRequiredTitle(
        _ normalized: String
    ) -> (subject: String, interactionKind: PaneAgentInteractionKind)? {
        let stripped = stripCodexTitleBadge(from: normalized)
        let actionRequiredPrefix = "action required"
        guard stripped.lowercased().hasPrefix(actionRequiredPrefix) else {
            return nil
        }

        return (stripped.lowercased(), .genericInput)
    }

    private static func stripCodexTitleBadge(from value: String) -> String {
        var remainder = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.hasPrefix("["),
              let closingIndex = remainder.firstIndex(of: "]") else {
            return remainder
        }
        let badge = remainder[remainder.index(after: remainder.startIndex)..<closingIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard badge == "!" || badge == "." else {
            return remainder
        }
        remainder = String(remainder[remainder.index(after: closingIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder
    }

    private static func parseAgentStatusTitle(
        _ normalized: String,
        runningWords: Set<String>,
        startingWords: Set<String>,
        needsInputWords: Set<String> = [],
        idleWords: Set<String>
    ) -> ParsedVolatileAgentStatusTitle? {
        let firstWord = normalized.prefix(while: { $0.isLetter }).lowercased()
        let phase: VolatileAgentStatusPhase
        if runningWords.contains(firstWord) {
            phase = .running
        } else if startingWords.contains(firstWord) {
            phase = .starting
        } else if needsInputWords.contains(firstWord) {
            phase = .needsInput
        } else if idleWords.contains(firstWord) {
            phase = .idle
        } else {
            return nil
        }

        var remainder = normalized.dropFirst(firstWord.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }

        if let firstToken = remainder.split(whereSeparator: \.isWhitespace).first,
           firstToken.contains(where: \.isLetter) == false,
           firstToken.contains(where: \.isNumber) == false {
            remainder = remainder.dropFirst(firstToken.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !remainder.isEmpty else {
            return nil
        }

        return ParsedVolatileAgentStatusTitle(
            phase: phase,
            displaySubject: remainder
        )
    }

    private static func parseHermesStatusTitle(
        _ normalized: String
    ) -> VolatileAgentStatusTitleSignature? {
        guard let firstCharacter = normalized.first,
              let firstScalar = firstCharacter.unicodeScalars.first else {
            return nil
        }

        let phase: VolatileAgentStatusPhase
        switch firstScalar.value {
        case 0x23F3: // ⏳
            phase = .running
        case 0x2713: // ✓
            phase = .idle
        case 0x26A0: // ⚠ / ⚠️
            phase = .needsInput
        default:
            return nil
        }

        let subject = normalized.dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            return nil
        }

        return VolatileAgentStatusTitleSignature(
            phase: phase,
            subject: subject.lowercased()
        )
    }

    private static func stripTrailingCodexTaskProgress(from value: String) -> String {
        splitTrailingCodexTaskProgress(from: value)?.title ?? value
    }

    private static func splitTrailingCodexTaskProgress(
        from value: String
    ) -> (title: String, progress: PaneAgentTaskProgress)? {
        guard let tasksRange = value.range(of: " | Tasks ", options: .backwards) else {
            return nil
        }

        let title = value[..<tasksRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let progressValue = value[tasksRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = progressValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let doneCount = Int(parts[0]),
              let totalCount = Int(parts[1]),
              let progress = PaneAgentTaskProgress(doneCount: doneCount, totalCount: totalCount),
              !title.isEmpty else {
            return nil
        }

        return (title: title, progress: progress)
    }
}
