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
    case running = "running"
    case needsInput = "needs-input"
    case unresolvedStop = "unresolved-stop"
    case completed = "completed"

    var defaultStatusText: String {
        switch self {
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

enum WorkspaceContextFormatter {
    static func contextText(for metadata: TerminalMetadata?) -> String {
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap { compactDirectoryName($0) }
        let branch = displayBranch(metadata?.gitBranch)
        return [compactDirectory, branch]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    static func displayWorkingDirectory(for metadata: TerminalMetadata?) -> String? {
        resolvedWorkingDirectory(for: metadata).flatMap(homeRelativePath)
    }

    static func resolvedWorkingDirectory(for metadata: TerminalMetadata?) -> String? {
        normalizedWorkingDirectoryCandidate(metadata?.currentWorkingDirectory)
            ?? inferredWorkingDirectory(fromTitle: metadata?.title)
    }

    static func homeRelativePath(_ path: String) -> String? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        if trimmedPath == homePath {
            return "~"
        }

        guard trimmedPath.hasPrefix(homePath + "/") else {
            return trimmedPath
        }

        return "~/" + trimmedPath.dropFirst(homePath.count + 1)
    }

    static func compactSidebarPath(
        _ path: String,
        minimumSegments: Int = 1
    ) -> String? {
        guard let components = sidebarPathComponents(path) else {
            return nil
        }

        guard components != ["~"] else {
            return "~"
        }

        if let worktreeLabel = worktreeSidebarPathLabel(path) {
            return worktreeLabel
        }

        let clampedSegmentCount = min(
            max(1, minimumSegments),
            components.count
        )
        return components.suffix(clampedSegmentCount).joined(separator: "/")
    }

    static func maxSidebarPathSegments(_ path: String) -> Int? {
        guard let components = sidebarPathComponents(path) else {
            return nil
        }

        if worktreeSidebarPathLabel(path) != nil {
            return 2
        }

        return components == ["~"] ? 1 : components.count
    }

    static func compactDirectoryName(
        _ path: String,
        minimumSegments: Int = 1
    ) -> String? {
        compactSidebarPath(path, minimumSegments: minimumSegments).flatMap { compactPath in
            guard compactPath != "~" else {
                return "~"
            }

            guard minimumSegments > 1 else {
                return compactPath.split(separator: "/").last.map(String.init)
            }

            return compactPath
        }
    }

    static func paneDetailLine(
        metadata: TerminalMetadata?,
        fallbackTitle: String?,
        minimumPathSegments: Int = 1
    ) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap {
            compactDirectoryName($0, minimumSegments: minimumPathSegments)
        }
        let fallback = meaningfulSidebarDetailRole(
            metadata: metadata,
            fallbackTitle: fallbackTitle
        )

        if let branch, let compactDirectory {
            return "\(branch) • \(compactDirectory)"
        }

        if let branch {
            return branch
        }

        if let fallback, let compactDirectory {
            return "\(fallback) • \(compactDirectory)"
        }

        return compactDirectory ?? fallback
    }

    static func singlePaneSidebarDetailLine(metadata: TerminalMetadata?) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap {
            compactDirectoryName($0)
        }

        if let branch, let compactDirectory {
            return "\(branch) • \(compactDirectory)"
        }

        return branch
    }

    static func normalizeSidebarFallbackTitle(_ title: String?) -> String? {
        guard let normalized = trimmed(title) else {
            return nil
        }

        if normalized.range(of: #"^pane \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }

        if normalized.caseInsensitiveCompare("shell") == .orderedSame {
            return nil
        }

        if normalized.caseInsensitiveCompare("split") == .orderedSame {
            return nil
        }

        if normalized.caseInsensitiveCompare("git") == .orderedSame {
            return "git"
        }

        return normalized
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    static func displayBranch(_ value: String?) -> String? {
        guard let value = trimmed(value), !looksCompactedForDisplay(value) else {
            return nil
        }

        return value
    }

    static func looksCompactedForDisplay(_ value: String?) -> Bool {
        guard let value = trimmed(value) else {
            return false
        }

        return value.contains("...") || value.contains("…")
    }

    private static func meaningfulSidebarRole(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> String? {
        normalizeSidebarFallbackTitle(metadata?.title)
            ?? normalizeSidebarFallbackTitle(metadata?.processName)
            ?? normalizeSidebarFallbackTitle(fallbackTitle)
    }

    private static func meaningfulSidebarDetailRole(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> String? {
        guard let role = meaningfulSidebarRole(
            metadata: metadata,
            fallbackTitle: fallbackTitle
        ) else {
            return nil
        }

        switch role.lowercased() {
        case "zsh", "bash", "fish", "sh":
            return nil
        default:
            return role
        }
    }

    private static func sidebarPathComponents(_ path: String) -> [String]? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = trimmedPath.hasPrefix(homePath)
            ? trimmedPath.replacingOccurrences(of: homePath, with: "~")
            : trimmedPath

        guard normalizedPath != "~" else {
            return ["~"]
        }

        let components = normalizedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard components.isEmpty == false else {
            return nil
        }

        return components
    }

    private static func worktreeSidebarPathLabel(_ path: String) -> String? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = trimmedPath.hasPrefix(homePath)
            ? trimmedPath.replacingOccurrences(of: homePath, with: "~")
            : trimmedPath
        let components = normalizedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let worktreesIndex = components.firstIndex(of: "worktrees"),
              worktreesIndex + 2 < components.count else {
            return nil
        }

        return components[(worktreesIndex + 1)...(worktreesIndex + 2)].joined(separator: "/")
    }

    private static func inferredWorkingDirectory(fromTitle title: String?) -> String? {
        guard let trimmedTitle = trimmed(title) else {
            return nil
        }

        var candidates = [trimmedTitle]
        candidates.append(contentsOf: trimmedTitle.split(separator: ":").reversed().map(String.init))
        return candidates.lazy.compactMap(normalizedWorkingDirectoryCandidate).first
    }

    private static func normalizedWorkingDirectoryCandidate(_ candidate: String?) -> String? {
        guard let trimmedCandidate = trimmed(candidate) else {
            return nil
        }

        if trimmedCandidate == "~" {
            return NSHomeDirectory()
        }

        if trimmedCandidate.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(trimmedCandidate.dropFirst(2)))
        }

        guard trimmedCandidate.hasPrefix("/") else {
            return nil
        }

        return trimmedCandidate
    }
}
