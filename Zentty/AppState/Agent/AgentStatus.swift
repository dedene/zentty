import Foundation

enum AgentTool: Equatable, Sendable {
    case zentty
    case amp
    case claudeCode
    case codex
    case copilot
    case cursor
    case droid
    case gemini
    case kimi
    case openCode
    case pi
    case grok
    case agy
    case hermes
    case vibe
    case smallHarness
    case custom(String)

    var displayName: String {
        switch self {
        case .zentty:
            return "Zentty"
        case .amp:
            return "Amp"
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .droid:
            return "Droid"
        case .gemini:
            return "Gemini"
        case .kimi:
            return "Kimi"
        case .openCode:
            return "OpenCode"
        case .pi:
            return "Pi"
        case .grok:
            return "Grok"
        case .agy:
            return "Antigravity"
        case .hermes:
            return "Hermes Agent"
        case .vibe:
            return "Mistral Vibe"
        case .smallHarness:
            return "Small Harness"
        case .custom(let name):
            return name
        }
    }

    static func resolve(named rawName: String?) -> AgentTool? {
        guard let normalized = normalized(rawName) else {
            return nil
        }

        if let tool = resolveKnownTool(named: normalized, includeHookDrivenOnly: true) {
            return tool
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

        return resolveKnownTool(named: normalized, includeHookDrivenOnly: false)
    }

    private static func resolveKnownTool(named normalized: String, includeHookDrivenOnly: Bool) -> AgentTool? {
        for matcher in knownToolMatchers {
            guard includeHookDrivenOnly || !matcher.isHookDrivenOnly else { continue }
            if matcher.matches(normalized) {
                return matcher.tool
            }
        }
        return nil
    }

    private struct ToolNameMatcher: Sendable {
        let tool: AgentTool
        let isHookDrivenOnly: Bool
        let match: Match

        func matches(_ normalized: String) -> Bool {
            switch match {
            case .contains(let needle):
                return normalized.contains(needle)
            case .containsAny(let needles):
                return needles.contains { normalized.contains($0) }
            case .leadingToken(let tokens):
                return matchesLeadingToken(normalized, tokens: tokens)
            case .pi:
                return matchesPi(normalized)
            }
        }
    }

    private enum Match: Sendable {
        case contains(String)
        case containsAny([String])
        case leadingToken([String])
        case pi
    }

    private static let knownToolMatchers: [ToolNameMatcher] = [
        ToolNameMatcher(tool: .amp, isHookDrivenOnly: false, match: .leadingToken(["amp"])),
        ToolNameMatcher(tool: .claudeCode, isHookDrivenOnly: false, match: .contains("claude")),
        ToolNameMatcher(tool: .codex, isHookDrivenOnly: false, match: .contains("codex")),
        // Keep hook-driven-only tools out of metadata recognition so generic
        // terminal-progress fallback still shows Running when hooks are absent.
        ToolNameMatcher(tool: .copilot, isHookDrivenOnly: true, match: .contains("copilot")),
        ToolNameMatcher(tool: .cursor, isHookDrivenOnly: true, match: .contains("cursor")),
        ToolNameMatcher(tool: .droid, isHookDrivenOnly: false, match: .contains("droid")),
        ToolNameMatcher(tool: .gemini, isHookDrivenOnly: false, match: .contains("gemini")),
        ToolNameMatcher(tool: .kimi, isHookDrivenOnly: false, match: .contains("kimi")),
        ToolNameMatcher(tool: .openCode, isHookDrivenOnly: false, match: .containsAny(["opencode", "open code"])),
        ToolNameMatcher(tool: .pi, isHookDrivenOnly: false, match: .pi),
        ToolNameMatcher(tool: .grok, isHookDrivenOnly: false, match: .leadingToken(["grok", "grok-build"])),
        ToolNameMatcher(tool: .agy, isHookDrivenOnly: false, match: .leadingToken(["agy", "antigravity"])),
        ToolNameMatcher(tool: .hermes, isHookDrivenOnly: false, match: .leadingToken(["hermes"])),
        // "Mistral Vibe" normalizes to "mistral vibe" (leading token "mistral");
        // the bare binary surfaces as "vibe". Match both leading tokens.
        ToolNameMatcher(tool: .vibe, isHookDrivenOnly: false, match: .leadingToken(["vibe", "mistral"])),
        ToolNameMatcher(tool: .smallHarness, isHookDrivenOnly: false, match: .containsAny(["small-harness", "small harness", "smallharness"])),
    ]

    private static func matchesPi(_ normalized: String) -> Bool {
        // Pi's binary name is short ("pi") and its titlebar extension uses
        // the Greek letter π, sometimes prefixed with a braille spinner
        // frame (e.g. "⠋ π - cwd"). Split on whitespace and require an
        // exact token match so "pip", "pizza", "apipie", "pi.py" etc.
        // don't get caught.
        for token in normalized.split(separator: " ") {
            if token == "pi" || token == "π" { return true }
        }
        return false
    }

    private static func matchesLeadingToken(_ normalized: String, tokens expectedTokens: [String]) -> Bool {
        guard let token = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first else {
            return false
        }
        return expectedTokens.contains(String(token))
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
            return "Requires approval"
        case .question:
            return "Needs decision"
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
            return "list.bullet"
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
    case toolActivity = "tool-activity"
    case turnComplete = "turn-complete"
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

struct PaneAgentTaskProgress: Equatable, Sendable {
    let doneCount: Int
    let totalCount: Int

    init?(doneCount: Int, totalCount: Int) {
        guard totalCount > 0 else {
            return nil
        }

        self.totalCount = totalCount
        self.doneCount = min(max(doneCount, 0), totalCount)
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
    var agentLaunchSnapshot: AgentLaunchSnapshot?
    var taskProgress: PaneAgentTaskProgress?

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
        parentSessionID: String? = nil,
        agentLaunchSnapshot: AgentLaunchSnapshot? = nil,
        taskProgress: PaneAgentTaskProgress? = nil
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
        self.agentLaunchSnapshot = agentLaunchSnapshot
        self.taskProgress = taskProgress
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
    let taskProgress: PaneAgentTaskProgress?
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
        taskProgress: PaneAgentTaskProgress? = nil,
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
        self.taskProgress = taskProgress
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
        let processTool = AgentTool.resolveKnown(named: metadata?.processName)
        if processTool == .hermes {
            return .hermes
        }

        return AgentTool.resolveKnown(named: metadata?.title)
            ?? processTool
            ?? codexFromVolatileTitle(metadata?.title)
    }

    private static func codexFromVolatileTitle(_ title: String?) -> AgentTool? {
        guard let title,
              let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                  title,
                  recognizedTool: .codex
              ) else {
            return nil
        }

        if containsCodexSpinner(in: title) {
            return .codex
        }

        if TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: title) != nil {
            return .codex
        }

        if signature.phase == .idle,
           title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("ready") {
            return .codex
        }

        return nil
    }

    private static func containsCodexSpinner(in title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            scalar.value >= 0x2800 && scalar.value <= 0x28FF
        }
    }
}
