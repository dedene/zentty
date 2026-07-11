import Foundation
import os

private let vibeHooksLogger = Logger(subsystem: "be.zenjoy.zentty", category: "VibeHooksInstaller")

/// Installs Zentty's Mistral Vibe status hooks into the user's Vibe configuration
/// so the running Zentty app can observe session lifecycle and tool-use events.
///
/// Mistral Vibe reads hooks from `~/.vibe/hooks.toml` (user-global). Zentty's installer
/// manages a hooks.toml file at that path, merging Zentty-managed hooks with any
/// existing user hooks. Hooks are only installed when the user grants consent
/// via the integration consent panel.
///
/// Hook Events Registered:
/// - `post_agent_turn` - Fires after every assistant turn, used for running/idle detection
/// - `before_tool` with matcher `*` - Fires before tool execution, used for needs-input detection
/// - `after_tool` with matcher `*` - Fires after tool execution, used for input-resolved detection
///
/// Each hook invokes: `<resolved-zentty-cli> ipc agent-event --adapter=vibe`
/// (the absolute CLI path is baked in at install time).
///
/// Note: Mistral Vibe's hooks are experimental and gated behind `enable_experimental_hooks = true`
/// in the user's config. The consent panel mentions this requirement.
enum VibeHooksInstaller {

    /// Marker present in every hook command we write. Used by `uninstall` to
    /// recognize and remove only our entries, and by tests for assertions.
    static let hookMarker: String = "ipc agent-event --adapter=vibe"

    /// Substring that uniquely identifies our managed block in the TOML file.
    /// Deliberately omits the trailing bracket so it matches both the
    /// `# [Zentty Managed Hooks - Begin]` and `- End]` delimiter lines. Used by
    /// `isInstalled` and the consent panel; `internal` so tests can assert on it.
    static let zenttyBlockMarker: String = "# [Zentty Managed Hooks"

    /// File name of the hooks config in the Vibe home directory.
    private static let hooksFileName = "hooks.toml"

    /// Marker file used to detect "first install" so we can show a one-time
    /// user-visible message. Lives next to hooks.toml.
    private static let firstRunMarkerName = ".zentty-vibe-hooks-installed"

    // MARK: - Paths

