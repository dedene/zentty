import Foundation
import os

private let agyHooksLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgyHooksInstaller")

/// Installs Zentty's Antigravity status hooks into the user's Antigravity
/// configuration so the running Zentty app can observe session lifecycle and
/// tool-use events.
///
/// The Antigravity CLI loads hooks from a single JSON file at
/// `~/.gemini/config/hooks.json`. Multiple installers (Zentty, the user's own
/// hooks, other tools) coexist by owning a top-level group key; we own
/// `"zentty"` and merge non-destructively with whatever else is in the file.
///
/// Each event entry runs a single shell line that invokes
/// `zentty agy-hook <event>`. The hook subcommand is responsible for
/// forwarding the payload to the app over IPC and printing the JSON response
/// the Antigravity CLI expects on stdout. A trailing `|| echo '{}'` keeps
/// Antigravity from failing the hook step if `agy-hook` itself exits
/// non-zero.
///
/// Plugin-style installations under `~/.gemini/.../plugins/zentty/` are
/// considered legacy: install removes them if they carry the Zentty marker,
/// uninstall does the same. They predated runtime hook loading and are no
/// longer wired up.
enum AgyHooksInstaller {

    /// Marker present in every shell command we write into `hooks.json`. Used
    /// by `uninstall(...)` as a recognition guard before touching the file and
    /// by tests for assertions.
    static let hookMarker: String = "zentty-agy-hook-v1"

    /// Top-level key under which Zentty's hook entries live in
    /// `~/.gemini/config/hooks.json`. Other groups in the same file are
    /// preserved verbatim by install/uninstall.
    static let groupKey: String = "zentty"

    /// Sentinel file written next to `hooks.json` the first time Zentty
    /// auto-installs hooks for the current user. Its presence suppresses the
    /// one-time install banner on subsequent launches.
    static let firstRunMarkerName: String = ".zentty-agy-hooks-installed"

    /// Plugin directory name owned by Zentty under each legacy plugins root.
    private static let legacyPluginName: String = "zentty"

    /// Marker that older plugin-format installations carried in `hook.sh`.
    /// Used to gate deletion of legacy plugin directories so we never remove
    /// a directory we don't own.
    private static let legacyHookMarker: String = "agy-hook"
    private static let oldestLegacyHookMarker: String = "ipc agent-event --adapter=agy"

    // MARK: Paths

