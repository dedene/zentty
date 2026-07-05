import Foundation
import os

/// Shared logger for agent-integration consent/persistence paths. These are
/// best-effort in-app operations that must log and continue rather than crash
/// (see AGENTS.md error handling).
let agentIntegrationLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgentIntegration")

/// User-facing state of an agent's Zentty integration.
///
/// - `ask`: undecided. Only meaningful for *persistent* (config-modifying) agents
///   that have never been consented; their first interactive launch shows the
///   consent panel. Ephemeral agents are never `ask` (their default is `on`).
/// - `on`: integration enabled. Persistent agents have their hooks installed;
///   ephemeral agents get their per-launch shim/overlay.
/// - `off`: integration disabled. The agent launches with no Zentty hooks at all
///   (direct passthrough). Persistent agents have had their on-disk hooks removed.
enum AgentIntegrationState: String, Codable, Equatable, Sendable, CaseIterable {
    case ask
    case on
    case off
}

/// How an agent's integration is delivered, which determines its consent rules.
///
/// - `persistent`: Zentty writes hook entries into the user's on-disk config.
///   These are consent-gated (tri-state, default `ask`).
/// - `ephemeral`: hooks are passed via CLI args or a per-pane runtime overlay;
///   the user's config is never touched. Enabled by default (binary on/off).
enum AgentIntegrationClass: Equatable, Sendable {
    case persistent
    case ephemeral
}

/// What `AgentLaunchBootstrap.makePlan` should do for an agent once consent
/// (if any) has been resolved.
enum AgentIntegrationDecision: Equatable, Sendable {
    /// Install / inject hooks as normal (the historical behavior).
    case proceed
    /// Integration disabled — produce a direct passthrough plan, no hooks.
    case off
    /// Unconsented persistent agent spawned during a workspace restore. Launch
    /// degraded (no hooks) but leave the stored state at `ask` so the next
    /// *manual* launch still prompts.
    case suppressedByRestore
}

/// Handler-level resolution of an agent's launch gate from its stored state,
/// computed before `makePlan` runs.
enum AgentIntegrationGate: Equatable, Sendable {
    case proceed
    case off
    case suppressedByRestore
    /// Persistent + `ask` + interactive (non-restore) launch: the IPC handler
    /// must respond `consentRequired` and show the consent panel before it can
    /// resolve a `makePlan` decision.
    case needsConsent

    /// The `makePlan` decision for gates that bypass the consent panel.
    /// `needsConsent` returns `nil` — it must first resolve via the panel.
    var immediateDecision: AgentIntegrationDecision? {
        switch self {
        case .proceed: return .proceed
        case .off: return .off
        case .suppressedByRestore: return .suppressedByRestore
        case .needsConsent: return nil
        }
    }
}

extension AgentBootstrapTool {
    /// Whether this agent's integration writes to the user's on-disk config.
    ///
    /// Persistent agents install hooks inside `AgentLaunchBootstrap.makePlan`
    /// (amp/cursor/droid/grok/agy/hermes). Everything else uses CLI args or a
    /// per-pane overlay and leaves the user's config untouched.
    var integrationClass: AgentIntegrationClass {
        switch self {
        case .amp, .cursor, .droid, .grok, .agy, .hermes, .vibe:
            return .persistent
        case .claude, .codex, .copilot, .gemini, .kimi, .opencode, .pi, .omp, .smallHarness:
            return .ephemeral
        }
    }

    /// The state used when the user has never configured this agent: persistent
    /// agents start `ask` (prompt on first use), ephemeral agents start `on`.
    var defaultIntegrationState: AgentIntegrationState {
        integrationClass == .persistent ? .ask : .on
    }

    /// The display/icon counterpart in `AgentTool` (used by Settings + the
    /// consent panel for the agent name and menu-bar-style icon).
    var agentTool: AgentTool {
        switch self {
        case .amp: return .amp
        case .claude: return .claudeCode
        case .codex: return .codex
        case .copilot: return .copilot
        case .cursor: return .cursor
        case .droid: return .droid
        case .gemini: return .gemini
        case .kimi: return .kimi
        case .opencode: return .openCode
        case .pi: return .pi
        case .omp: return .omp
        case .grok: return .grok
        case .agy: return .agy
        case .hermes: return .hermes
        case .vibe: return .vibe
        case .smallHarness: return .smallHarness
        }
    }

    /// Human-readable name, e.g. "Claude Code", "Antigravity".
    var integrationDisplayName: String { agentTool.displayName }

    /// The config file/dir Zentty modifies for this agent — used by the consent
    /// panel and the Settings "Reveal in Finder" recovery action. `nil` for
    /// ephemeral agents, which never touch the user's config.
    var integrationConfigURL: URL? {
        switch self {
        case .amp:
            return AmpPluginInstaller
                .defaultUserConfigHomeURL(environment: ProcessInfo.processInfo.environment)
                .appendingPathComponent("amp/plugins/\(AmpPluginInstaller.pluginFileName)")
        case .cursor: return CursorHooksInstaller.defaultUserHooksURL()
        case .droid: return DroidHooksInstaller.defaultUserSettingsURL()
        case .grok: return GrokHooksInstaller.defaultUserHooksURL()
        case .agy: return AgyHooksInstaller.defaultUserHooksFileURL()
        case .hermes: return HermesHooksInstaller.defaultConfigURL()
        case .vibe: return VibeHooksInstaller.defaultUserHooksFileURL()
        case .claude, .codex, .copilot, .gemini, .kimi, .opencode, .pi, .omp, .smallHarness:
            return nil
        }
    }

