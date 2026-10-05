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

    /// Synthetic hook event the wrapper sends before it execs
    /// `claude attach <id>`, so the app can move the session to this pane.
    static let attachEventName = "ZenttyAttach"

    /// `claude attach <id>` opens a background session in this terminal. The
    /// client takes neither `--session-id` nor `--settings` and fires no hooks
    /// of its own, so it launches as given, with or without a usable id.
    static func isAttach(_ arguments: [String]) -> Bool {
        arguments.first == "attach"
    }

    /// The session id (usually its 8-character short form) named by
    /// `claude attach <id>`.
    static func attachedSessionID(in arguments: [String]) -> String? {
        guard isAttach(arguments), arguments.count >= 2 else {
            return nil
        }
        let id = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count >= minimumAttachIDLength, !id.hasPrefix("-") else {
            return nil
        }
        return id
    }

    /// Shorter prefixes could match an unrelated session.
    static let minimumAttachIDLength = 8
}
