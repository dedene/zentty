import Foundation

enum HermesHooksInstaller {
    struct Event {
        let name: String
        let cliEvent: String
        let timeout: Int
    }

    static let hookMarker = "# zentty hermes hooks begin"
    private static let hookEndMarker = "# zentty hermes hooks end"
    private static let managedScriptsDirectoryName = "zentty-status"
    private static let managedScriptMarker = "zentty hermes hook script v1"
    private static let legacyManagedScriptMarker = "ipc agent-event --adapter=hermes"

    static let events: [Event] = [
        Event(name: "on_session_start", cliEvent: "on-session-start", timeout: 5),
        Event(name: "on_session_reset", cliEvent: "on-session-reset", timeout: 5),
        Event(name: "pre_llm_call", cliEvent: "pre-llm-call", timeout: 5),
        Event(name: "post_llm_call", cliEvent: "post-llm-call", timeout: 5),
        Event(name: "on_session_end", cliEvent: "on-session-end", timeout: 5),
        Event(name: "on_session_finalize", cliEvent: "on-session-finalize", timeout: 5),
        Event(name: "pre_tool_call", cliEvent: "pre-tool-call", timeout: 5),
        Event(name: "post_tool_call", cliEvent: "post-tool-call", timeout: 5),
        Event(name: "pre_approval_request", cliEvent: "pre-approval-request", timeout: 30),
        Event(name: "post_approval_response", cliEvent: "post-approval-response", timeout: 5),
    ]

