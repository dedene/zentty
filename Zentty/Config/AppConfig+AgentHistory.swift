import Foundation

extension AppConfig {
    /// `[agent_history]` in config.toml: preferences that are fine to sync between Macs.
    /// Consent and per-source choices live in the index's `state.json` instead.
    struct AgentHistory: Equatable, Sendable {
        /// Absolute, lexically standardized folders (symlinks NOT resolved), deduplicated in
        /// order. Sessions whose working directory lies inside one are never indexed.
        var excludedFolders: [String]
        /// Lets `zentty history search` look outside the calling pane's project.
        var allowAgentsAllProjects: Bool

        static let `default` = AgentHistory(excludedFolders: [], allowAgentsAllProjects: false)

        /// Trims, expands `~`, drops empty and relative entries, standardizes `.`/`..`, strips
        /// the trailing `/` (except for `/` itself) and deduplicates keeping the first spelling.
        func normalized() -> AgentHistory {
            var seen = Set<String>()
            var folders: [String] = []
            for raw in excludedFolders {
                guard let folder = Self.normalizedFolder(raw), seen.insert(folder).inserted else {
                    continue
                }
                folders.append(folder)
            }
            return AgentHistory(excludedFolders: folders, allowAgentsAllProjects: allowAgentsAllProjects)
        }

        /// Canonicalizes the folders once for ingest, query-time filtering and the SQL purge.
        var exclusionMatcher: AgentHistoryExclusionMatcher {
            AgentHistoryExclusionMatcher(folders: excludedFolders)
        }

        static func normalizedFolder(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                return nil
            }
            var path = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path.isEmpty ? nil : path
        }
    }
}
