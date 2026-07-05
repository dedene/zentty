import Foundation

/// Passthrough rules for Pi-lineage CLIs (`pi`, `omp`) that inject Zentty status via `-e`.
enum PiFamilyLaunchPolicy {
    static let piPassthroughSubcommands: Set<String> = [
        "install", "remove", "uninstall", "update", "list", "config",
    ]

    static let piEarlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-v", "--list-models", "--export",
    ]

    /// Snapshot from `omp --help`, v16.3.6, 2026-07-05.
    static let ompPassthroughSubcommands: Set<String> = [
        "acp", "agents", "auth-broker", "auth-gateway", "bench", "commit", "completions",
        "config", "dry-balance", "gallery", "gc", "grep", "grievances", "install", "join",
        "models", "plugin", "read", "say", "search", "setup", "shell", "ssh", "stats",
        "tiny-models", "token", "ttsr", "update", "usage", "worktree",
    ]

    static let ompEarlyExitFlags: Set<String> = piEarlyExitFlags.union(["--alias"])

    // These are the global scope flags a user plausibly puts before a management
    // subcommand (`omp --profile work plugin list`); boolean/session flags
    // intentionally stop the scan because after them arguments are messages.
    private static let passthroughScopeFlags: Set<String> = ["--profile", "--cwd", "--config"]

    static func passthroughSubcommands(for tool: AgentBootstrapTool) -> Set<String>? {
        switch tool {
        case .pi: return piPassthroughSubcommands
        case .omp: return ompPassthroughSubcommands
        default: return nil
        }
    }

    static func passthroughSubcommand(in arguments: [String], for tool: AgentBootstrapTool) -> String? {
        guard let subcommands = passthroughSubcommands(for: tool),
              !subcommands.isEmpty else {
            return nil
        }

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]

            if passthroughScopeFlags.contains(argument) {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { return nil }
                index = arguments.index(after: index)
                continue
            }

            if passthroughScopeFlags.contains(where: { argument.hasPrefix($0 + "=") }) {
                index = arguments.index(after: index)
                continue
            }

            return subcommands.contains(argument) ? argument : nil
        }

        return nil
    }

    static func earlyExitFlags(for tool: AgentBootstrapTool) -> Set<String>? {
        switch tool {
        case .pi: return piEarlyExitFlags
        case .omp: return ompEarlyExitFlags
        default: return nil
        }
    }
}
