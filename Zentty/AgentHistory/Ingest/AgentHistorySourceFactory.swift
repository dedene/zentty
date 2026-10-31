import Foundation

/// Builds one history source per discovered root.
///
/// Stat-only: discovery goes through `AgentHistoryRootLocator`, and the adapters' initializers
/// only compute paths, so building sources never opens a transcript or database. The indexer
/// calls this on start and again on every reconcile, so a root that appears, disappears or moves
/// (for example a new `$CODEX_HOME`) yields a fresh set of source instances.
enum AgentHistorySourceFactory {
    static func makeSources(locator: AgentHistoryRootLocator = .init()) -> [any AgentHistorySource] {
        makeSources(roots: locator.allRoots())
    }

    /// One source per root, in the given order; each source is built for its root's agent.
    static func makeSources(roots: [AgentHistorySourceRoot]) -> [any AgentHistorySource] {
        roots.map(makeSource(root:))
    }

    static func makeSource(root: AgentHistorySourceRoot) -> any AgentHistorySource {
        switch root.agent {
        case .claude:
            return ClaudeHistorySource(root: root)
        case .codex:
            return CodexHistorySource(root: root)
        case .grok:
            return GrokHistorySource(root: root)
        case .opencode:
            return OpenCodeHistorySource(root: root)
        }
    }
}