    /// Returns the user's Vibe config directory (`~/.vibe/`).
    static func defaultUserVibeHomeURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".vibe", isDirectory: true)
    }

    /// Returns `~/.vibe/hooks.toml`.
    static func defaultUserHooksFileURL(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    ) -> URL {
        defaultUserVibeHomeURL(home: home)
            .appendingPathComponent(hooksFileName, isDirectory: false)
    }

    /// Returns the marker file URL next to hooks.toml.
    private static func firstRunMarkerURL(
        hooksFileURL: URL
    ) -> URL {
        hooksFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(firstRunMarkerName, isDirectory: false)
    }

    // MARK: - Hook Configuration

    /// Canonical hook entries Zentty manages. These are appended to the user's
    /// hooks.toml under a marked block. Order is preserved for deterministic output.
    private static func managedHookEntries(cliPath: String) -> [String] {
        // Bake the resolved CLI path into each command so hooks fire even when
        // the agent process has no ZENTTY_CLI_BIN in its environment.
        let command = "\(cliPath) \(hookMarker)"
        return [
            """
            [[hooks]]
            name = "zentty-post-agent-turn"
            type = "post_agent_turn"
            command = "\(command)"
            timeout = 15.0
            description = "Zentty: Track Mistral Vibe session state"
            """,
            """
            [[hooks]]
            name = "zentty-before-tool"
            type = "before_tool"
            match = "*"
            command = "\(command)"
            timeout = 60.0
            description = "Zentty: Track Mistral Vibe tool calls"
            """,
            """
            [[hooks]]
            name = "zentty-after-tool"
            type = "after_tool"
            match = "*"
            command = "\(command)"
            timeout = 60.0
            description = "Zentty: Track Mistral Vibe tool completion"
            """,
        ]
    }

    /// The full Zentty-managed block as a single TOML string, with marker comments.
    private static func zenttyManagedBlock(cliPath: String) -> String {
        let entries = managedHookEntries(cliPath: cliPath).joined(separator: "\n")
        return """
        \n# [Zentty Managed Hooks - Begin]
        # DO NOT EDIT: These hooks are managed by Zentty.
        # Run `zentty uninstall vibe-hooks` to remove.
        # Marker: \(hookMarker)
        \(entries)
        # [Zentty Managed Hooks - End]
        """
    }

    // MARK: - Public Surface

    /// Returns true if Zentty-managed Vibe hooks are currently installed in the
    /// default user hooks file. Used by the grandfather migration and Settings UI.
    static func isInstalled(
        hooksFileURL: URL = defaultUserHooksFileURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: hooksFileURL.path) else {
            return false
        }
        
        guard let content = try? String(contentsOf: hooksFileURL, encoding: .utf8) else {
            return false
        }
        
        // Check for our marker comment
        return content.contains(zenttyBlockMarker)
    }

    /// Installs Zentty's hook entries into `~/.vibe/hooks.toml`, preserving any
    /// existing user hooks. Creates a marker file and prints a one-time banner on
    /// first successful install.
    ///
    /// - Parameters:
    ///   - hooksFileURL: target hooks.toml file
    ///   - cliPath: path to the `zentty` binary to bake into hook commands
    ///   - fileManager: injection point for tests
    /// - Returns: `true` when the file content actually changed; `false` when
    ///   the on-disk hooks already matched
    @discardableResult
    static func install(
        hooksFileURL: URL = defaultUserHooksFileURL(),
        cliPath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        vibeHooksLogger.info("Installing Mistral Vibe hooks at \(hooksFileURL.path)")

        let directoryURL = hooksFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Resolve symlinks before writing
        let resolvedURL = resolvedHooksFileURL(hooksFileURL, fileManager: fileManager)

        var existingContent = ""
        if fileManager.fileExists(atPath: resolvedURL.path) {
            existingContent = try String(contentsOf: resolvedURL, encoding: .utf8)
        }

        // Remove any existing Zentty-managed block to avoid duplication
        let cleanedContent = removeZenttyManagedBlock(from: existingContent)

        // Build new content: existing user hooks + our managed block
        let newContent = buildHooksFileContent(userContent: cleanedContent, cliPath: cliPath)

        // Only write if content changed
        if newContent == existingContent && fileManager.fileExists(atPath: resolvedURL.path) {
            vibeHooksLogger.info("Vibe hooks already up to date at \(resolvedURL.path)")
            return false
        }

        try newContent.write(to: resolvedURL, atomically: true, encoding: .utf8)
        vibeHooksLogger.info("Vibe hooks installed at \(resolvedURL.path)")
        return true
    }

    /// Removes Zentty-managed hook entries from `~/.vibe/hooks.toml`. Also removes
    /// the file if no other content remains. Best-effort — missing files are not
    /// an error.
    static func uninstall(
        hooksFileURL: URL = defaultUserHooksFileURL(),
        fileManager: FileManager = .default
    ) throws {
        vibeHooksLogger.info("Uninstalling Mistral Vibe hooks from \(hooksFileURL.path)")

        let resolvedURL = resolvedHooksFileURL(hooksFileURL, fileManager: fileManager)

        guard fileManager.fileExists(atPath: resolvedURL.path) else {
            return
        }

        let content = try String(contentsOf: resolvedURL, encoding: .utf8)
        let cleanedContent = removeZenttyManagedBlock(from: content)

        if cleanedContent.isEmpty || cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try fileManager.removeItem(at: resolvedURL)
            vibeHooksLogger.info("Removed hooks file (was Zentty-only) at \(resolvedURL.path)")
        } else {
            try cleanedContent.write(to: resolvedURL, atomically: true, encoding: .utf8)
            vibeHooksLogger.info("Removed Zentty hooks from \(resolvedURL.path)")
        }

        // Also clean up the first-run marker
        let markerURL = firstRunMarkerURL(hooksFileURL: hooksFileURL)
        try? fileManager.removeItem(at: markerURL)
    }

    /// Ensures Zentty-managed Mistral Vibe hooks exist for the current user.
    /// Idempotent and cheap — only writes if our content has drifted.
    /// Returns true if this was the first install we noticed (and printed the banner).
    @discardableResult
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> Bool {
        let hooksFileURL = defaultUserHooksFileURL(home: home)
        let markerURL = firstRunMarkerURL(hooksFileURL: hooksFileURL)
        let alreadyAnnounced = fileManager.fileExists(atPath: markerURL.path)

        let didWrite = try install(hooksFileURL: hooksFileURL, cliPath: cliPath, fileManager: fileManager)

        guard !alreadyAnnounced, didWrite else {
            return false
        }

        // Best-effort marker + banner
        try? Data().write(to: markerURL)
        FileHandle.standardError.write(Data("""

        [Zentty] Installed Mistral Vibe hooks at \(hooksFileURL.path).
                When Vibe is launched through Zentty, hooks fire automatically —
                Zentty enables Vibe's experimental hooks for you. To use them
                outside Zentty, set `enable_experimental_hooks = true` in
                ~/.vibe/config.toml (or export VIBE_ENABLE_EXPERIMENTAL_HOOKS=true).
                Run `zentty uninstall vibe-hooks` to remove.

        """.utf8))
        return true
    }

    // MARK: - Internals

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

    /// Builds the complete hooks.toml content: user content + Zentty-managed block.
    private static func buildHooksFileContent(userContent: String, cliPath: String) -> String {
        if userContent.isEmpty {
            return zenttyManagedBlock(cliPath: cliPath)
        }

        // Ensure there's a blank line between user content and our block
        let separator = userContent.hasSuffix("\n") ? "" : "\n"
        return userContent + separator + zenttyManagedBlock(cliPath: cliPath)
    }

    /// Removes the Zentty-managed block from content, preserving user hooks.
    private static func removeZenttyManagedBlock(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)

        var resultLines: [String] = []
        var inZenttyBlock = false

        for line in lines {
            if inZenttyBlock {
                // Inside our block: drop every line, exiting on the end marker.
                // Checking the end marker first (before the begin check below)
                // is what keeps user hooks placed *after* our block intact.
                if line.contains("# [Zentty Managed Hooks - End]") {
                    inZenttyBlock = false
                }
                continue
            }

            // Outside our block: enter it only on the begin marker.
            if line.contains("# [Zentty Managed Hooks - Begin]") {
                inZenttyBlock = true
                continue
            }

            resultLines.append(line)
        }

        return resultLines.joined(separator: "\n")
    }
}

// MARK: - HooksInstalling conformance

extension VibeHooksInstaller: HooksInstalling {
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        environment: [String: String],
        fileManager: FileManager
    ) throws {
        _ = try ensureInstalledForCurrentUser(
            cliPath: cliPath,
            home: environment["HOME"] ?? NSHomeDirectory(),
            fileManager: fileManager
        )
    }

    static func isInstalledForCurrentUser(environment: [String: String], fileManager: FileManager) -> Bool {
        isInstalled(hooksFileURL: defaultUserHooksFileURL(home: environment["HOME"] ?? NSHomeDirectory()), fileManager: fileManager)
    }

    static func uninstallForCurrentUser(environment: [String: String], fileManager: FileManager) throws {
        try uninstall(hooksFileURL: defaultUserHooksFileURL(home: environment["HOME"] ?? NSHomeDirectory()), fileManager: fileManager)
    }

    static func integrationConfigURL(environment: [String: String]) -> URL? {
        defaultUserHooksFileURL(home: environment["HOME"] ?? NSHomeDirectory())
    }
}
