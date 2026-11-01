import Foundation

/// Which sessions a palette or CLI search covers: every project, or one project.
enum AgentHistoryScope: Hashable, Sendable {
    case all
    case project(AgentHistoryProjectScope)
}

/// One project, identified by its canonical main repo root, else its repo root, else the pane's
/// working directory.
struct AgentHistoryProjectScope: Hashable, Sendable {
    /// Canonical main repo root, else repo root, else cwd.
    let key: String
    /// Basename of `key`.
    let displayName: String
    /// False when `key` is `/`, the home directory or an ancestor of it: such a scope admits
    /// repo-less sessions with exactly that cwd only, never everything below it.
    let allowsCWDPrefix: Bool
}
