import Foundation

/// Re-emits canonical Agent Status Protocol events derived from a raw agent
/// hook payload. Conformers are stateless types whose only responsibility is
/// to inspect a single payload and return zero or more canonical JSON envelopes
/// that the CLI fan-out logic should additionally send.
///
/// Today only Grok needs this — the bench profile expects discrete
/// `task.progress`, `agent.needs-input`, and `session.start` records, and
/// `GrokCanonicalReEmitter` mints them in Swift. The protocol exists so the
/// CLI's fan-out site is generic: any future agent that needs the same
/// treatment registers a conformance and adds itself to the registry below.
protocol HookCanonicalReEmitter: Sendable {
    /// Canonical JSON envelopes to additionally send, one IPC request per
    /// element. Empty when the payload contains nothing worth re-emitting (or
    /// is already canonical itself).
    static func reEmissions(forHookPayload data: Data) -> [String]
}

/// Maps the value of a `--adapter=<name>` CLI flag to the appropriate
/// `HookCanonicalReEmitter`. Adding a new agent is a single-line change here.
enum HookCanonicalReEmitterRegistry {
    static let reEmitters: [String: any HookCanonicalReEmitter.Type] = [
        "grok": GrokCanonicalReEmitter.self,
        "agy": AgyCanonicalReEmitter.self,
        // Vibe deliberately has no CLI fan-out entry: the app-side
        // `vibeAdapter` (VibeCanonicalReEmitter) is the single source of
        // canonical Vibe status, so a re-emitter here would double-emit.
    ]

    /// Returns the re-emitter registered for the adapter encoded in `arg`
    /// (expected form: `--adapter=<name>`). Returns `nil` for unknown adapters
    /// or arguments that aren't the adapter flag.
    static func reEmitter(forAdapterArgument arg: String) -> (any HookCanonicalReEmitter.Type)? {
        guard let name = adapterName(from: arg) else { return nil }
        return reEmitters[name]
    }

    /// First re-emitter resolved from any `--adapter=<name>` argument in the
    /// list. Returns `nil` when no `--adapter=<name>` argument is present or
    /// the named adapter has no registered re-emitter.
    static func reEmitter(forArguments arguments: [String]) -> (any HookCanonicalReEmitter.Type)? {
        for arg in arguments {
            if let reEmitter = reEmitter(forAdapterArgument: arg) {
                return reEmitter
            }
        }
        return nil
    }

    private static func adapterName(from arg: String) -> String? {
        guard arg.hasPrefix("--adapter=") else { return nil }
        let name = String(arg.dropFirst("--adapter=".count))
        return name.isEmpty ? nil : name
    }
}
