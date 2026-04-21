import Foundation
import os

private let installerLogger = Logger(subsystem: "be.zenjoy.zentty", category: "DroidHookInstall")

/// Installs and removes Zentty hook entries in Droid's user-level settings.local.json file.
///
/// Droid (`droid`) merges hooks from `~/.factory/settings.local.json` on top of
/// `~/.factory/settings.json`. The installer mutates `settings.local.json` in place:
/// Zentty's managed entries are marked by the presence of `hookMarker` in the command
/// string, so uninstall (and re-install) can find and rewrite them without touching
/// entries owned by the user or other tools in either file.
enum DroidHooksInstaller {
    static let managedEvents: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
        "SubagentStop",
    ]

    /// Substring present in every Zentty-managed hook command. Used to locate
    /// and remove our entries without affecting entries the user added by hand
    /// or via another tool.
    static let hookMarker: String = "ipc agent-event --adapter=droid"

    static func defaultUserSettingsURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("settings.local.json", isDirectory: false)
    }

    /// Write (or refresh) Zentty's hook entries in the given file. Safe to call
    /// repeatedly; stale entries are replaced in place.
    ///
    /// Throws only on unrecoverable I/O failures. A malformed existing file is
    /// surfaced as a thrown error so the caller can log an actionable message
    /// rather than destroying user data.
    static func install(
        at settingsURL: URL,
        cliPath: String,
        fileManager: FileManager = .default
    ) throws {
        let command = hookCommand(cliPath: cliPath)
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var jsonObject: [String: Any] = [:]
        if fileManager.isReadableFile(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if !data.isEmpty {
                guard let parsed = parsePermissive(data) else {
                    throw CocoaError(
                        .propertyListReadCorrupt,
                        userInfo: [NSLocalizedDescriptionKey:
                            "\(settingsURL.path) is not valid JSON; move it aside or fix it and relaunch"]
                    )
                }
                jsonObject = parsed
            }
        }

        var hooks = jsonObject["hooks"] as? [String: Any] ?? [:]
        for event in managedEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                guard let nestedHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return nestedHooks.contains { hook in
                    guard let existing = hook["command"] as? String else { return false }
                    return existing.contains(hookMarker)
                }
            }
            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": 10,
                    ],
                ],
            ])
            hooks[event] = entries
        }
        jsonObject["hooks"] = hooks

        let newData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        if fileManager.isReadableFile(atPath: settingsURL.path),
           let existing = try? Data(contentsOf: settingsURL),
           existing == newData {
            return
        }

        try newData.write(to: settingsURL, options: .atomic)
    }

    /// Remove any Zentty-managed entries from the given file. If removal
    /// leaves the file with no hooks and no other top-level keys, the file is
    /// deleted entirely. Files that never contained a Zentty entry are left
    /// exactly as-is (including any JSON-with-Comments formatting the user may
    /// have).
    static func uninstall(
        at settingsURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.isReadableFile(atPath: settingsURL.path) else {
            return
        }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty, var jsonObject = parsePermissive(data) else {
            return
        }

        guard var hooks = jsonObject["hooks"] as? [String: Any] else {
            return
        }

        var didRemoveAny = false
        for event in managedEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { entry in
                guard let nestedHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return nestedHooks.contains { hook in
                    guard let existing = hook["command"] as? String else { return false }
                    return existing.contains(hookMarker)
                }
            }
            if entries.count != before {
                didRemoveAny = true
            }
            if entries.isEmpty {
                if hooks[event] != nil {
                    hooks.removeValue(forKey: event)
                }
            } else {
                hooks[event] = entries
            }
        }

        guard didRemoveAny else {
            return
        }

        if hooks.isEmpty {
            jsonObject.removeValue(forKey: "hooks")
        } else {
            jsonObject["hooks"] = hooks
        }

        if jsonObject.isEmpty {
            try fileManager.removeItem(at: settingsURL)
            return
        }

        let newData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        if data == newData {
            return
        }
        try newData.write(to: settingsURL, options: .atomic)
    }

    /// URL for `~/.factory/hooks/hooks.json` where Droid persists hook-level
    /// settings like `showHookOutput`.
    static func defaultHooksConfigURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    /// Ensure `showHookOutput` is set to `false` in Droid's hooks config.
    ///
    /// Zentty hooks are invisible plumbing that should not clutter the Droid
    /// chat view with purple HOOKS output boxes. This sets the flag only if
    /// it has not already been explicitly set by the user.
    static func suppressHookOutput(
        at hooksConfigURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: hooksConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var jsonObject: [String: Any] = [:]
        if fileManager.isReadableFile(atPath: hooksConfigURL.path) {
            let data = try Data(contentsOf: hooksConfigURL)
            if !data.isEmpty {
                guard let parsed = parsePermissive(data) else {
                    // File is corrupt — don't risk overwriting user data.
                    return
                }
                jsonObject = parsed
            }
        }

        // Only set the default if the key is absent — respect the user's
        // explicit choice if they've already toggled it.
        guard jsonObject["showHookOutput"] == nil else {
            return
        }

        jsonObject["showHookOutput"] = false

        let newData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try newData.write(to: hooksConfigURL, options: .atomic)
    }

    /// Run `install` with environment-derived paths, logging the outcome.
    /// Used by the auto-install path during `zentty launch droid`.
    static func installIfPossible(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nonBlank else {
            installerLogger.debug("Skipping droid hook install: ZENTTY_CLI_BIN is not set")
            return
        }
        guard let home = environment["HOME"]?.nonBlank else {
            installerLogger.debug("Skipping droid hook install: HOME is not set")
            return
        }
        let settingsURL = defaultUserSettingsURL(home: home)
        do {
            try install(at: settingsURL, cliPath: cliPath, fileManager: fileManager)
            installerLogger.info("Installed Zentty hook entries in \(settingsURL.path, privacy: .public)")
        } catch {
            installerLogger.error(
                "Failed to install droid hooks at \(settingsURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        let hooksConfigURL = defaultHooksConfigURL(home: home)
        do {
            try suppressHookOutput(at: hooksConfigURL, fileManager: fileManager)
        } catch {
            installerLogger.warning(
                "Failed to suppress droid hook output at \(hooksConfigURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Internals

    static func hookCommand(cliPath: String) -> String {
        "\"\(shellEscapeDoubleQuoted(cliPath))\" ipc agent-event --adapter=droid"
    }

    /// Try strict JSON first; on failure, retry after stripping `//` / `/* */`
    /// comments and trailing commas (JSON-with-Comments forms some users edit
    /// by hand). Returns `nil` only when the content can't be recovered.
    private static func parsePermissive(_ data: Data) -> [String: Any]? {
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        guard let stripped = JSONCRelaxedParse.stripComments(in: data),
              let cleaned = JSONCRelaxedParse.stripTrailingCommas(in: stripped),
              let parsed = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    private static func shellEscapeDoubleQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

private extension String {
    /// Returns `self` when it has at least one non-whitespace character; `nil`
    /// otherwise. Mirrors the trimming behaviour the pre-extraction helpers
    /// relied on to filter out env vars set to whitespace-only strings.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
