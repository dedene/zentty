import Foundation

/// One live subagent spawned by an agent session (Claude `Agent` tool, Codex
/// `spawn_agent`, Grok `spawn_subagent`, …).
struct PaneAgentSubagentEntry: Codable, Equatable, Hashable, Sendable {
    /// Stable id for the subagent lifetime (`agent_id`, sub-thread id, or the
    /// transcript path when the agent CLI provides nothing better).
    let id: String
    /// Agent kind as the CLI names it: `general-purpose`, `Explore`, `worker`, `guardian`, …
    let agentType: String?
    /// Raw model id as reported by the agent CLI (`claude-opus-5`, `gpt-6-astra`).
    let model: String?
    /// Codex assigns a nickname per spawned thread (`Noether`, `Dirac`).
    let nickname: String?
    /// Subagent transcript / rollout on disk, used to resolve the model lazily.
    let transcriptPath: String?

    init(id: String, agentType: String? = nil, model: String? = nil, nickname: String? = nil, transcriptPath: String? = nil) {
        self.id = id
        self.agentType = agentType
        self.model = model
        self.nickname = nickname
        self.transcriptPath = transcriptPath
    }

    func with(model: String?, nickname: String? = nil) -> PaneAgentSubagentEntry {
        PaneAgentSubagentEntry(
            id: id,
            agentType: agentType,
            model: model ?? self.model,
            nickname: nickname ?? self.nickname,
            transcriptPath: transcriptPath
        )
    }

    /// Short model label for the sidebar (`opus`, `astra`, `auto-review`).
    var modelLabel: String? {
        model.flatMap(AgentModelLabel.short(from:))
    }
}

/// Rows of the expanded subagent list: `2 × opus  general-purpose`.
struct PaneAgentSubagentGroup: Equatable, Sendable {
    let count: Int
    let modelLabel: String?
    let agentType: String?
    let nicknames: [String]

    var leadingText: String {
        "\(count) ×"
    }

    var modelText: String {
        modelLabel ?? "model?"
    }

    var trailingText: String? {
        let parts = [agentType, nicknames.isEmpty ? nil : nicknames.joined(separator: ", ")]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Authoritative snapshot of the subagents currently running under a pane's
/// agent session. An empty summary is a deliberate "none running" signal, so
/// payload consumers can distinguish it from `nil` ("unchanged").
struct PaneAgentSubagentSummary: Equatable, Sendable {
    let entries: [PaneAgentSubagentEntry]

    static let empty = PaneAgentSubagentSummary(entries: [])

    init(entries: [PaneAgentSubagentEntry]) {
        self.entries = entries.sorted { $0.id < $1.id }
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Entries grouped by (model label, agent type), most numerous first, with a
    /// stable alphabetical tie-break so the expanded list does not jitter.
    var groups: [PaneAgentSubagentGroup] {
        struct Key: Hashable {
            let modelLabel: String?
            let agentType: String?
        }
        var counts: [Key: (count: Int, nicknames: [String])] = [:]
        for entry in entries {
            let key = Key(modelLabel: entry.modelLabel, agentType: entry.agentType)
            var bucket = counts[key] ?? (0, [])
            bucket.count += 1
            if let nickname = entry.nickname, !nickname.isEmpty {
                bucket.nicknames.append(nickname)
            }
            counts[key] = bucket
        }
        return counts
            .map { key, value in
                PaneAgentSubagentGroup(
                    count: value.count,
                    modelLabel: key.modelLabel,
                    agentType: key.agentType,
                    nicknames: value.nicknames.sorted()
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.modelText != rhs.modelText { return lhs.modelText < rhs.modelText }
                return (lhs.agentType ?? "") < (rhs.agentType ?? "")
            }
    }

    var badgeText: String {
        String(count)
    }

    var tooltipText: String {
        let noun = count == 1 ? "subagent" : "subagents"
        return "\(count) \(noun)\nClick for details"
    }

    var accessibilityText: String {
        let noun = count == 1 ? "subagent" : "subagents"
        return "\(count) \(noun)"
    }

    // MARK: - Transport

    /// JSON array encoding used on the IPC / notification transport.
    var transportJSON: String? {
        guard let data = try? JSONEncoder.subagentTransport.encode(entries) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    init?(transportJSON: String?) {
        guard let transportJSON, let data = transportJSON.data(using: .utf8),
              let entries = try? JSONDecoder().decode([PaneAgentSubagentEntry].self, from: data) else {
            return nil
        }
        self.init(entries: entries)
    }
}

private extension JSONEncoder {
    static let subagentTransport: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

/// Turns raw model ids into the short names people use in conversation.
enum AgentModelLabel {
    /// `claude-opus-5` → `opus`, `claude-fable-5-1` → `fable`, `sonnet[1m]` → `sonnet`,
    /// `gpt-6-astra` → `astra`, `gpt-5.6-sol` → `sol`, `codex-auto-review` → `auto-review`,
    /// `gpt-5.5` → `gpt-5.5` (nothing to shorten), `gpt-5.4-mini` → `gpt-5.4-mini`.
    static func short(from rawModel: String) -> String? {
        var value = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        // Bedrock / Vertex style prefixes and context-window suffixes.
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let bracket = value.firstIndex(of: "[") {
            value = String(value[..<bracket])
        }
        if let claudeRange = value.range(of: "claude-") {
            value = String(value[claudeRange.lowerBound...])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !value.isEmpty else { return nil }

        let tokens = value.split(separator: "-").map(String.init)
        guard tokens.count > 1 else { return value }

        if tokens.first == "claude" {
            // First purely alphabetic token after the vendor prefix is the family.
            return tokens.dropFirst().first(where: isAlphabetic) ?? value
        }

        if tokens.first == "codex" {
            return tokens.dropFirst().joined(separator: "-")
        }

        // OpenAI style: `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.3-codex-spark`.
        // Everything after the version token forms the codename; a lone
        // generic size word (`mini`, `nano`) is not a codename.
        if let versionIndex = tokens.firstIndex(where: isVersion) {
            let codename = Array(tokens[(versionIndex + 1)...])
            if codename.isEmpty || codename.contains(where: { !isAlphabetic($0) }) {
                return value
            }
            if codename.count == 1, genericSizeWords.contains(codename[0]) {
                return value
            }
            return codename.joined(separator: "-")
        }

        return value
    }

    private static let genericSizeWords: Set<String> = ["mini", "nano", "small", "medium", "large", "pro", "max", "lite"]

    private static func isAlphabetic(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isLetter)
    }

    private static func isVersion(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber || $0 == "." } && token.contains(where: \.isNumber)
    }
}
