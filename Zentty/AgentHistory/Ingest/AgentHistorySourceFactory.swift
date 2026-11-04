import Foundation

/// Builds one history source per discovered root.
///
/// Stat-only: discovery goes through `AgentHistoryRootLocator`, and the adapters' initializers
/// only compute paths, so building sources never opens a transcript or database. The indexer
/// calls this on start and again on every full reconcile (periodic, wake, explicit): a root that
/// appears gets a new source; one that disappears is handled as a missing root, and a stored
/// root no longer reported (for example a `$CODEX_HOME` of an earlier launch) is purged after the
/// grace period (`AgentHistoryIndexer+Roots.swift`).
enum AgentHistorySourceFactory {
    ///
    /// `snapshotCopyPolicy` is where the database adapters (Codex catalog, opencode) put private
    /// copies of a database whose `-shm` is missing. The indexer passes `.index(paths)`, so the
    /// copies sit inside the index directory; `.standard` (temp) is only for callers that never
    /// open a database, like the pre-consent probe.
    static func makeSources(
        locator: AgentHistoryRootLocator = .init(),
        snapshotCopyPolicy: ExternalSnapshotCopyPolicy = .standard
    ) -> [any AgentHistorySource] {
        makeSources(roots: locator.allRoots(), snapshotCopyPolicy: snapshotCopyPolicy)
    }

    /// One source per root, in the given order; each source is built for its root's agent.
    static func makeSources(
        roots: [AgentHistorySourceRoot],
        snapshotCopyPolicy: ExternalSnapshotCopyPolicy = .standard
    ) -> [any AgentHistorySource] {
        roots.map { makeSource(root: $0, snapshotCopyPolicy: snapshotCopyPolicy) }
    }

    static func makeSource(
        root: AgentHistorySourceRoot,
        snapshotCopyPolicy: ExternalSnapshotCopyPolicy = .standard
    ) -> any AgentHistorySource {
        switch root.agent {
        case .claude:
            return ClaudeHistorySource(root: root)
        case .codex:
            return CodexHistorySource(root: root, snapshotCopyPolicy: snapshotCopyPolicy)
        case .grok:
            return GrokHistorySource(root: root)
        case .opencode:
            return OpenCodeHistorySource(root: root, snapshotCopyPolicy: snapshotCopyPolicy)
        }
    }
}
