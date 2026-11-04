import Foundation

/// What `disable(deleteIndex:completion:)` did.
enum AgentHistoryDisableOutcome: Equatable, Sendable {
    /// Agent History is off; the index is kept.
    case turnedOff
    /// The directory and the consent are gone.
    case deleted
    /// Another Zentty instance runs Agent History on this index (owner or standby): nothing was
    /// deleted, consent is kept. Quitting it, or turning Agent History off there, lets it through.
    case refusedAnotherInstance
    /// The directory could not be deleted (or locked for it). Consent is reset only when the
    /// delete was attempted. Without a delete: `state.json` couldn't be saved, so Agent History
    /// is off only until the next launch.
    case failed
}

/// Whether a change to `state.json` (History or a source on or off) was saved.
enum AgentHistoryStateChangeOutcome: Equatable, Sendable {
    case saved
    /// Took effect, but `state.json` couldn't be written: it may come back after a restart.
    /// Only a change that takes access away ends up here.
    case appliedButNotSaved
    /// `state.json` couldn't be written, so nothing changed.
    case notSaved
    /// config.toml can't be read or saved, so the excluded folders aren't certain: nothing was
    /// turned on. Only a change that grants access ends up here.
    case refusedConfigUnreadable
}
