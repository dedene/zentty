import Foundation

/// A validated, ready-to-run resume command for one history session.
struct AgentHistoryResumePlan: Equatable, Sendable {
    var agent: AgentHistoryAgent
    /// The normalized native session id the command resumes.
    var sessionID: String
    /// A shell command line: base resume command and allowlisted flags. Claude sessions from an
    /// alternate root get an `env CLAUDE_CONFIG_DIR=…` prefix; sessions from the default
    /// `~/.claude` get `env -u CLAUDE_CONFIG_DIR`, so an exported value can't redirect them.
    var command: String
    /// Extra session environment. Always empty in v1; the alternate Claude root travels as an
    /// `env` prefix in `command` instead (D3).
    var environment: [String: String]

    /// The text placed on the pasteboard by "Copy Resume Command": `cd <dir> && <command>` when the
    /// directory is known, else the bare command.
    func copyText(workingDirectory: String?) -> String {
        guard let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return command
        }
        return "cd \(AgentResumeCommandBuilder.shellQuotedArgument(directory)) && \(command)"
    }
}

enum AgentHistoryResumeAvailability: Equatable, Sendable {
    case available(AgentHistoryResumePlan)
    case unavailable(reason: String)
}

/// Builds resume commands for history sessions. Session ids go through the same validators as pane
/// restore; model and effort metadata only ever become a fixed per-agent flag, with values matched
/// against an allowlist. Nothing here can add a permission, approval, sandbox or profile flag.
enum AgentHistoryResumeCommandBuilder {
    static let invalidSessionIDReason = "This session's ID can't be resumed safely."
    static let unsafeCommandReason = "This session can't be resumed safely."

    /// Arguments that must never appear in a resume command. Entries ending in a space match a
    /// whole argument (`-a`, `-p`); every other entry matches as a case-insensitive substring.
    static let forbiddenFlagTokens: [String] = [
        "--dangerously", "--permission-mode", "--allow-dangerously", "bypass", "--yolo", "--full-auto",
        "--sandbox", "-a ", "--ask-for-approval", "approval_policy", "sandbox_mode", "--settings",
        "--config-dir", "-p ", "--profile", "CODEX_HOME", "GROK_HOME",
    ]

    private static let modelPattern = #"^[A-Za-z0-9][A-Za-z0-9._:@+/\[\]-]{0,127}$"#
    private static let openCodeModelPattern = #"^[^/]+/.+$"#

    static func availability(
        for source: AgentHistoryResumeSource,
        homeDirectory: String = NSHomeDirectory()
    ) -> AgentHistoryResumeAvailability {
        let agent = source.agent
        // A nil id must never fall through to an id-less resume (e.g. Grok's bare `grok --resume`).
        guard let sessionID = agent.normalizedSessionID(source.nativeSessionID) else {
            return .unavailable(reason: invalidSessionIDReason)
        }
        let draft = PaneRestoreDraft(
            paneID: "",
            kind: .agentResume,
            toolName: agent.agentTool.displayName,
            sessionID: sessionID,
            workingDirectory: source.workingDirectory,
            trackedPID: 0
        )
        guard let base = AgentResumeCommandBuilder.command(for: draft) else {
            return .unavailable(reason: invalidSessionIDReason)
        }

        let flags = flagArguments(
            agent: agent,
            model: source.model,
            effort: source.effort,
            generation: source.generation
        )
        var configDirectory: String?
        var unsetsConfigDirectory = false
        if agent == .claude {
            configDirectory = claudeConfigDirectoryOverride(sourceRoot: source.sourceRoot, homeDirectory: homeDirectory)
            unsetsConfigDirectory = configDirectory == nil
                && isDefaultClaudeRoot(sourceRoot: source.sourceRoot, homeDirectory: homeDirectory)
        }

        let baseArguments = base.split(separator: " ").map(String.init)
        var checked = baseArguments + flags
        if let configDirectory {
            checked.append(configDirectory)
        }
        guard !checked.contains(where: isForbiddenArgument(_:)) else {
            return .unavailable(reason: unsafeCommandReason)
        }

        var command = ([base] + flags.map(AgentResumeCommandBuilder.shellQuotedArgument(_:))).joined(separator: " ")
        if let configDirectory {
            command = "env CLAUDE_CONFIG_DIR=\(AgentResumeCommandBuilder.shellQuotedArgument(configDirectory)) \(command)"
        } else if unsetsConfigDirectory {
            // The pane's shell may export CLAUDE_CONFIG_DIR for another root; a bare `claude` would
            // look there and miss this session. Unset it rather than pointing it at `~/.claude`,
            // which would also move where Claude reads `.claude.json`.
            command = "env -u CLAUDE_CONFIG_DIR \(command)"
        }
        return .available(AgentHistoryResumePlan(
            agent: agent,
            sessionID: sessionID,
            command: command,
            environment: [:]
        ))
    }

