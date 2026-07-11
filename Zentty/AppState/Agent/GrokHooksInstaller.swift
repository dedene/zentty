import Foundation
import os

private let grokHooksLogger = Logger(subsystem: "be.zenjoy.zentty", category: "GrokHooksInstaller")

/// Installer for Grok Build hooks.
///
/// Grok's official "Always trusted" hook source is `~/.grok/hooks/*.json` (per
/// `~/.grok/docs/user-guide/10-hooks.md`). We register a single JSON config
/// there and pair it with one forwarder script that pipes the payload into
/// `zentty ipc agent-event --adapter=grok`. The Swift CLI then parses it via
/// `GrokCanonicalReEmitter` and fans out canonical Agent Status Protocol
/// events to the running Zentty app — no plugin trust, no per-project trust,
/// no external runtime dependencies.
///
/// Schema rule from the Grok binary: lifecycle events (`SessionStart`,
/// `Stop`, `Notification`, etc.) MUST NOT specify a `matcher` field — only
/// `PreToolUse` / `PostToolUse` may have one. Including a matcher on a
/// lifecycle event silently invalidates the entry (binary string:
/// "lifecycle hooks () must not specify a matcher in v0").
///
/// Earlier versions of this installer wrote to `~/.grok/user-settings.json`,
/// `~/.grok/hooks-paths`, and `~/.grok/plugins/zentty-status/`. Grok ignores
/// the first two for hook discovery, and the plugin manifest is `[disabled]`
/// by default. `uninstall` cleans those legacy artifacts up so users
/// upgrading from a broken install land in a clean state.
enum GrokHooksInstaller {

    /// String present in every script we install. Used by uninstall to identify
    /// and remove only our entries.
    static let hookMarker: String = "ipc agent-event --adapter=grok"

