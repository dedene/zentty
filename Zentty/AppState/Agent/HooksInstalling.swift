import Foundation

// MARK: - Hooks installer seam

/// Uniform surface over the per-agent hooks installers. Each installer keeps
/// its own richer, test-pinned API; the conformance in each installer file
/// adapts those divergent internals (some derive `cliPath` from the
/// environment, some take a `home` or full `environment`, Grok/Agy/Vibe return
/// a "did announce" Bool) to this common shape.
///
/// Foundation-only by construction: this file is compiled into the ZenttyCLI
/// tool target as well as the app, so it must never reference app-only types
/// such as `AgentStatusPayload`.
protocol HooksInstalling {
    /// Idempotently install (or refresh) the tool's hooks for the current user.
    static func ensureInstalledForCurrentUser(
        cliPath: String,
        environment: [String: String],
        fileManager: FileManager
    ) throws

    /// Whether the tool's managed hooks are currently present on disk.
    static func isInstalledForCurrentUser(
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool

    /// Remove the tool's managed hooks for the current user.
    static func uninstallForCurrentUser(
        environment: [String: String],
        fileManager: FileManager
    ) throws

    /// The user-facing config file the tool's hooks live in, if any.
    static func integrationConfigURL(environment: [String: String]) -> URL?
}

/// Persistent-agent installers keyed by bootstrap tool. The plugin-based Amp is
/// intentionally absent — it writes through its own plugin surface. Modern Kimi
/// installs a persistent managed block into ~/.kimi-code/config.toml, so it is
/// registered here; legacy Kimi still uses an ephemeral --config-file overlay
/// but shares the same tool entry.
enum AgentHooksInstallerRegistry {
    static let installers: [AgentBootstrapTool: any HooksInstalling.Type] = [
        .cursor: CursorHooksInstaller.self,
        .droid: DroidHooksInstaller.self,
        .grok: GrokHooksInstaller.self,
        .agy: AgyHooksInstaller.self,
        .hermes: HermesHooksInstaller.self,
        .vibe: VibeHooksInstaller.self,
        .kimi: KimiHooksInstaller.self,
    ]

    static func installer(for tool: AgentBootstrapTool) -> (any HooksInstalling.Type)? {
        installers[tool]
    }
}
