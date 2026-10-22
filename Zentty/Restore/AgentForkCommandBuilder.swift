import Foundation

/// What a fork needs from the source pane's agent session.
struct AgentForkSource: Equatable, Sendable {
    var tool: AgentTool
    var sessionID: String?
    var workingDirectory: String?
}

/// A ready-to-run fork: the command typed at the new pane's shell prompt
/// (so the Zentty agent wrapper on `PATH` launches it, exactly like a manual
/// launch) and the directory the new pane starts in.
struct AgentForkPlan: Equatable, Sendable {
    var tool: AgentTool
    var command: String
    var workingDirectory: String
}

enum AgentForkAvailability: Equatable, Sendable {
    case available(AgentForkPlan)
    case unavailable(reason: String)

    var plan: AgentForkPlan? {
        if case .available(let plan) = self {
            return plan
        }
        return nil
    }

    var isAvailable: Bool {
        plan != nil
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self {
            return reason
        }
        return nil
    }
}

/// Per-agent fork commands. Only agents whose CLI has a real fork flag or
/// subcommand are listed; every other agent is not forkable. Session ids go
/// through the same validators as `AgentResumeCommandBuilder`.
enum AgentForkCommandBuilder {
    static let noAgentReason = "No agent is running in this pane."
    static let remotePaneReason = "Forking isn't available in remote panes."

    /// Availability for a live pane. `nil` when no agent runs in it.
    static func availability(
        pane: PaneState,
        auxiliary: PaneAuxiliaryState?
    ) -> AgentForkAvailability? {
        guard let auxiliary, let agent = forkableAgent(in: auxiliary) else {
            return nil
        }
        guard auxiliary.shellContext?.scope != .remote else {
            return .unavailable(reason: remotePaneReason)
        }

        let source = AgentForkSource(
            tool: agent.tool,
            sessionID: agent.sessionID,
            workingDirectory: SessionRestoreDraftExporter.workingDirectory(
                agentStatus: auxiliary.agentStatus,
                auxiliary: auxiliary,
                pane: pane,
                restoredDraft: nil
            )
        )
        return availability(for: source)
    }

    static func availability(for source: AgentForkSource) -> AgentForkAvailability {
        let toolName = source.tool.displayName
        guard supportsFork(source.tool) else {
            return .unavailable(reason: "\(toolName) can't fork a conversation.")
        }
        guard let rawSessionID = trimmed(source.sessionID),
              !SessionRestoreDraftExporter.isPlaceholderSessionID(rawSessionID, for: source.tool) else {
            return .unavailable(reason: "\(toolName) hasn't reported a session ID yet.")
        }
        guard let workingDirectory = trimmed(source.workingDirectory) else {
            return .unavailable(reason: "The agent's working directory is unknown.")
        }
        guard let command = command(
            for: source.tool,
            sessionID: rawSessionID,
            workingDirectory: workingDirectory
        ) else {
            return .unavailable(reason: "\(toolName) reported a session ID that can't be forked.")
        }
        return .available(AgentForkPlan(
            tool: source.tool,
            command: command,
            workingDirectory: workingDirectory
        ))
    }

    static func supportsFork(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claudeCode, .codex, .openCode, .droid, .grok, .pi:
            return true
        case .custom(let name):
            return manifestFork(displayName: name) != nil
        default:
            return false
        }
    }

    /// The fork command for a session, or nil when the tool has no fork
    /// support or the id fails validation.
    static func command(
        for tool: AgentTool,
        sessionID rawSessionID: String,
        workingDirectory: String? = nil
    ) -> String? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case .claudeCode:
            return AgentResumeCommandBuilder.validatedClaudeSessionID(from: sessionID)
                .map { "claude --resume \(quoted($0)) --fork-session" }
        case .codex:
            return AgentResumeCommandBuilder.validatedCodexSessionID(from: sessionID)
                .map { "codex fork \(quoted($0))" }
        case .openCode:
            return AgentResumeCommandBuilder.validatedOpenCodeSessionID(from: sessionID)
                .map { "opencode --session \(quoted($0)) --fork" }
        case .droid:
            return AgentResumeCommandBuilder.validatedDroidSessionID(from: sessionID)
                .map { "droid --fork \(quoted($0))" }
        case .grok:
            return AgentResumeCommandBuilder.validatedGrokSessionID(from: sessionID)
                .map { "grok --resume \(quoted($0)) --fork-session" }
        case .pi:
            // Pi accepts a full or partial session UUID; only full UUIDs are
            // taken so a fragment can't match the wrong conversation.
            return UUID(uuidString: sessionID)
                .map { "pi --fork \(quoted($0.uuidString.lowercased()))" }
        case .custom(let name):
            guard let fork = manifestFork(displayName: name) else {
                return nil
            }
            return manifestForkCommand(fork: fork, sessionID: sessionID, workingDirectory: workingDirectory)
        default:
            return nil
        }
    }

    /// Title for the forked pane. Only a user-set title is carried over;
    /// without one the new pane keeps default naming and the agent's own
    /// title. Forking a fork keeps a single " (fork)" suffix.
    static func forkedPaneTitle(sourceCustomTitle: String?) -> String? {
        guard let title = trimmed(sourceCustomTitle) else {
            return nil
        }
        let suffix = " (fork)"
        return title.hasSuffix(suffix) ? title : title + suffix
    }

    /// The visible agent, or else the newest root session the reducer still
    /// tracks with a live PID. The sidebar badge hides an idle agent after
    /// `idleVisibilityWindow`, but the agent stays forkable while it runs.
    private static func forkableAgent(
        in auxiliary: PaneAuxiliaryState
    ) -> (tool: AgentTool, sessionID: String?)? {
        if let agentStatus = auxiliary.agentStatus {
            return (agentStatus.tool, agentStatus.sessionID)
        }
        return auxiliary.agentReducerState.sessionsByID.values
            .filter { $0.trackedPID != nil && $0.parentSessionID == nil }
            .max { $0.updatedAt < $1.updatedAt }
            .map { ($0.tool, $0.sessionID) }
    }

    private static func manifestFork(displayName: String) -> AgentManifest.Resume? {
        guard let fork = AgentManifestRegistry.provider().manifest(displayName: displayName)?.fork,
              fork.command.contains("{sessionId}") else {
            return nil
        }
        return fork
    }

    private static func manifestForkCommand(
        fork: AgentManifest.Resume,
        sessionID: String,
        workingDirectory: String?
    ) -> String? {
        guard let validatedSessionID = AgentResumeCommandBuilder.validatedManifestSessionID(
            sessionID,
            pattern: fork.sessionIdPattern
        ) else {
            return nil
        }
        var command = fork.command.replacingOccurrences(
            of: "{sessionId}",
            with: quoted(validatedSessionID)
        )
        if command.contains("{workingDirectory}") {
            guard let workingDirectory = trimmed(workingDirectory) else {
                return nil
            }
            command = command.replacingOccurrences(
                of: "{workingDirectory}",
                with: quoted(workingDirectory)
            )
        }
        return command
    }

    private static func quoted(_ argument: String) -> String {
        AgentResumeCommandBuilder.shellQuotedArgument(argument)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