    /// Lifecycle hook events. Per Grok's schema these MUST NOT specify a
    /// `matcher`. Order is preserved for deterministic JSON output.
    private static let lifecycleEvents: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "Notification",
        "BeforeAgent",
        "AfterAgent",
    ]

    /// Tool-use events. These DO accept a `matcher`. We use `".*"` to fire on
    /// every tool call (we filter downstream in `GrokCanonicalReEmitter`).
    private static let toolUseEvents: [String] = [
        "PreToolUse",
        "PostToolUse",
    ]

    /// Every event the installer registers, in canonical order. Exposed for
    /// tests; the JSON build uses the two arrays above to attach the matcher
    /// only to the tool-use subset.
    static let defaultManagedEvents: [String] = lifecycleEvents + toolUseEvents

    /// File name of the JSON hook config we drop in `~/.grok/hooks/`.
    private static let hookConfigFileName = "zentty-status.json"

    /// Subdirectory (inside `~/.grok/hooks/`) where the forwarder script lives.
    /// Putting the script in a subdir keeps it out of grok's `*.json` glob.
    private static let forwarderSubdirName = "zentty-status"
    private static let forwarderScriptName = "01-zentty-status.sh"

    /// Marker file used to detect "first install" so we can show a one-time
    /// user-visible message. Lives next to the JSON config.
    private static let firstRunMarkerName = ".zentty-installed"

    // MARK: - Public surface

    /// Returns `~/.grok/hooks/`.
    static func defaultUserHooksURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// True when the Zentty forwarder script is present and carries our marker
    /// — the ownership signal `uninstall` keys off for the current layout. Used
    /// by the grandfather migration to recognize pre-existing installs.
    ///
    /// Note: this detects only the current `zentty-status/01-zentty-status.sh`
    /// layout. `uninstall` additionally cleans up legacy artifacts (per-event
    /// scripts, `user-settings.json` entries, plugin manifests); a user who has
    /// ONLY a legacy install and never re-ran grok since the layout change is
    /// not detected here and is re-prompted once on next launch (self-healing).
    static func isInstalled(
        hooksRoot: URL = defaultUserHooksURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        let forwarderURL = hooksRoot
            .appendingPathComponent(forwarderSubdirName, isDirectory: true)
            .appendingPathComponent(forwarderScriptName, isDirectory: false)
        guard
            fileManager.isReadableFile(atPath: forwarderURL.path),
            let script = try? String(contentsOf: forwarderURL, encoding: .utf8)
        else {
            return false
        }
        return script.contains(hookMarker)
    }

    /// Ensures Zentty-managed Grok status hooks exist for the current user.
    /// Idempotent and cheap — only writes if our content has drifted.
    /// Returns true if this was the first install we noticed.
    @discardableResult
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let hooksRoot = defaultUserHooksURL()
        let markerFile = hooksRoot.appendingPathComponent(firstRunMarkerName, isDirectory: false)
        let alreadyInstalled = fileManager.fileExists(atPath: markerFile.path)

        try install(at: hooksRoot, cliPath: cliPath, fileManager: fileManager)

        if !alreadyInstalled {
            try? Data().write(to: markerFile)
            fputs(
                "\n[Zentty] Installed Grok status hooks at ~/.grok/hooks/zentty-status.json.\n" +
                "        Hooks fire automatically — no /hooks-trust or /plugins enable needed.\n" +
                "        Run `zentty uninstall grok-hooks` to remove.\n\n",
                stderr
            )
            return true
        }
        return false
    }

    // MARK: - Install

    /// Installs the Zentty hook config + forwarder script into `hooksRoot`
    /// (typically `~/.grok/hooks/`). The `managedEvents` parameter is retained
    /// for tests but defaults to the full canonical set.
    static func install(
        at hooksRoot: URL,
        cliPath: String,
        fileManager: FileManager = .default,
        managedEvents: [String] = defaultManagedEvents
    ) throws {
        grokHooksLogger.info("Installing Grok hooks into \(hooksRoot.path)")

        try fileManager.createDirectory(at: hooksRoot, withIntermediateDirectories: true)
        let forwarderDir = hooksRoot.appendingPathComponent(forwarderSubdirName, isDirectory: true)
        try fileManager.createDirectory(at: forwarderDir, withIntermediateDirectories: true)

        // 1. Forwarder script
        let forwarderURL = forwarderDir.appendingPathComponent(forwarderScriptName, isDirectory: false)
        let scriptContent = forwarderScriptBody(cliPath: cliPath)
        let scriptData = Data(scriptContent.utf8)
        let scriptUpToDate = (try? Data(contentsOf: forwarderURL)) == scriptData
        if !scriptUpToDate {
            try scriptData.write(to: forwarderURL, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forwarderURL.path)

        // 2. JSON hook config
        let configURL = hooksRoot.appendingPathComponent(hookConfigFileName, isDirectory: false)
        let hookConfig = buildHookConfig(
            forwarderPath: forwarderURL.path,
            managedEvents: managedEvents
        )
        let configData = try JSONSerialization.data(
            withJSONObject: hookConfig,
            options: [.prettyPrinted, .sortedKeys]
        )
        let configUpToDate = (try? Data(contentsOf: configURL)) == configData
        if !configUpToDate {
            try configData.write(to: configURL, options: .atomic)
        }

        grokHooksLogger.info("Grok hooks installed at \(configURL.path)")
    }

    /// Returns the JSON object Grok expects, partitioning events into lifecycle
    /// (no matcher) and tool-use (matcher `".*"`). Exposed via the body of the
    /// function rather than as a separate helper so tests can validate the
    /// shape via `install` rather than re-implement it.
    private static func buildHookConfig(
        forwarderPath: String,
        managedEvents: [String]
    ) -> [String: Any] {
        var hookEntries: [String: Any] = [:]
        for event in managedEvents {
            let baseHook: [String: Any] = [
                "type": "command",
                "command": forwarderPath,
                "timeout": 15,
            ]
            var entry: [String: Any] = ["hooks": [baseHook]]
            if toolUseEvents.contains(event) {
                entry["matcher"] = ".*"
            }
            hookEntries[event] = [entry]
        }
        return ["hooks": hookEntries]
    }

    /// Forwarder body. Uses the existing `hookCLIBinResolution` snippet so the
    /// script keeps working even when Grok strips `$ZENTTY_CLI_BIN` (or other
    /// `ZENTTY_*` env vars) before exec'ing hook children.
    private static func forwarderScriptBody(cliPath: String) -> String {
        let resolution = hookCLIBinResolution(cliPath: cliPath)
        return """
        #!/usr/bin/env bash
        # Zentty-managed hook for Grok Build status reporting.
        # Marker: \(hookMarker)

        \(resolution)
        exec "$ZENTTY_BIN" ipc agent-event --adapter=grok
        """
    }

    private static func hookCLIBinResolution(cliPath: String) -> String {
        let escaped = cliPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        ZENTTY_BIN="\(escaped)"
        if [[ -z "$ZENTTY_BIN" || ! -x "$ZENTTY_BIN" ]]; then
            ZENTTY_BIN="$(command -v zentty 2>/dev/null || true)"
        fi
        if [[ -z "$ZENTTY_BIN" ]]; then
            exit 0
        fi
        """
    }

    // MARK: - Uninstall

    /// Removes Zentty-managed hook artifacts under `hooksRoot` (the current
    /// layout) AND cleans up legacy artifacts from previous installer versions
    /// (`user-settings.json` hook entries, `hooks-paths` line, plugin manifest
    /// directory, per-event-subdir scripts). Best-effort — missing files are
    /// not an error.
    static func uninstall(
        at hooksRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        grokHooksLogger.info("Uninstalling Grok hooks from \(hooksRoot.path)")

        // 1. Current layout: ~/.grok/hooks/zentty-status.json + zentty-status/01-zentty-status.sh
        let configURL = hooksRoot.appendingPathComponent(hookConfigFileName, isDirectory: false)
        try? fileManager.removeItem(at: configURL)

        let forwarderDir = hooksRoot.appendingPathComponent(forwarderSubdirName, isDirectory: true)
        if fileManager.fileExists(atPath: forwarderDir.path) {
            try? fileManager.removeItem(at: forwarderDir)
        }

        // 2. Legacy: per-event subdirectory scripts (`~/.grok/hooks/<Event>/01-zentty-status.sh`).
        removeLegacyPerEventScripts(in: hooksRoot, fileManager: fileManager)

        // 3. Legacy: user-settings.json hook entries.
        try? removeLegacyUserSettingsEntries(hooksRoot: hooksRoot, fileManager: fileManager)

        // 4. Legacy: hooks-paths line.
        removeLegacyHooksPathsLine(hooksRoot: hooksRoot, fileManager: fileManager)

        // 5. Legacy: plugin manifest dir.
        let pluginDir = grokRoot(forHooks: hooksRoot)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-status", isDirectory: true)
        if fileManager.fileExists(atPath: pluginDir.path) {
            try? fileManager.removeItem(at: pluginDir)
        }

        // 6. First-run marker.
        let markerFile = hooksRoot.appendingPathComponent(firstRunMarkerName, isDirectory: false)
        try? fileManager.removeItem(at: markerFile)

        // 7. Remove the hooks dir if it's now empty.
        if (try? fileManager.contentsOfDirectory(at: hooksRoot, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? fileManager.removeItem(at: hooksRoot)
        }
    }

    // MARK: - Legacy cleanup helpers

    /// Removes `~/.grok/hooks/<EventName>/01-zentty-status.sh` from older
    /// per-event-subdir installs, and the parent subdir if it becomes empty.
    private static func removeLegacyPerEventScripts(
        in hooksRoot: URL,
        fileManager: FileManager
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(at: hooksRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in contents where entry.hasDirectoryPath && entry.lastPathComponent != forwarderSubdirName {
            guard let scripts = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) else {
                continue
            }
            for script in scripts {
                guard let data = try? Data(contentsOf: script),
                      let content = String(data: data, encoding: .utf8),
                      content.contains(hookMarker) else {
                    continue
                }
                try? fileManager.removeItem(at: script)
            }
            if (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?.isEmpty == true {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Strips Zentty entries from a legacy `~/.grok/user-settings.json` "hooks"
    /// dict, preserving any user-added entries. Deletes the file if it becomes
    /// empty. No-op when the file is absent or unparseable.
    private static func removeLegacyUserSettingsEntries(
        hooksRoot: URL,
        fileManager: FileManager
    ) throws {
        let settingsURL = grokRoot(forHooks: hooksRoot)
            .appendingPathComponent("user-settings.json", isDirectory: false)
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        var didRemove = false
        for (event, raw) in hooks {
            guard let entries = raw as? [[String: Any]] else { continue }
            let filtered = entries.filter { !isZenttyManagedEntry($0) }
            if filtered.count != entries.count {
                hooks[event] = filtered.isEmpty ? nil : filtered
                didRemove = true
            }
        }
        guard didRemove else { return }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if json.isEmpty {
            try fileManager.removeItem(at: settingsURL)
        } else {
            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: settingsURL, options: .atomic)
        }
    }

    /// Removes our line from a legacy `~/.grok/hooks-paths` file. Deletes the
    /// file if it becomes empty.
    private static func removeLegacyHooksPathsLine(
        hooksRoot: URL,
        fileManager: FileManager
    ) {
        let pathsURL = grokRoot(forHooks: hooksRoot)
            .appendingPathComponent("hooks-paths", isDirectory: false)
        guard fileManager.fileExists(atPath: pathsURL.path),
              let content = try? String(contentsOf: pathsURL, encoding: .utf8) else {
            return
        }
        // Line-exact filter so unrelated paths that contain ours as a prefix
        // (e.g. ".grok/hooks-extra") survive.
        let lines = content.components(separatedBy: .newlines).filter { $0 != hooksRoot.path && !$0.isEmpty }
        if lines.isEmpty {
            try? fileManager.removeItem(at: pathsURL)
        } else {
            try? (lines.joined(separator: "\n") + "\n").write(to: pathsURL, atomically: true, encoding: .utf8)
        }
    }

    /// Sibling files (user-settings.json, hooks-paths, plugins/) live next to
    /// the hooks dir, not inside it. Tests pass a tmp hooksRoot whose parent
    /// stands in for `~/.grok/`.
    private static func grokRoot(forHooks hooksRoot: URL) -> URL {
        hooksRoot.deletingLastPathComponent()
    }

    /// Returns every command path attached to a JSON registration entry. Grok's
    /// format wraps the actual command inside `entry["hooks"][i]["command"]`;
    /// some legacy/user shapes use `entry["command"]` directly. We check both
    /// so legacy uninstall recognises our entries regardless of which shape.
    private static func commandPaths(in entry: [String: Any]) -> [String] {
        var paths: [String] = []
        if let cmd = entry["command"] as? String { paths.append(cmd) }
        if let nested = entry["hooks"] as? [[String: Any]] {
            for hook in nested {
                if let cmd = hook["command"] as? String { paths.append(cmd) }
            }
        }
        return paths
    }

    /// An entry is Zentty-managed if any of its command paths references our
    /// marker or our installed script filename. Matches both the new
    /// `zentty-status/01-zentty-status.sh` path and the legacy per-event
    /// `<EventName>/01-zentty-status.sh` paths.
    private static func isZenttyManagedEntry(_ entry: [String: Any]) -> Bool {
        commandPaths(in: entry).contains { cmd in
            cmd.contains(hookMarker) || cmd.contains("/01-zentty-status.sh")
        }
    }

    // MARK: - CLI convenience

    static func install(cliPath: String, fileManager: FileManager = .default) throws {
        try install(at: defaultUserHooksURL(), cliPath: cliPath, fileManager: fileManager)
    }

    static func uninstall(fileManager: FileManager = .default) throws {
        try uninstall(at: defaultUserHooksURL(), fileManager: fileManager)
    }
}

// MARK: - HooksInstalling conformance

extension GrokHooksInstaller: HooksInstalling {
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        environment: [String: String],
        fileManager: FileManager
    ) throws {
        _ = try ensureInstalledForCurrentUser(cliPath: cliPath, fileManager: fileManager)
    }

    static func isInstalledForCurrentUser(environment: [String: String], fileManager: FileManager) -> Bool {
        isInstalled(hooksRoot: defaultUserHooksURL(home: environment["HOME"] ?? NSHomeDirectory()), fileManager: fileManager)
    }

    static func uninstallForCurrentUser(environment: [String: String], fileManager: FileManager) throws {
        try uninstall(fileManager: fileManager)
    }

    static func integrationConfigURL(environment: [String: String]) -> URL? {
        defaultUserHooksURL(home: environment["HOME"] ?? NSHomeDirectory())
    }
}
