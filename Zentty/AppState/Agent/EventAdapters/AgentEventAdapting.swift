import Foundation

// MARK: - App-side event adapter seam

/// A per-agent event adapter. Each conformer owns the mapping from an agent's
/// raw hook payload to canonical `AgentStatusPayload`s, plus two pieces of
/// dispatch metadata the bridge needs: the exact `--adapter=<name>` value it
/// answers to, and whether a thrown error should be swallowed (fail-open) or
/// surfaced as a non-zero exit (fail-closed).
///
/// Conformers forward verbatim to the existing `AgentEventBridge.<agent>Adapter`
/// static funcs so behavior — and the test call sites that pin those funcs —
/// stay unchanged.
protocol AgentEventAdapting {
    /// Exact `--adapter=<name>` value, e.g. `"codex-notify"`, `"small-harness"`.
    static var adapterName: String { get }

    /// When true, a thrown error is swallowed and the CLI still exits success.
    /// Replaces the hardcoded allowlist previously inlined in `run`.
    static var suppressesErrors: Bool { get }

    /// - Parameter positionalArguments: the remaining args with `--adapter=` flags
    ///   removed, exactly as `AgentEventBridge.run` computes them. Adapters that
    ///   take a default event name read `positionalArguments.first`.
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload]
}

/// Maps `--adapter=<name>` values to their conforming adapter types.
enum AgentEventAdapterRegistry {
    static let adapters: [String: any AgentEventAdapting.Type] = [
        ClaudeEventAdapter.adapterName: ClaudeEventAdapter.self,
        CopilotEventAdapter.adapterName: CopilotEventAdapter.self,
        CodexEventAdapter.adapterName: CodexEventAdapter.self,
        SmallHarnessEventAdapter.adapterName: SmallHarnessEventAdapter.self,
        CodexNotifyEventAdapter.adapterName: CodexNotifyEventAdapter.self,
        DroidEventAdapter.adapterName: DroidEventAdapter.self,
        GeminiEventAdapter.adapterName: GeminiEventAdapter.self,
        CursorEventAdapter.adapterName: CursorEventAdapter.self,
        KimiEventAdapter.adapterName: KimiEventAdapter.self,
        GrokEventAdapter.adapterName: GrokEventAdapter.self,
        AgyEventAdapter.adapterName: AgyEventAdapter.self,
        HermesEventAdapter.adapterName: HermesEventAdapter.self,
        VibeEventAdapter.adapterName: VibeEventAdapter.self,
    ]

    static func adapter(named name: String) -> (any AgentEventAdapting.Type)? {
        adapters[name]
    }
}