    /// User-facing, tilde-abbreviated path of `integrationConfigURL` — shown in
    /// the consent panel. `nil` for ephemeral agents.
    var integrationConfigPathDisplay: String? {
        integrationConfigURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }
}

/// Pure, I/O-free resolution of integration consent. The IPC handler and tests
/// both drive this; persistence and UI live elsewhere.
enum AgentIntegrationConsent {
    /// Persistent (config-modifying) agents, in Settings display order.
    static let persistentTools: [AgentBootstrapTool] = [.amp, .cursor, .droid, .grok, .agy, .hermes, .vibe]
    /// Ephemeral (built-in) agents, in Settings display order.
    static let ephemeralTools: [AgentBootstrapTool] = [.claude, .codex, .copilot, .gemini, .kimi, .opencode, .pi, .omp, .smallHarness]
    /// All known agents, persistent group first.
    static let allTools: [AgentBootstrapTool] = persistentTools + ephemeralTools

    /// The effective state for a tool given what's stored in config (or its
    /// class default when unset).
    static func effectiveState(
        for tool: AgentBootstrapTool,
        storedState: AgentIntegrationState?
    ) -> AgentIntegrationState {
        storedState ?? tool.defaultIntegrationState
    }

    /// Resolve the launch gate for a tool from its stored state and whether this
    /// launch is part of a workspace restore.
    static func gate(
        for tool: AgentBootstrapTool,
        storedState: AgentIntegrationState?,
        isRestore: Bool
    ) -> AgentIntegrationGate {
        switch effectiveState(for: tool, storedState: storedState) {
        case .on:
            return .proceed
        case .off:
            return .off
        case .ask:
            // Ephemeral agents default to `on`, so a stray `ask` on one is a
            // data anomaly; treat it as proceed rather than blocking on a panel
            // that has nothing to install.
            guard tool.integrationClass == .persistent else { return .proceed }
            return isRestore ? .suppressedByRestore : .needsConsent
        }
    }

    /// Map a user's consent-panel answer (or a Settings toggle that runs the
    /// same panel) to the `makePlan` decision.
    static func decision(forConsentAnswer state: AgentIntegrationState) -> AgentIntegrationDecision {
        state == .on ? .proceed : .off
    }
}

/// The single place that maps a persistent agent to its on-disk install
/// detector and remover. The grandfather migration and the Settings toggle both
/// route through here, so adding a new persistent agent means touching exactly
/// one switch — and `AgentIntegrationConsentTests` asserts every persistent tool
/// resolves handlers (and every ephemeral tool does not), turning a forgotten
/// branch into a test failure rather than a silent on-disk no-op.
enum AgentIntegrationHooks {
    struct Handlers {
        let isInstalled: () -> Bool
        let uninstall: () throws -> Void
    }

    /// On-disk handlers for a persistent agent, or `nil` for ephemeral agents
    /// (which write nothing to the user's config).
    static func handlers(for tool: AgentBootstrapTool) -> Handlers? {
        switch tool {
        case .amp:
            return Handlers(
                isInstalled: { AmpPluginInstaller.isInstalled() },
                uninstall: { try AmpPluginInstaller.uninstall() }
            )
        case .cursor:
            return Handlers(
                isInstalled: { CursorHooksInstaller.isInstalled() },
                uninstall: { try CursorHooksInstaller.uninstall(at: CursorHooksInstaller.defaultUserHooksURL()) }
            )
        case .droid:
            return Handlers(
                isInstalled: { DroidHooksInstaller.isInstalled() },
                uninstall: { try DroidHooksInstaller.uninstall(at: DroidHooksInstaller.defaultUserSettingsURL()) }
            )
        case .grok:
            return Handlers(
                isInstalled: { GrokHooksInstaller.isInstalled() },
                uninstall: { try GrokHooksInstaller.uninstall() }
            )
        case .agy:
            return Handlers(
                isInstalled: { AgyHooksInstaller.isInstalled() },
                uninstall: { try AgyHooksInstaller.uninstall() }
            )
        case .hermes:
            return Handlers(
                isInstalled: { HermesHooksInstaller.isInstalled() },
                uninstall: { try HermesHooksInstaller.uninstall() }
            )
        case .vibe:
            return Handlers(
                isInstalled: { VibeHooksInstaller.isInstalled() },
                uninstall: { try VibeHooksInstaller.uninstall() }
            )
        case .claude, .codex, .copilot, .gemini, .kimi, .opencode, .pi, .omp, .smallHarness:
            return nil
        }
    }

    /// Whether the tool's hooks are currently installed on disk. Ephemeral
    /// agents are never installed.
    static func isInstalled(_ tool: AgentBootstrapTool) -> Bool {
        handlers(for: tool)?.isInstalled() ?? false
    }

    /// Remove the tool's hooks from disk. No-op for ephemeral agents.
    static func uninstall(_ tool: AgentBootstrapTool) throws {
        try handlers(for: tool)?.uninstall()
    }
}

extension Notification.Name {
    /// Posted (in-process) when a persistent agent's on-disk hooks may have just
    /// changed — e.g. a pane launch reinstalled them via `AgentLaunchBootstrap`.
    /// The Agents settings panel observes this to re-check `isInstalled` and clear
    /// a stale "Hooks missing" warning while it is already open.
    static let agentIntegrationHooksDidChange = Notification.Name("AgentIntegrationHooksDidChange")
}
