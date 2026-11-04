import Foundation

/// Everything the resume path needs about one session, whether it came from the history index
/// or from a live pane. Values are untrusted until the command builder validates them.
struct AgentHistoryResumeSource: Equatable, Sendable {
    /// The `sessions.id` row, or nil for a live pane that has no indexed row to record opens on.
    var sessionRowID: Int64?
    var agent: AgentHistoryAgent
    var nativeSessionID: String
    var title: String
    var workingDirectory: String?
    var repoRoot: String?
    var mainRepoRoot: String?
    var branch: String?
    var model: String?
    var effort: String?
    var generation: String?
    /// The history root the session was read from (e.g. an alternate Claude config directory).
    var sourceRoot: String?

    var key: AgentHistorySessionKey {
        AgentHistorySessionKey(agent: agent, nativeID: nativeSessionID)
    }
}

extension AgentHistoryResumeSource {
    init(summary: AgentHistorySessionSummary) {
        self.init(
            sessionRowID: summary.id,
            agent: summary.agent,
            nativeSessionID: summary.nativeID,
            title: summary.title,
            workingDirectory: summary.cwd,
            repoRoot: summary.repoRoot,
            mainRepoRoot: summary.mainRepoRoot,
            branch: summary.branch,
            model: summary.model,
            effort: summary.effort,
            generation: summary.generation,
            sourceRoot: summary.sourceRoot.isEmpty ? nil : summary.sourceRoot
        )
    }
}
