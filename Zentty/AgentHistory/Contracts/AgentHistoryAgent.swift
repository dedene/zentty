import Foundation

/// The agents whose on-disk history Agent History indexes.
enum AgentHistoryAgent: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case grok
    case opencode

    /// Maps a running pane's tool to its history agent; every other tool is nil.
    init?(tool: AgentTool) {
        switch tool {
        case .claudeCode:
            self = .claude
        case .codex:
            self = .codex
        case .grok:
            self = .grok
        case .openCode:
            self = .opencode
        default:
            return nil
        }
    }

    var agentTool: AgentTool {
        switch self {
        case .claude:
            return .claudeCode
        case .codex:
            return .codex
        case .grok:
            return .grok
        case .opencode:
            return .openCode
        }
    }

    var displayName: String { agentTool.displayName }

    /// The canonical `native_id` for a raw session id, or nil when it is not a safe id for this
    /// agent. Used at ingest and for live pane ids, so both sides key sessions the same way.
    func normalizedSessionID(_ raw: String) -> String? {
        switch self {
        case .claude:
            return AgentResumeCommandBuilder.validatedClaudeSessionID(from: raw)
        case .codex:
            return AgentResumeCommandBuilder.validatedCodexSessionID(from: raw)
        case .grok:
            return AgentResumeCommandBuilder.validatedGrokSessionID(from: raw)
        case .opencode:
            return AgentResumeCommandBuilder.validatedOpenCodeSessionID(from: raw)
        }
    }
}

/// Identifies one session across the index, tombstones and live panes. `nativeID` is normalized.
struct AgentHistorySessionKey: Hashable, Codable, Sendable {
    let agent: AgentHistoryAgent
    let nativeID: String
}

enum AgentHistoryTitleKind: String, Codable, Sendable, Comparable {
    case firstPrompt = "first_prompt"
    case generated
    case custom

    var rank: Int {
        switch self {
        case .firstPrompt:
            return 1
        case .generated:
            return 2
        case .custom:
            return 3
        }
    }

    static func < (lhs: AgentHistoryTitleKind, rhs: AgentHistoryTitleKind) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum AgentHistoryRole: String, Codable, Sendable {
    case user
    case agent
}

enum AgentHistoryArtifactKind: String, Codable, CaseIterable, Sendable {
    case path
    case command
    case commit
    case pr
}
