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
            let nextConfig = removeManagedHooks(from: existingConfig)
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

    /// True when the Hermes config currently contains Zentty-managed hooks:
    /// either a well-formed marker block, or bare entries pointing at our
    /// managed scripts. Hermes re-serializes `config.yaml` on save, which drops
    /// the marker comments, so the bare form is the common one in the wild.
    /// Mirrors `removeManagedHooks` exactly, so a corrupted or commented-out
    /// marker isn't mistaken for a live install. Used by the grandfather
    /// migration and the Settings panel.
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
        return removeManagedHooks(from: config) != config
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
        var text = removeManagedHooks(from: source)
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

    /// Strips every Zentty-managed hook from a Hermes config: the marker block
    /// we write, plus any marker-less managed entries left after Hermes
    /// rewrote the file. Foreign hooks are left untouched.
    static func removeManagedHooks(from source: String) -> String {
        removeUnmarkedManagedHooks(from: removeManagedBlock(from: source))
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

    /// Line-based walk of the top-level `hooks:` mapping (block style, with or
    /// without indented sequences). Drops list items whose lines reference a
    /// managed script, then drops event keys left without items. An emptied
    /// mapping becomes `hooks: {}` so Hermes still reads a mapping.
    private static func removeUnmarkedManagedHooks(from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let hooksIndex = lines.firstIndex(where: {
            $0.range(of: #"^hooks:\s*$"#, options: .regularExpression) != nil
        }) else {
            return source
        }

        var sectionEnd = hooksIndex + 1
        while sectionEnd < lines.count,
              isBlankOrComment(lines[sectionEnd]) || indentation(of: lines[sectionEnd]) > 0 {
            sectionEnd += 1
        }
        let section = Array(lines[(hooksIndex + 1)..<sectionEnd])
        guard let keyIndent = section.first(where: { !isBlankOrComment($0) }).map(indentation(of:)) else {
            return source
        }

        // Event spans: a key line at keyIndent through the line before the
        // next key at keyIndent (sequence items may sit at keyIndent too).
        var keptSection: [String] = []
        var index = 0
        var changed = false
        while index < section.count {
            let line = section[index]
            guard !isBlankOrComment(line), indentation(of: line) == keyIndent, !isSequenceItem(line) else {
                keptSection.append(line)
                index += 1
                continue
            }
            var eventEnd = index + 1
            while eventEnd < section.count {
                let next = section[eventEnd]
                if !isBlankOrComment(next), indentation(of: next) <= keyIndent, !isSequenceItem(next) {
                    break
                }
                eventEnd += 1
            }
            let body = Array(section[(index + 1)..<eventEnd])
            let (keptBody, removedItems, keptItems) = removeManagedItems(from: body)
            if removedItems > 0 {
                changed = true
                if keptItems > 0 {
                    keptSection.append(line)
                    keptSection.append(contentsOf: keptBody)
                }
            } else {
                keptSection.append(line)
                keptSection.append(contentsOf: body)
            }
            index = eventEnd
        }

        guard changed else {
            return source
        }
        if keptSection.allSatisfy(isBlankOrComment) {
            lines[hooksIndex] = "hooks: {}"
        }
        lines.replaceSubrange((hooksIndex + 1)..<sectionEnd, with: keptSection)
        return lines.joined(separator: "\n")
    }

    private static func removeManagedItems(from body: [String]) -> (kept: [String], removed: Int, keptItems: Int) {
        var kept: [String] = []
        var removed = 0
        var keptItems = 0
        var index = 0
        while index < body.count {
            let line = body[index]
            guard isSequenceItem(line) else {
                kept.append(line)
                index += 1
                continue
            }
            let itemIndent = indentation(of: line)
            var itemEnd = index + 1
            while itemEnd < body.count {
                let next = body[itemEnd]
                if !isBlankOrComment(next), indentation(of: next) <= itemIndent {
                    break
                }
                itemEnd += 1
            }
            let item = body[index..<itemEnd]
            if item.contains(where: { !isBlankOrComment($0) && isManagedHookCommand($0) }) {
                removed += 1
            } else {
                keptItems += 1
                kept.append(contentsOf: item)
            }
            index = itemEnd
        }
        return (kept, removed, keptItems)
    }

    private static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func isSequenceItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "-" || trimmed.hasPrefix("- ")
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