    static func command(for source: AgentHistoryResumeSource) -> String? {
        guard case .available(let plan) = availability(for: source) else {
            return nil
        }
        return plan.command
    }

    /// Unquoted argv tokens for the model and effort flags (see the R4 table). Invalid or
    /// non-allowlisted values are dropped silently.
    static func flagArguments(
        agent: AgentHistoryAgent,
        model: String?,
        effort: String?,
        generation: String?
    ) -> [String] {
        let model = validatedModel(model, for: agent)
        let effort = validatedEffort(effort, for: agent)
        var arguments: [String] = []
        switch agent {
        case .claude:
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
        case .codex:
            if let model { arguments += ["-m", model] }
            if let effort { arguments += ["-c", "model_reasoning_effort=\(effort)"] }
        case .grok:
            if let model { arguments += ["-m", model] }
            if let effort { arguments += ["--reasoning-effort", effort] }
        case .opencode:
            // Only the v1 CLI's `--model provider/model` is known; v2 and unknown get no flags (V2).
            let isV1 = generation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "v1"
            if isV1, let model { arguments += ["--model", model] }
        }
        return arguments
    }

    static func validatedModel(_ raw: String?, for agent: AgentHistoryAgent) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !containsControlCharacter(value),
              value.range(of: modelPattern, options: .regularExpression) != nil,
              !isForbiddenArgument(value) else {
            return nil
        }
        if agent == .opencode, value.range(of: openCodeModelPattern, options: .regularExpression) == nil {
            return nil
        }
        return value
    }

    static func validatedEffort(_ raw: String?, for agent: AgentHistoryAgent) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        return effortAllowlist(for: agent).contains(value) ? value : nil
    }

    /// The standardized `sourceRoot` when it is an alternate Claude config root, else nil. Never
    /// returns the default `<home>/.claude`, including through a symlink.
    static func claudeConfigDirectoryOverride(sourceRoot: String?, homeDirectory: String) -> String? {
        guard let standardized = standardizedClaudeRoot(sourceRoot),
              !isDefaultClaudeRoot(standardized: standardized, homeDirectory: homeDirectory) else {
            return nil
        }
        return standardized
    }

    /// True when `sourceRoot` is the default `<home>/.claude`, including through a symlink. A nil or
    /// unusable root is not the default: nothing is known about it.
    static func isDefaultClaudeRoot(sourceRoot: String?, homeDirectory: String) -> Bool {
        guard let standardized = standardizedClaudeRoot(sourceRoot) else {
            return false
        }
        return isDefaultClaudeRoot(standardized: standardized, homeDirectory: homeDirectory)
    }

    private static func standardizedClaudeRoot(_ sourceRoot: String?) -> String? {
        guard let root = sourceRoot, root.hasPrefix("/"), !containsControlCharacter(root) else {
            return nil
        }
        let standardized = (root as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else {
            return nil
        }
        return standardized
    }

    private static func isDefaultClaudeRoot(standardized: String, homeDirectory: String) -> Bool {
        let defaultRoot = ((homeDirectory as NSString).appendingPathComponent(".claude") as NSString).standardizingPath
        return standardized == defaultRoot
            || (standardized as NSString).resolvingSymlinksInPath == (defaultRoot as NSString).resolvingSymlinksInPath
    }

    /// True when `argument` matches any `forbiddenFlagTokens` entry.
    static func isForbiddenArgument(_ argument: String) -> Bool {
        let lowered = argument.lowercased()
        return forbiddenFlagTokens.contains { token in
            if token.hasSuffix(" ") {
                return lowered == token.trimmingCharacters(in: .whitespaces).lowercased()
            }
            return lowered.contains(token.lowercased())
        }
    }

    private static func effortAllowlist(for agent: AgentHistoryAgent) -> Set<String> {
        switch agent {
        case .claude:
            return ["low", "medium", "high", "xhigh", "max"]
        case .codex:
            return ["none", "minimal", "low", "medium", "high", "xhigh"]
        case .grok:
            return ["low", "medium", "high"]
        case .opencode:
            return []
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
