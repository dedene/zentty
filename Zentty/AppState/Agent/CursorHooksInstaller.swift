import Foundation
import os

private let installerLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CursorHookInstall")

/// Installs and removes Zentty hook entries in Cursor's user-level hooks file.
///
/// Cursor (the Cursor CLI agent, `cursor-agent`) loads hooks from
/// `~/.cursor/hooks.json`; there is no environment variable or CLI flag that
/// redirects this path. The installer mutates that file in place: Zentty's
/// managed entries are marked by the presence of `hookMarker` in the command
/// string, so uninstall (and re-install) can find and rewrite them without
/// touching entries owned by the user or other tools.
enum CursorHooksInstaller {
    static let managedEvents: [String] = [
        "sessionStart",
        "sessionEnd",
        "beforeSubmitPrompt",
        "stop",
    ]

    /// Substring present in every Zentty-managed hook command. Used to locate
    /// and remove our entries without affecting entries the user added by hand
    /// or via another tool.
    static let hookMarker: String = "ipc agent-event --adapter=cursor"

    static func defaultUserHooksURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    /// Write (or refresh) Zentty's hook entries in the given file. Safe to call
    /// repeatedly; stale entries are replaced in place.
    ///
    /// Throws only on unrecoverable I/O failures. A malformed existing file is
    /// surfaced as a thrown error so the caller can log an actionable message
    /// rather than destroying user data.
    static func install(
        at hooksURL: URL,
        cliPath: String,
        fileManager: FileManager = .default
    ) throws {
        let command = hookCommand(cliPath: cliPath)
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var jsonObject: [String: Any] = [:]
        if fileManager.isReadableFile(atPath: hooksURL.path) {
            let data = try Data(contentsOf: hooksURL)
            if !data.isEmpty {
                guard let parsed = parsePermissive(data) else {
                    throw CocoaError(
                        .propertyListReadCorrupt,
                        userInfo: [NSLocalizedDescriptionKey:
                            "\(hooksURL.path) is not valid JSON; move it aside or fix it and relaunch"]
                    )
                }
                jsonObject = parsed
            }
        }
        jsonObject["version"] = 1

        var hooks = jsonObject["hooks"] as? [String: Any] ?? [:]
        for event in managedEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                guard let existing = entry["command"] as? String else { return false }
                return existing.contains(hookMarker)
            }
            entries.append(["command": command])
            hooks[event] = entries
        }
        jsonObject["hooks"] = hooks

        let newData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        if fileManager.isReadableFile(atPath: hooksURL.path),
           let existing = try? Data(contentsOf: hooksURL),
           existing == newData {
            return
        }

        try newData.write(to: hooksURL, options: .atomic)
    }

    /// Remove any Zentty-managed entries from the given file. If removal
    /// leaves the file with no hooks and no other top-level keys, the file is
    /// deleted entirely. Files that never contained a Zentty entry are left
    /// exactly as-is (including any JSON-with-Comments formatting the user may
    /// have).
    static func uninstall(
        at hooksURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.isReadableFile(atPath: hooksURL.path) else {
            return
        }
        let data = try Data(contentsOf: hooksURL)
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
                guard let existing = entry["command"] as? String else { return false }
                return existing.contains(hookMarker)
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

        let hasOnlyVersion = jsonObject.keys.allSatisfy { $0 == "version" }
        if hasOnlyVersion {
            try fileManager.removeItem(at: hooksURL)
            return
        }

        let newData = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        if data == newData {
            return
        }
        try newData.write(to: hooksURL, options: .atomic)
    }

    /// Run `install` with environment-derived paths, logging the outcome.
    /// Used by the auto-install path during `zentty launch cursor`.
    static func installIfPossible(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        guard let cliPath = environment["ZENTTY_CLI_BIN"]?.nonBlank else {
            installerLogger.debug("Skipping cursor hook install: ZENTTY_CLI_BIN is not set")
            return
        }
        guard let home = environment["HOME"]?.nonBlank else {
            installerLogger.debug("Skipping cursor hook install: HOME is not set")
            return
        }
        let hooksURL = defaultUserHooksURL(home: home)
        do {
            try install(at: hooksURL, cliPath: cliPath, fileManager: fileManager)
            installerLogger.info("Installed Zentty hook entries in \(hooksURL.path, privacy: .public)")
        } catch {
            installerLogger.error(
                "Failed to install cursor hooks at \(hooksURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Internals

    static func hookCommand(cliPath: String) -> String {
        "\"\(shellEscapeDoubleQuoted(cliPath))\" ipc agent-event --adapter=cursor"
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
