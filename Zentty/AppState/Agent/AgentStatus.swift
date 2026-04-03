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

enum PaneAgentInteractionKind: String, Equatable, Sendable {
    case none
    case approval
    case question
    case decision
    case auth
    case genericInput = "generic-input"

    var requiresHumanAttention: Bool {
        self != .none
    }

    var statusLabel: String {
        switch self {
        case .none:
            return "Needs input"
        case .approval:
            return "Needs approval"
        case .question:
            return "Question"
        case .decision:
            return "Needs decision"
        case .auth:
            return "Needs sign-in"
        case .genericInput:
            return "Needs input"
        }
    }

    var symbolName: String? {
        switch self {
        case .none:
            return nil
        case .approval:
            return "checkmark.shield"
        case .question:
            return "questionmark.circle"
        case .decision:
            return "list.bullet"
        case .auth:
            return "key.fill"
        case .genericInput:
            return "ellipsis.circle"
        }
    }

    var priority: Int {
        switch self {
        case .approval:
            return 5
        case .question:
            return 4
        case .decision:
            return 3
        case .auth:
            return 2
        case .genericInput:
            return 1
        case .none:
            return 0
        }
    }
}

enum AgentSignalConfidence: String, Equatable, Sendable {
    case weak
    case strong
    case explicit

    var priority: Int {
        switch self {
        case .explicit:
            return 2
        case .strong:
            return 1
        case .weak:
            return 0
        }
    }
}

enum AgentLifecycleEvent: String, Equatable, Sendable {
    case update
    case stopCandidate = "stop-candidate"
}

enum PaneAgentState: String, Equatable, Sendable {
    case starting = "starting"
    case running = "running"
    case needsInput = "needs-input"
    case unresolvedStop = "unresolved-stop"
    case idle = "idle"

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
        case .idle:
            return "Idle"
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
        case .idle:
            return 1
        }
    }
}

enum PaneAgentStatusSource: Equatable, Sendable {
    case explicit
    case inferred
}

enum WorklaneAttentionState: String, Equatable, Sendable {
    case needsInput
    case unresolvedStop
    case ready
    case running
}

enum WorklaneArtifactKind: String, Equatable, Sendable {
    case pullRequest = "pull-request"
    case session
    case share
    case compare
    case generic
}

struct WorklaneArtifactLink: Equatable, Sendable {
    let kind: WorklaneArtifactKind
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
    var artifactLink: WorklaneArtifactLink?
    var updatedAt: Date
    var source: PaneAgentStatusSource
    var origin: AgentSignalOrigin
    var interactionState: PaneInteractionState
    var interactionKind: PaneAgentInteractionKind
    var confidence: AgentSignalConfidence
    var shellActivityState: PaneShellActivityState
    var trackedPID: Int32?
    var workingDirectory: String?
    var hasObservedRunning: Bool
    var sessionID: String?
    var parentSessionID: String?

    init(
        tool: AgentTool,
        state: PaneAgentState,
        text: String?,
        artifactLink: WorklaneArtifactLink?,
        updatedAt: Date,
        source: PaneAgentStatusSource = .explicit,
        origin: AgentSignalOrigin = .compatibility,
        interactionState: PaneInteractionState? = nil,
        interactionKind: PaneAgentInteractionKind? = nil,
        confidence: AgentSignalConfidence? = nil,
        shellActivityState: PaneShellActivityState = .unknown,
        trackedPID: Int32? = nil,
        workingDirectory: String? = nil,
        hasObservedRunning: Bool? = nil,
        sessionID: String? = nil,
        parentSessionID: String? = nil
    ) {
        self.tool = tool
        self.state = state
        self.text = text
        self.artifactLink = artifactLink
        self.updatedAt = updatedAt
        self.source = source
        self.origin = origin
        let resolvedInteractionKind = interactionKind ?? (state == .needsInput ? .genericInput : .none)
        self.interactionKind = resolvedInteractionKind
        self.interactionState = interactionState ?? (resolvedInteractionKind.requiresHumanAttention ? .awaitingHuman : .none)
        self.confidence = confidence ?? Self.defaultConfidence(for: origin)
        self.shellActivityState = shellActivityState
        self.trackedPID = trackedPID
        self.workingDirectory = workingDirectory
        self.hasObservedRunning = hasObservedRunning ?? Self.defaultHasObservedRunning(for: state)
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
    }

    init(
        tool: AgentTool,
        state: PaneAgentState,
        text: String?,
        artifactLink: WorklaneArtifactLink?,
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

    var statusLabel: String {
        if state == .needsInput {
            return interactionKind.statusLabel
        }

        return state.defaultStatusText
    }

    var statusSymbolName: String? {
        if state == .needsInput {
            return interactionKind.symbolName
        }

        return nil
    }

    private static func defaultConfidence(for origin: AgentSignalOrigin) -> AgentSignalConfidence {
        switch origin {
        case .explicitHook, .explicitAPI:
            return .explicit
        case .heuristic, .compatibility:
            return .strong
        case .shell, .inferred:
            return .weak
        }
    }

    private static func defaultHasObservedRunning(for state: PaneAgentState) -> Bool {
        switch state {
        case .running, .needsInput, .unresolvedStop:
            return true
        case .starting, .idle:
            return false
        }
    }
}

extension PaneAgentState {
    var worklaneAttentionState: WorklaneAttentionState? {
        switch self {
        case .starting:
            return nil
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .running:
            return .running
        case .idle:
            return nil
        }
    }
}

struct WorklaneAttentionSummary: Equatable, Sendable {
    let paneID: PaneID
    let tool: AgentTool
    let state: WorklaneAttentionState
    let interactionKind: PaneInteractionKind?
    let interactionLabel: String?
    let primaryText: String
    let statusText: String
    let contextText: String
    let artifactLink: WorklaneArtifactLink?
    let interactionSymbolName: String?
    let updatedAt: Date

    init(
        paneID: PaneID,
        tool: AgentTool,
        state: WorklaneAttentionState,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        primaryText: String,
        statusText: String,
        contextText: String,
        artifactLink: WorklaneArtifactLink?,
        interactionSymbolName: String? = nil,
        updatedAt: Date
    ) {
        self.paneID = paneID
        self.tool = tool
        self.state = state
        self.interactionKind = interactionKind
        self.interactionLabel = interactionLabel
        self.primaryText = primaryText
        self.statusText = statusText
        self.contextText = contextText
        self.artifactLink = artifactLink
        self.interactionSymbolName = interactionSymbolName
        self.updatedAt = updatedAt
    }

    var requiresHumanAttention: Bool {
        switch state {
        case .needsInput, .unresolvedStop:
            return true
        case .ready, .running:
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
