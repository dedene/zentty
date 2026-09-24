import Foundation

/// Passthrough rules for `claude` subcommands that must launch without the
/// injected `--session-id` / `--settings` hooks plan. Shared by the app-side
/// bootstrap and the CLI launcher so both sides skip the same verbs.
enum ClaudeLaunchPolicy {
    /// `remote-control` (alias `rc`) refuses to start when `--settings`
    /// precedes the verb, because it can't carry it over to the sessions it
    /// spawns.
    static let passthroughSubcommands: Set<String> = [
        "mcp", "config", "api-key", "remote-control", "rc",
    ]

    static func passthroughSubcommand(in arguments: [String]) -> String? {
        guard let subcommand = arguments.first, passthroughSubcommands.contains(subcommand) else {
            return nil
        }
        return subcommand
    }
}
