import Foundation

/// Passthrough rules for `claude` subcommands that must launch without the
/// injected `--session-id` / `--settings` hooks plan. Shared by the app-side
/// bootstrap and the CLI launcher so both sides skip the same verbs.
enum ClaudeLaunchPolicy {
    /// Management verbs: the hooks plan buys them nothing, and several break
    /// once options precede them (dedene/zentty#141):
    /// - `remote-control` (alias `rc`) refuses to start when `--settings`
    ///   precedes the verb, because it can't carry it over to the sessions it
    ///   spawns. `plugin test` refuses any option before `plugin`.
    /// - The background-session verbs (`logs`, `respawn`, `rm`, `stop`/`kill`)
    ///   are only recognised as the first argument; behind the injected flags
    ///   Claude reads them as a prompt and starts a new session instead.
    ///
    /// `agents` and `ultrareview` stay wrapped: both parse fine after options,
    /// and `agents` hands the per-launch `--settings` to the sessions it
    /// dispatches, which is how their hooks reach this pane (dedene/zentty#121).
    /// `attach` is handled separately, see `isAttach`.
    static let passthroughSubcommands: Set<String> = [
        "mcp", "config", "api-key", "remote-control", "rc",
        "auth", "auto-mode", "doctor", "gateway", "import", "install",
        "plugin", "plugins", "purge", "setup-token", "update", "upgrade",
        "logs", "respawn", "rm", "stop", "kill",
    ]

    /// Flags that print and exit before any session starts.
    static let earlyExitFlags: Set<String> = [
        "--help", "-h", "--version", "-v",
    ]

    static func passthroughSubcommand(in arguments: [String]) -> String? {
        guard let subcommand = arguments.first, passthroughSubcommands.contains(subcommand) else {
            return nil
        }
        return subcommand
    }

    /// Arguments after `--` are prompt text, not options.
    static func earlyExitFlag(in arguments: [String]) -> String? {
        arguments.prefix { $0 != "--" }.first(where: earlyExitFlags.contains)
    }

    /// Why this launch skips the hooks plan, or `nil` when it gets one.
    static func passthroughReason(in arguments: [String]) -> String? {
        if let subcommand = passthroughSubcommand(in: arguments) {
            return "claude passthrough subcommand: \(subcommand)"
        }
        if let flag = earlyExitFlag(in: arguments) {
            return "claude early-exit flag: \(flag)"
        }
        return nil
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
