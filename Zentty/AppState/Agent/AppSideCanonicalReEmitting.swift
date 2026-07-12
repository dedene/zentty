import Foundation

// MARK: - App-side canonical re-emitter seam

/// App-side counterpart to the CLI `HookCanonicalReEmitter` family. Where the
/// CLI re-emitters drive the fan-out that fires on the wire, this protocol
/// unifies the re-emitters the app consumes in-process.
///
/// Vibe is deliberately kept OUT of the CLI `HookCanonicalReEmitterRegistry`:
/// its canonical envelopes are produced inside `vibeAdapter` (app side) and
/// registering it CLI-side too would double-emit (see the note in
/// HookCanonicalReEmitter.swift). This protocol lives in an app-only file and
/// must not be added to the ZenttyCLI target.
protocol AppSideCanonicalReEmitting {
    static func canonicalPayloads(from hookPayload: [String: Any]) -> [[String: Any]]
}

extension VibeCanonicalReEmitter: AppSideCanonicalReEmitting {}