    static func defaultHermesHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = nonBlank(environment["HOME"]) ?? NSHomeDirectory()
        let configured = nonBlank(environment["HERMES_HOME"]) ?? "~/.hermes"
        if configured == "~" {
            return home
        }
        if configured.hasPrefix("~/") {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
                .path
        }
        return configured
    }

    static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: defaultHermesHome(environment: environment), isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
    }

    static func defaultAllowlistURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: defaultHermesHome(environment: environment), isDirectory: true)
            .appendingPathComponent("shell-hooks-allowlist.json", isDirectory: false)
    }

    @discardableResult
    static func install(
        configURL: URL = defaultConfigURL(),
        allowlistURL: URL = defaultAllowlistURL(),
        cliPath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: allowlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let wroteScripts = try installManagedScripts(
            hermesHomeURL: configURL.deletingLastPathComponent(),
            cliPath: cliPath,
            fileManager: fileManager
        )

        let existingConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let nextConfig = installManagedBlock(
            in: existingConfig,
            hermesHomeURL: configURL.deletingLastPathComponent()
        )
        let wroteConfig = existingConfig != nextConfig || !fileManager.fileExists(atPath: configURL.path)
        if wroteConfig {
            try nextConfig.write(to: configURL, atomically: true, encoding: .utf8)
        }

        let existingAllowlist = readAllowlist(at: allowlistURL)
        let nextAllowlist = mergedAllowlist(
            existingAllowlist,
            hermesHomeURL: configURL.deletingLastPathComponent()
        )
        let existingAllowlistData = try? JSONSerialization.data(
            withJSONObject: existingAllowlist,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let nextAllowlistData = try JSONSerialization.data(
            withJSONObject: nextAllowlist,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let wroteAllowlist = existingAllowlistData != nextAllowlistData || !fileManager.fileExists(atPath: allowlistURL.path)
        if wroteAllowlist {
            try nextAllowlistData.write(to: allowlistURL, options: .atomic)
        }

        return wroteScripts || wroteConfig || wroteAllowlist
    }

    static func uninstall(
        configURL: URL = defaultConfigURL(),
        allowlistURL: URL = defaultAllowlistURL(),
        fileManager: FileManager = .default
    ) throws {
        if let existingConfig = try? String(contentsOf: configURL, encoding: .utf8) {
            let nextConfig = removeManagedBlock(from: existingConfig)
            if nextConfig != existingConfig {
                try nextConfig.write(to: configURL, atomically: true, encoding: .utf8)
            }
        }

        guard fileManager.fileExists(atPath: allowlistURL.path) else {
            return
        }

        let existingAllowlist = readAllowlist(at: allowlistURL)
        let nextAllowlist = removeManagedApprovals(from: existingAllowlist)
        let existingAllowlistData = try? JSONSerialization.data(
            withJSONObject: existingAllowlist,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let nextAllowlistData = try JSONSerialization.data(
            withJSONObject: nextAllowlist,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if existingAllowlistData != nextAllowlistData {
            try nextAllowlistData.write(to: allowlistURL, options: .atomic)
        }

        let scriptsURL = managedScriptsDirectoryURL(hermesHomeURL: configURL.deletingLastPathComponent())
        if fileManager.fileExists(atPath: scriptsURL.path) {
            try? fileManager.removeItem(at: scriptsURL)
        }
    }

    /// True when the Hermes config currently contains a well-formed Zentty
    /// managed block. Mirrors `removeManagedBlock` exactly — a standalone
    /// (trimmed) begin-marker line followed by a matching end-marker line — so a
    /// corrupted or commented-out marker isn't mistaken for a live install (a
    /// false positive would wrongly grandfather the agent `on`). Used by the
    /// grandfather migration to recognize pre-existing installs.
    static func isInstalled(
        configURL: URL = defaultConfigURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard
            fileManager.isReadableFile(atPath: configURL.path),
            let config = try? String(contentsOf: configURL, encoding: .utf8)
        else {
            return false
        }
        let lines = config.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == hookMarker
        }) else {
            return false
        }
        return lines[start...].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == hookEndMarker
        }
    }

    // Void return (dropped an unused Bool) so this directly witnesses the
    // HooksInstalling.ensureInstalledForCurrentUser(cliPath:environment:fileManager:)
    // requirement, whose signature Hermes already matches exactly.
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        try install(
            configURL: defaultConfigURL(environment: environment),
            allowlistURL: defaultAllowlistURL(environment: environment),
            cliPath: cliPath,
            fileManager: fileManager
        )
    }

    private static func installManagedBlock(in source: String, hermesHomeURL: URL) -> String {
        var text = removeManagedBlock(from: source)
        if text.isEmpty {
            text = "hooks:\n"
        }

        if let range = text.range(of: #"(?m)^hooks:\s*\{\}\s*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "hooks:")
        } else if let range = text.range(of: #"(?m)^hooks:\s*\[\]\s*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "hooks:")
        }

        let block = managedHookBlock(hermesHomeURL: hermesHomeURL)
        guard let hooksRange = text.range(of: #"(?m)^hooks:\s*$"#, options: .regularExpression) else {
            if !text.hasSuffix("\n") { text += "\n" }
            return text + "\nhooks:\n" + block
        }

        var insertionIndex = hooksRange.upperBound
        if insertionIndex < text.endIndex, text[insertionIndex] == "\n" {
            insertionIndex = text.index(after: insertionIndex)
        } else {
            text.insert("\n", at: insertionIndex)
            insertionIndex = text.index(after: insertionIndex)
        }
        text.insert(contentsOf: block, at: insertionIndex)
        return text
    }

    private static func managedHookBlock(hermesHomeURL: URL) -> String {
        var lines = ["  \(hookMarker)"]
        for event in events {
            lines.append("  \(event.name):")
            lines.append("    - command: \"\(yamlDoubleQuoted(hookCommand(hermesHomeURL: hermesHomeURL, event: event)))\"")
            lines.append("      timeout: \(event.timeout)")
        }
        lines.append("  \(hookEndMarker)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func removeManagedBlock(from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == hookMarker }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == hookEndMarker }) else {
            return source
        }
        lines.removeSubrange(start...end)
        return lines.joined(separator: "\n")
    }

    private static func installManagedScripts(
        hermesHomeURL: URL,
        cliPath: String,
        fileManager: FileManager
    ) throws -> Bool {
        let scriptsURL = managedScriptsDirectoryURL(hermesHomeURL: hermesHomeURL)
        try fileManager.createDirectory(at: scriptsURL, withIntermediateDirectories: true)

        var wrote = false
        var currentScriptNames = Set<String>()
        for event in events {
            let scriptURL = managedScriptURL(hermesHomeURL: hermesHomeURL, event: event)
            currentScriptNames.insert(scriptURL.lastPathComponent)
            let body = managedScriptBody(cliPath: cliPath, event: event)
            let data = Data(body.utf8)
            if (try? Data(contentsOf: scriptURL)) != data {
                try data.write(to: scriptURL, options: .atomic)
                wrote = true
            }
            let attributes = try? fileManager.attributesOfItem(atPath: scriptURL.path)
            let permissions = attributes?[.posixPermissions] as? NSNumber
            if permissions?.uint16Value != 0o755 {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
                wrote = true
            }
        }
        if try removeStaleManagedScripts(
            in: scriptsURL,
            currentScriptNames: currentScriptNames,
            fileManager: fileManager
        ) {
            wrote = true
        }
        return wrote
    }

    private static func removeStaleManagedScripts(
        in scriptsURL: URL,
        currentScriptNames: Set<String>,
        fileManager: FileManager
    ) throws -> Bool {
        var removed = false
        let fileNames = (try? fileManager.contentsOfDirectory(atPath: scriptsURL.path)) ?? []
        for fileName in fileNames where !currentScriptNames.contains(fileName) {
            let scriptURL = scriptsURL.appendingPathComponent(fileName, isDirectory: false)
            guard let script = try? String(contentsOf: scriptURL, encoding: .utf8),
                  script.contains(managedScriptMarker) || script.contains(legacyManagedScriptMarker) else {
                continue
            }
            try fileManager.removeItem(at: scriptURL)
            removed = true
        }
        return removed
    }

    private static func managedScriptBody(cliPath: String, event: Event) -> String {
        """
        #!/bin/sh
        # Zentty-managed Hermes hook.
        # Marker: \(managedScriptMarker)

        if [ "${ZENTTY_HERMES_HOOKS_DISABLED:-}" = "1" ]; then
            printf '{}\\n'
            exit 0
        fi

        ZENTTY_BIN=\(shellQuotedArgument(cliPath))
        if [ -z "$ZENTTY_BIN" ] || [ ! -x "$ZENTTY_BIN" ]; then
            ZENTTY_BIN="$(command -v zentty 2>/dev/null || true)"
        fi
        if [ -z "$ZENTTY_BIN" ]; then
            printf '{}\\n'
            exit 0
        fi

        zentty_resolve_hermes_pid() {
            candidate="${PPID:-}"
            while [ -n "$candidate" ] && [ "$candidate" -gt 1 ] 2>/dev/null; do
                command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
                case "$command_line" in
                    *"/hermes"*|*" hermes"*|*"hermes-agent"*)
                        printf '%s\\n' "$candidate"
                        return 0
                        ;;
                esac
                candidate="$(ps -p "$candidate" -o ppid= 2>/dev/null | tr -d ' ' || true)"
            done
            return 1
        }

        if [ -z "${ZENTTY_HERMES_PID:-}" ]; then
            if ZENTTY_RESOLVED_HERMES_PID="$(zentty_resolve_hermes_pid)"; then
                ZENTTY_HERMES_PID="$ZENTTY_RESOLVED_HERMES_PID"
                export ZENTTY_HERMES_PID
            fi
        fi

        "$ZENTTY_BIN" hermes-hook \(event.cliEvent) || printf '{}\\n'
        exit 0
        """
    }

    private static func hookCommand(hermesHomeURL: URL, event: Event) -> String {
        managedScriptURL(hermesHomeURL: hermesHomeURL, event: event).path
    }

    private static func managedScriptsDirectoryURL(hermesHomeURL: URL) -> URL {
        hermesHomeURL
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(managedScriptsDirectoryName, isDirectory: true)
    }

    private static func managedScriptURL(hermesHomeURL: URL, event: Event) -> URL {
        managedScriptsDirectoryURL(hermesHomeURL: hermesHomeURL)
            .appendingPathComponent("\(event.cliEvent).sh", isDirectory: false)
    }

    private static func readAllowlist(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["approvals": []]
        }
        return object
    }

    private static func mergedAllowlist(_ allowlist: [String: Any], hermesHomeURL: URL) -> [String: Any] {
        var next = allowlist
        var approvals = (next["approvals"] as? [[String: Any]]) ?? []
        approvals.removeAll { approval in
            guard let command = approval["command"] as? String else { return false }
            return isManagedHookCommand(command)
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        approvals.append(contentsOf: events.map { event in
            [
                "event": event.name,
                "command": hookCommand(hermesHomeURL: hermesHomeURL, event: event),
                "approved_at": timestamp,
            ]
        })
        next["approvals"] = approvals
        return next
    }

    private static func removeManagedApprovals(from allowlist: [String: Any]) -> [String: Any] {
        var next = allowlist
        let approvals = (next["approvals"] as? [[String: Any]]) ?? []
        next["approvals"] = approvals.filter { approval in
            guard let command = approval["command"] as? String else { return true }
            return !isManagedHookCommand(command)
        }
        return next
    }

    private static func isManagedHookCommand(_ command: String) -> Bool {
        command.contains("zentty hermes-hook")
            || command.contains("/hooks/\(managedScriptsDirectoryName)/")
            || command.contains("\\/hooks\\/\(managedScriptsDirectoryName)\\/")
    }

    private static func yamlDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuotedArgument(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - HooksInstalling conformance

extension HermesHooksInstaller: HooksInstalling {
    // ensureInstalledForCurrentUser(cliPath:environment:fileManager:) is
    // witnessed directly by the primary method above (now Void-returning).

    static func isInstalledForCurrentUser(environment: [String: String], fileManager: FileManager) -> Bool {
        isInstalled(configURL: defaultConfigURL(environment: environment), fileManager: fileManager)
    }

    static func uninstallForCurrentUser(environment: [String: String], fileManager: FileManager) throws {
        try uninstall(
            configURL: defaultConfigURL(environment: environment),
            allowlistURL: defaultAllowlistURL(environment: environment),
            fileManager: fileManager
        )
    }

    static func integrationConfigURL(environment: [String: String]) -> URL? {
        defaultConfigURL(environment: environment)
    }
}
