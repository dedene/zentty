import Foundation

/// The environment that puts a process "inside tmux" as far as tmux-based
/// tools can tell, with the bundled `tmux` shim first on `PATH`. Shared by
/// the app (Agent Teams injection into new panes) and the CLI
/// (`zentty launch --teams` / `--tmux-shim`).
enum TmuxShimEnvironment {
    /// Set to `1` in shim-mode processes. Shell integrations keep the shim
    /// directory first on `PATH` while it is set, and panes the shim creates
    /// inherit the shim environment.
    static let markerKey = "ZENTTY_TMUX_SHIM"
    static let shimDirectoryKey = "ZENTTY_TMUX_SHIM_DIR"
    static let tracePathKey = "ZENTTY_TMUX_COMPAT_TRACE_PATH"
    static let claudeAgentTeamsKey = "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
    /// Comma-separated names a tool set with `-e NAME=VALUE` on a pane the
    /// shim created, so saved workspaces leave them out.
    static let toolAssignedKeysKey = "ZENTTY_TMUX_SHIM_ASSIGNED_ENV"

    /// Keys a shim-mode process carries. `TMUX_PANE` is per pane; the rest
    /// are copied into panes the shim creates.
    static let inheritedKeys = ["TMUX", markerKey, shimDirectoryKey, tracePathKey]

    /// A socket-shaped path for `$TMUX` and `#{socket_path}`. Nothing listens
    /// on it: routing goes through the Zentty IPC socket. It only has to be
    /// absolute, stable for the app run and short enough for tools that check
    /// the Unix socket length limit.
    static func socketPath(instanceID: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let raw = (instanceID ?? "").unicodeScalars.filter { allowed.contains($0) }
        let suffix = String(String.UnicodeScalarView(raw).prefix(12))
        return "/tmp/zentty-tmux/\(suffix.isEmpty ? "default" : suffix)"
    }

    /// `$TMUX` is `socket,server-pid,session-number`; tools split on commas and
    /// expect a numeric pid.
    static func tmuxValue(socketPath: String, serverPID: Int32, sessionNumber: Int) -> String {
        "\(socketPath),\(serverPID),\(sessionNumber)"
    }

    static func paneValue(paneNumber: Int) -> String {
        "%\(paneNumber)"
    }

    /// Writes the shim variables into `environment`, prepending the shim
    /// directory to `PATH` once.
    static func apply(
        to environment: inout [String: String],
        shimDirectory: String,
        tmux: String,
        tmuxPane: String,
        tracePath: String?,
        fallbackPath: String? = nil
    ) {
        environment[shimDirectoryKey] = shimDirectory
        environment[markerKey] = "1"
        environment["TMUX"] = tmux
        environment["TMUX_PANE"] = tmuxPane
        if let tracePath, !tracePath.isEmpty {
            environment[tracePathKey] = tracePath
        }
        let currentPath = environment["PATH"] ?? fallbackPath ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = prependingShim(shimDirectory, to: currentPath)
    }

    static func prependingShim(_ shimDirectory: String, to path: String) -> String {
        let entries = path.split(separator: ":").map(String.init).filter { $0 != shimDirectory }
        return ([shimDirectory] + entries).joined(separator: ":")
    }

    // MARK: - zentty launch --teams / --tmux-shim

    /// The calling pane's tmux identity as the app reports it.
    struct Identity: Equatable {
        let socketPath: String
        let serverPID: Int32
        let sessionNumber: Int
        let paneID: String
    }

    /// Asked of the app with `display-message -p` before a shim launch.
    static let identityFormat = "#{socket_path}\t#{pid}\t#{session_id}\t#{pane_id}"

    static func parseIdentity(_ output: String) -> Identity? {
        let fields = output.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard fields.count == 4,
              fields[0].hasPrefix("/"),
              let pid = Int32(fields[1]), pid > 0,
              fields[2].hasPrefix("$"), let session = Int(fields[2].dropFirst()),
              fields[3].hasPrefix("%"), Int(fields[3].dropFirst()) != nil
        else {
            return nil
        }
        return Identity(socketPath: fields[0], serverPID: pid, sessionNumber: session, paneID: fields[3])
    }

    /// `base` with the shim environment for `identity` applied. Agent-team
    /// launches of Claude Code also switch its team mode on.
    static func launchEnvironment(
        base: [String: String],
        shimDirectory: String,
        identity: Identity,
        enableClaudeAgentTeams: Bool
    ) -> [String: String] {
        var environment = base
        apply(
            to: &environment,
            shimDirectory: shimDirectory,
            tmux: tmuxValue(
                socketPath: identity.socketPath,
                serverPID: identity.serverPID,
                sessionNumber: identity.sessionNumber
            ),
            tmuxPane: identity.paneID,
            tracePath: base[tracePathKey]
        )
        if enableClaudeAgentTeams {
            environment[claudeAgentTeamsKey] = "1"
        }
        return environment
    }

    enum LaunchMode: Equatable {
        /// An integrated agent, launched through its Zentty bootstrap.
        case agent(tool: String, arguments: [String])
        /// Any command, run directly; empty means the login shell.
        case command([String])
    }

    struct LaunchPlan: Equatable {
        let mode: LaunchMode
        /// Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`: for `--teams claude`,
        /// and for `--tmux-shim --teams` (an orchestrator that starts Claude).
        let enablesClaudeAgentTeams: Bool
    }

    /// Reads `zentty launch` flags. `--teams` goes before the tool or as the
    /// first argument after it (`zentty launch claude --teams`); anything
    /// later belongs to the tool. Returns nil when neither flag is in play.
    static func launchPlan(
        command: [String],
        teams: Bool,
        tmuxShim: Bool
    ) -> LaunchPlan? {
        var command = command
        if command.first == "--" {
            command.removeFirst()
        }
        var teams = teams
        if command.count > 1, command[1] == "--teams" {
            teams = true
            command.remove(at: 1)
        }
        if tmuxShim {
            return LaunchPlan(mode: .command(command), enablesClaudeAgentTeams: teams)
        }
        guard teams, let tool = command.first else {
            return nil
        }
        return LaunchPlan(
            mode: .agent(tool: tool, arguments: Array(command.dropFirst())),
            enablesClaudeAgentTeams: tool == "claude"
        )
    }

    static func toolAssignedKeys(in environment: [String: String]) -> Set<String> {
        guard let list = environment[toolAssignedKeysKey], !list.isEmpty else {
            return []
        }
        return Set(list.split(separator: ",").map(String.init))
    }

    /// tmux `-e NAME=VALUE` arguments as a dictionary; malformed entries are
    /// dropped like tmux does.
    static func environmentAssignments(_ values: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                continue
            }
            result[String(value[..<equals])] = String(value[value.index(after: equals)...])
        }
        return result
    }
}
