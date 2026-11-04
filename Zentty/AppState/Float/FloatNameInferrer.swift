import Foundation

/// Infers a stable float name from a stream of "command executed" events.
///
/// Once a name has been produced, subsequent observations are no-ops. Common
/// shell binaries are ignored so the first non-shell command in a freshly
/// spawned float drives the name (e.g. `lazygit`, `claude`, `tig`).
struct FloatNameInferrer: Equatable, Sendable {
    private static let shellCommands: Set<String> = [
        "bash", "zsh", "fish", "nu", "sh", "dash", "ksh", "tcsh", "csh",
    ]

    private(set) var inferredName: FloatName?

    init() {}

    /// Returns the inferred name if one was just produced, else `nil`.
    /// Subsequent calls after a name is set are no-ops.
    mutating func observe(command: String) -> FloatName? {
        guard inferredName == nil else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstToken = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        let basename = (firstToken as NSString).lastPathComponent

        guard !Self.shellCommands.contains(basename.lowercased()) else { return nil }

        let name = FloatName(value: basename)
        inferredName = name
        return name
    }
}
