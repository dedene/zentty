import Darwin
import Foundation

/// The pre-consent look at which agents have history on this Mac (D11).
///
/// Stat-only. For each source it checks that the root is a readable directory and asks the
/// adapter's `estimatedSessionCount()`, which counts transcript files and returns nil whenever a
/// number would mean opening a database (opencode, the Codex catalog). It never calls
/// `discoverUnits()` (Codex consults its thread catalog there), `ingest` or `existingNativeIDs()`.
/// Agents without a root on disk get one "not found" entry listing the paths that were checked.
///
/// Runs off-main: counting walks transcript directories.
enum AgentHistoryDiscoveryProbe {
    static func detect(locator: AgentHistoryRootLocator = .init()) -> [AgentHistoryDetectedSource] {
        detect(
            sources: AgentHistorySourceFactory.makeSources(locator: locator),
            candidatePaths: locator.candidatePaths(for:)
        )
    }

    /// One entry per source, grouped by agent in `AgentHistoryAgent.allCases` order (sources keep
    /// their given order within an agent), plus one not-found entry per agent without a source.
    static func detect(
        sources: [any AgentHistorySource],
        candidatePaths: (AgentHistoryAgent) -> [String]
    ) -> [AgentHistoryDetectedSource] {
        var results: [AgentHistoryDetectedSource] = []
        for agent in AgentHistoryAgent.allCases {
            let checkedPaths = candidatePaths(agent)
            let agentSources = sources.filter { $0.agent == agent }
            guard !agentSources.isEmpty else {
                results.append(AgentHistoryDetectedSource(
                    agent: agent, rootPath: nil, isFound: false, sessionCount: nil,
                    checkedPaths: checkedPaths, problem: nil
                ))
                continue
            }
            for source in agentSources {
                results.append(probe(source, checkedPaths: checkedPaths))
            }
        }
        return results
    }

    private static func probe(_ source: any AgentHistorySource, checkedPaths: [String]) -> AgentHistoryDetectedSource {
        let rootPath = source.root.path
        let found: Bool
        let problem: AgentHistorySourceProblem?
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            found = false
            problem = .rootMissing
        } else if access(rootPath, R_OK | X_OK) != 0 {
            found = true
            problem = .permissionDenied
        } else {
            found = true
            problem = nil
        }
        let count = found && problem == nil ? source.estimatedSessionCount() : nil
        return AgentHistoryDetectedSource(
            agent: source.agent, rootPath: rootPath, isFound: found, sessionCount: count,
            checkedPaths: checkedPaths, problem: problem
        )
    }
}