    /// Returns `~/.gemini/config/hooks.json` — the file the Antigravity CLI
    /// reads at startup to discover hooks.
    static func defaultUserHooksFileURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    /// Returns `~/.gemini/antigravity-cli/plugins/` — the first plugin root
    /// the Antigravity CLI shipped with. Retained only so install/uninstall
    /// can clean up old Zentty-owned plugin directories.
    static func defaultUserLegacyPluginsURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
    }

    /// Returns `~/.gemini/config/plugins/` — the migrated plugin root. Same
    /// caveat as `defaultUserLegacyPluginsURL`: only used to remove old
    /// Zentty-owned plugin directories.
    static func defaultUserConfigPluginsURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
    }

    // MARK: Hook schema

    /// One canonical Antigravity hook event Zentty subscribes to.
    ///
    /// The `agentEvent` is the literal key the Antigravity CLI looks up in
    /// `hooks.json`. The `cliEvent` is the short, dashed name we forward to
    /// `zentty agy-hook` so the receiving subcommand can pick the right
    /// response payload without re-parsing the JSON.
    struct Event {
        let agentEvent: String
        let cliEvent: String
        let timeoutSeconds: Int
        /// `true` for events Antigravity requires to be wrapped in a
        /// `{matcher, hooks: [...]}` group (currently the tool-use pair).
        let wrappedInMatcher: Bool
    }

    /// Events Zentty wires up. Order matters only for diff stability on
    /// upgrade; the actual hook ordering is whatever Antigravity decides.
    static let events: [Event] = [
        Event(agentEvent: "SessionStart", cliEvent: "session-start", timeoutSeconds: 15, wrappedInMatcher: false),
        Event(agentEvent: "PreInvocation", cliEvent: "prompt-submit", timeoutSeconds: 15, wrappedInMatcher: false),
        Event(agentEvent: "Stop", cliEvent: "stop", timeoutSeconds: 15, wrappedInMatcher: false),
        Event(agentEvent: "turn-completion", cliEvent: "turn-completion", timeoutSeconds: 15, wrappedInMatcher: false),
        Event(agentEvent: "Notification", cliEvent: "notification", timeoutSeconds: 15, wrappedInMatcher: false),
        Event(agentEvent: "SessionEnd", cliEvent: "session-end", timeoutSeconds: 15, wrappedInMatcher: false),
        // Tool-use hooks get a longer timeout because the receiving side may
        // block while a user decides whether to approve a tool call.
        Event(agentEvent: "PreToolUse", cliEvent: "pre-tool-use", timeoutSeconds: 120, wrappedInMatcher: true),
        Event(agentEvent: "PostToolUse", cliEvent: "post-tool-use", timeoutSeconds: 120, wrappedInMatcher: true),
    ]

    // MARK: Install / Uninstall

    /// Installs Zentty's hook entries into `~/.gemini/config/hooks.json`,
    /// preserving any foreign top-level groups in the file. Also removes
    /// legacy plugin-style installations under
    /// `~/.gemini/{antigravity-cli,config}/plugins/zentty/` if they still
    /// carry a Zentty marker.
    ///
    /// - Parameters:
    ///   - hooksFileURL: target `hooks.json`. Defaults to the user's file.
    ///   - cliPath: path to the `zentty` binary baked into each shell entry.
    ///   - home: HOME override used to locate legacy plugin directories.
    ///   - fileManager: injection point for tests.
    /// - Returns: `true` when the file content actually changed; `false` when
    ///   the on-disk hooks already matched (so callers like
    ///   `ensureInstalledForCurrentUser` can skip work and avoid rewriting on
    ///   every launch).
    @discardableResult
    static func install(
        hooksFileURL: URL = defaultUserHooksFileURL(),
        cliPath: String,
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> Bool {
        agyHooksLogger.info("Installing Antigravity hooks at \(hooksFileURL.path)")

        let directoryURL = hooksFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Resolve symlinks before writing. Atomic write does a temp-file +
        // rename, which would otherwise replace a user's symlink (e.g. one
        // pointing into a dotfiles repo) with a regular file and silently
        // sever the link.
        let resolvedURL = resolvedHooksFileURL(hooksFileURL, fileManager: fileManager)

        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: resolvedURL),
           !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                agyHooksLogger.error("Refusing to overwrite \(resolvedURL.path) — existing content is not a JSON object")
                throw AgyHooksInstallerError.existingFileNotJSON(path: resolvedURL.path)
            }
            existing = parsed
        }

        // Canonical "before" — re-serialize the parsed content so the
        // comparison ignores incidental formatting/key-order differences and
        // only reacts to a genuine semantic change.
        let beforeData = try? JSONSerialization.data(
            withJSONObject: existing,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        existing[groupKey] = buildGroup(cliPath: cliPath)

        let data = try JSONSerialization.data(
            withJSONObject: existing,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        let didWrite: Bool
        if beforeData == data, fileManager.fileExists(atPath: resolvedURL.path) {
            // Our group was already present and identical — leave the file
            // untouched so launches don't churn it.
            didWrite = false
        } else {
            try data.write(to: resolvedURL, options: .atomic)
            didWrite = true
        }

        removeLegacyPluginDirectories(home: home, fileManager: fileManager)
        return didWrite
    }

    /// Removes Zentty's hook entries from `~/.gemini/config/hooks.json` and
    /// drops the file if no other groups remain. Also cleans up legacy
    /// plugin-style installations.
    static func uninstall(
        hooksFileURL: URL = defaultUserHooksFileURL(),
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws {
        defer {
            removeLegacyPluginDirectories(home: home, fileManager: fileManager)
            // Drop the first-run marker so a future auto-install re-announces.
            let markerURL = hooksFileURL
                .deletingLastPathComponent()
                .appendingPathComponent(firstRunMarkerName, isDirectory: false)
            try? fileManager.removeItem(at: markerURL)
        }

        let resolvedURL = resolvedHooksFileURL(hooksFileURL, fileManager: fileManager)

        guard let data = try? Data(contentsOf: resolvedURL), !data.isEmpty else {
            return
        }
        guard var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Don't touch a file we can't parse — the user (or another tool)
            // may have hand-edited it into a state we shouldn't be guessing
            // at.
            agyHooksLogger.info("Skipping uninstall: \(resolvedURL.path) is not a JSON object")
            return
        }

        // Only act if the group we own actually looks like one of ours —
        // otherwise a different tool could legitimately own a top-level
        // "zentty" key and we'd silently delete it.
        if let group = parsed[groupKey] {
            guard groupLooksOwnedByZentty(group) else {
                agyHooksLogger.info("Skipping uninstall: \(groupKey) group in \(resolvedURL.path) does not match Zentty's marker")
                return
            }
            parsed.removeValue(forKey: groupKey)
        } else {
            return
        }

        if parsed.isEmpty {
            try? fileManager.removeItem(at: resolvedURL)
            return
        }

        let newData = try JSONSerialization.data(
            withJSONObject: parsed,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try newData.write(to: resolvedURL, options: .atomic)
    }

    /// Ensures Zentty's Antigravity status hooks exist for the current user,
    /// installing them on first launch and keeping them current thereafter.
    /// Called from `AgentLaunchBootstrap.agyPlan` on every agy launch, so it
    /// must stay cheap: `install` only rewrites `hooks.json` when the content
    /// has drifted. A one-time stderr banner is printed the first time only,
    /// keyed off a marker file next to `hooks.json`.
    ///
    /// - Returns: `true` when this call performed the first-run announcement
    ///   (useful for tests); `false` otherwise.
    @discardableResult
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> Bool {
        let hooksFileURL = defaultUserHooksFileURL(home: home)
        let markerURL = hooksFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(firstRunMarkerName, isDirectory: false)
        let alreadyAnnounced = fileManager.fileExists(atPath: markerURL.path)

        try install(hooksFileURL: hooksFileURL, cliPath: cliPath, home: home, fileManager: fileManager)

        guard !alreadyAnnounced else {
            return false
        }

        // Best-effort marker + banner. A marker-write failure is non-fatal;
        // worst case the banner prints again on a later launch.
        try? Data().write(to: markerURL)
        FileHandle.standardError.write(Data("""

        [Zentty] Installed Antigravity status hooks at \(hooksFileURL.path).
                Hooks fire automatically — no manual setup needed.
                Run `zentty uninstall agy-hooks` to remove.

        """.utf8))
        return true
    }

    /// Resolves the hooks file URL through any user-managed symlinks so the
    /// subsequent atomic write replaces the actual content, not the link.
    private static func resolvedHooksFileURL(_ url: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            return url
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard let fileType = attributes?[.type] as? FileAttributeType, fileType == .typeSymbolicLink else {
            return url
        }
        return url.resolvingSymlinksInPath()
    }

    // MARK: Internals

    /// Builds the `{"<EventName>": [...entries...]}` dictionary Zentty owns
    /// under the `"zentty"` key in `hooks.json`.
    static func buildGroup(cliPath: String) -> [String: Any] {
        var group: [String: Any] = [:]
        for event in events {
            let command = hookCommand(cliPath: cliPath, cliEvent: event.cliEvent)
            let entry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": event.timeoutSeconds,
            ]
            if event.wrappedInMatcher {
                group[event.agentEvent] = [
                    [
                        "matcher": "*",
                        "hooks": [entry],
                    ] as [String: Any]
                ]
            } else {
                group[event.agentEvent] = [entry]
            }
        }
        return group
    }

    /// Builds the inline shell command Antigravity will execute for an event.
    ///
    /// The colon-leader is a shell no-op that lets us embed a stable marker
    /// without affecting behavior — `uninstall` and tests grep for it. The
    /// disabled-env-var check skips IPC during diagnostic runs. We
    /// deliberately do not use `exec` so the parent shell stays alive and
    /// the trailing `|| echo '{}'` can catch a non-zero exit from
    /// `agy-hook` (Antigravity parses the first JSON object on stdout, so
    /// printing `{}` after `agy-hook` already responded is harmless).
    static func hookCommand(cliPath: String, cliEvent: String) -> String {
        let escapedCLI = shellEscapedDoubleQuoted(cliPath)
        return ": \(hookMarker); "
            + #"if [ "$ZENTTY_AGY_HOOKS_DISABLED" = "1" ]; then echo '{}'; exit 0; fi; "#
            + "\"\(escapedCLI)\" agy-hook \(cliEvent) 2>/dev/null || echo '{}'"
    }

    private static func groupLooksOwnedByZentty(_ group: Any) -> Bool {
        guard let dict = group as? [String: Any] else {
            return false
        }
        for value in dict.values {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let command = entry["command"] as? String, command.contains(hookMarker) {
                        return true
                    }
                    if let nested = entry["hooks"] as? [[String: Any]] {
                        for nestedEntry in nested {
                            if let command = nestedEntry["command"] as? String, command.contains(hookMarker) {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func removeLegacyPluginDirectories(home: String, fileManager: FileManager) {
        for pluginsRoot in [defaultUserLegacyPluginsURL(home: home), defaultUserConfigPluginsURL(home: home)] {
            let pluginDir = pluginsRoot.appendingPathComponent(legacyPluginName, isDirectory: true)
            guard fileManager.fileExists(atPath: pluginDir.path) else {
                continue
            }
            let hookScriptURL = pluginDir.appendingPathComponent("hook.sh", isDirectory: false)
            let script = try? String(contentsOf: hookScriptURL, encoding: .utf8)
            guard script?.contains(legacyHookMarker) == true
                    || script?.contains(oldestLegacyHookMarker) == true else {
                agyHooksLogger.info("Skipping legacy plugin removal at \(pluginDir.path) — does not carry Zentty marker")
                continue
            }
            do {
                try fileManager.removeItem(at: pluginDir)
                agyHooksLogger.info("Removed legacy plugin directory at \(pluginDir.path)")
            } catch {
                agyHooksLogger.warning("Failed to remove legacy plugin directory \(pluginDir.path): \(String(describing: error))")
            }
        }
    }

    private static func shellEscapedDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

enum AgyHooksInstallerError: Error, CustomStringConvertible {
    case existingFileNotJSON(path: String)

    var description: String {
        switch self {
        case let .existingFileNotJSON(path):
            return "\(path) exists but is not a JSON object. Move or remove the file before re-running install."
        }
    }
}
