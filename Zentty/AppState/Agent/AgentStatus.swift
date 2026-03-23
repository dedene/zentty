import Foundation

enum AgentTool: Equatable, Sendable {
    case claudeCode
    case codex
    case openCode
    case custom(String)

    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .openCode:
            return "OpenCode"
        case .custom(let name):
            return name
        }
    }

    static func resolve(named rawName: String?) -> AgentTool? {
        guard let normalized = normalized(rawName) else {
            return nil
        }

        if normalized.contains("claude") {
            return .claudeCode
        }
        if normalized.contains("codex") {
            return .codex
        }
        if normalized.contains("opencode") || normalized.contains("open code") {
            return .openCode
        }

        guard let rawName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return nil
        }

        return .custom(rawName)
    }

    static func resolveKnown(named rawName: String?) -> AgentTool? {
        guard let normalized = normalized(rawName) else {
            return nil
        }

        if normalized.contains("claude") {
            return .claudeCode
        }
        if normalized.contains("codex") {
            return .codex
        }
        if normalized.contains("opencode") || normalized.contains("open code") {
            return .openCode
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}

enum AgentSignalOrigin: String, Equatable, Sendable {
    case compatibility
    case explicitHook = "explicit-hook"
    case explicitAPI = "explicit-api"
    case heuristic
    case shell
    case inferred

    var priority: Int {
        switch self {
        case .explicitHook, .explicitAPI:
            return 4
        case .heuristic:
            return 3
        case .compatibility:
            return 2
        case .shell:
            return 1
        case .inferred:
            return 0
        }
    }
}

enum PaneShellActivityState: String, Equatable, Sendable {
    case unknown
    case promptIdle = "prompt-idle"
    case commandRunning = "command-running"
}

enum PaneInteractionState: String, Equatable, Sendable {
    case none
    case awaitingHuman = "awaiting-human"
}

enum PaneAgentState: String, Equatable, Sendable {
    case starting = "starting"
    case running = "running"
    case needsInput = "needs-input"
    case unresolvedStop = "unresolved-stop"
    case completed = "completed"

    var defaultStatusText: String {
        switch self {
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .needsInput:
            return "Needs input"
        case .unresolvedStop:
            return "Stopped early"
        case .completed:
            return "Completed"
        }
    }

    var attentionPriority: Int {
        switch self {
        case .starting:
            return 0
        case .needsInput:
            return 4
        case .unresolvedStop:
            return 3
        case .running:
            return 2
        case .completed:
            return 1
        }
    }
}

enum PaneAgentStatusSource: Equatable, Sendable {
    case explicit
    case inferred
}

enum WorkspaceAttentionState: String, Equatable, Sendable {
    case needsInput
    case unresolvedStop
    case running
    case completed
}

enum WorkspaceArtifactKind: String, Equatable, Sendable {
    case pullRequest = "pull-request"
    case session
    case share
    case compare
    case generic
}

struct WorkspaceArtifactLink: Equatable, Sendable {
    let kind: WorkspaceArtifactKind
    let label: String
    let url: URL
    let isExplicit: Bool

    var priority: Int {
        switch (isExplicit, kind) {
        case (true, .pullRequest):
            return 3
        case (true, _):
            return 2
        case (false, .pullRequest):
            return 1
        default:
            return 0
        }
    }
}

struct PaneAgentStatus: Equatable, Sendable {
    let tool: AgentTool
    var state: PaneAgentState
    var text: String?
    var artifactLink: WorkspaceArtifactLink?
    var updatedAt: Date
    var source: PaneAgentStatusSource
    var origin: AgentSignalOrigin
    var interactionState: PaneInteractionState
    var shellActivityState: PaneShellActivityState
    var trackedPID: Int32?

    init(
        tool: AgentTool,
        state: PaneAgentState,
        text: String?,
        artifactLink: WorkspaceArtifactLink?,
        updatedAt: Date,
        source: PaneAgentStatusSource = .explicit,
        origin: AgentSignalOrigin = .compatibility,
        interactionState: PaneInteractionState? = nil,
        shellActivityState: PaneShellActivityState = .unknown,
        trackedPID: Int32? = nil
    ) {
        self.tool = tool
        self.state = state
        self.text = text
        self.artifactLink = artifactLink
        self.updatedAt = updatedAt
        self.source = source
        self.origin = origin
        self.interactionState = interactionState ?? (state == .needsInput ? .awaitingHuman : .none)
        self.shellActivityState = shellActivityState
        self.trackedPID = trackedPID
    }

    init(
        tool: AgentTool,
        state: PaneAgentState,
        text: String?,
        artifactLink: WorkspaceArtifactLink?,
        updatedAt: Date
    ) {
        self.init(
            tool: tool,
            state: state,
            text: text,
            artifactLink: artifactLink,
            updatedAt: updatedAt,
            source: .explicit,
            origin: .compatibility
        )
    }

    var statusText: String {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText?.isEmpty == false ? trimmedText! : state.defaultStatusText
    }

    var requiresHumanAttention: Bool {
        interactionState == .awaitingHuman
    }
}

extension PaneAgentState {
    var workspaceAttentionState: WorkspaceAttentionState? {
        switch self {
        case .starting:
            return nil
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .running:
            return .running
        case .completed:
            return .completed
        }
    }
}

struct WorkspaceAttentionSummary: Equatable, Sendable {
    let paneID: PaneID
    let tool: AgentTool
    let state: WorkspaceAttentionState
    let primaryText: String
    let statusText: String
    let contextText: String
    let artifactLink: WorkspaceArtifactLink?
    let updatedAt: Date

    var requiresHumanAttention: Bool {
        switch state {
        case .needsInput, .unresolvedStop:
            return true
        case .running, .completed:
            return false
        }
    }
}

enum AgentToolRecognizer {
    static func recognize(metadata: TerminalMetadata?) -> AgentTool? {
        AgentTool.resolveKnown(named: metadata?.title)
            ?? AgentTool.resolveKnown(named: metadata?.processName)
    }
}
