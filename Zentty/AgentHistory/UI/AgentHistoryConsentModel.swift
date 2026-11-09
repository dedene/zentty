import Foundation

/// Indexed sessions out of a total, for one source row or the whole card (A-15).
struct AgentHistoryConsentProgress: Equatable {
    var indexed: Int
    var total: Int

    /// 0…1; nil while the total isn't known yet.
    var fraction: Double? {
        total > 0 ? min(1, Double(max(indexed, 0)) / Double(total)) : nil
    }
}

/// The first-run consent card (spec §4.5, D15): which agents to index, excluded folders, the
/// Claude retention nudge and, after "Index ‹N› Sessions", the indexing progress. Pure state;
/// `AgentHistoryViewModel+Consent` drives it and talks to the services.
struct AgentHistoryConsentModel: Equatable {
    struct SourceRow: Equatable, Identifiable {
        let agent: AgentHistoryAgent
        let rootPath: String?
        /// nil for database sources (opencode, the Codex catalog): counting would mean opening
        /// them before consent, so they read "Found" (D11).
        let sessionCount: Int?
        let isFound: Bool
        var isEnabled: Bool
        var progress: AgentHistoryConsentProgress?

        var id: String { "\(agent.rawValue):\(rootPath ?? "")" }
    }

    /// The card switches to results once this many sessions are searchable (spec §4.5).
    static let resultsThreshold = 50

    var rows: [SourceRow]
    /// Normalized absolute folders (same rules as config.toml), deduplicated in order.
    private(set) var excludedFolders: [String]
    /// Claude Code's retention for each config folder holding conversations, in root order;
    /// empty when Claude Code wasn't found.
    var retentions: [ClaudeRetentionStatus]
    /// Why "Keep 1 Year" failed; nothing was changed.
    var retentionError: String?
    /// Why "Index ‹N› Sessions" didn't start: the excluded folders couldn't be saved.
    var saveError: String?
    /// The folder "Keep 1 Year" last raised in this card.
    var raisedRetentionDirectory: String?
    /// "Keep 1 Year" is writing Claude Code's file; another click waits for it.
    var isRaisingRetention = false
    /// Set by "Index ‹N› Sessions": checkboxes lock and the card shows progress.
    var isIndexing = false
    var overallProgress: AgentHistoryConsentProgress?
    /// What the indexer is doing right now, above the note: counts and time left, or why it paused.
    var indexingStatus: AgentHistoryFooterHealth?

    /// Sessions counted across every found source (database sources add nothing, D11).
    var totalFound: Int {
        rows.reduce(0) { $0 + ($1.isFound ? $1.sessionCount ?? 0 : 0) }
    }

    /// Sessions counted across the checked sources: the confirm button's number.
    var selectedSessionCount: Int {
        rows.reduce(0) { $0 + ($1.isFound && $1.isEnabled ? $1.sessionCount ?? 0 : 0) }
    }

    /// Found sources that can't be counted before consent.
    var uncountedAgents: [AgentHistoryAgent] {
        var agents: [AgentHistoryAgent] = []
        for row in rows where row.isFound && row.sessionCount == nil && !agents.contains(row.agent) {
            agents.append(row.agent)
        }
        return agents
    }

    var enabledAgents: Set<AgentHistoryAgent> {
        Set(rows.filter { $0.isFound && $0.isEnabled }.map(\.agent))
    }

    /// The folder "Keep 1 Year" changes: the first one with a retention Zentty may raise.
    var retentionTarget: ClaudeRetentionStatus? { retentions.first(where: \.isNudgeEligible) }

    var showsRetentionNudge: Bool { retentionTarget != nil }

    /// "Keep 1 Year" succeeded in this card.
    var didRaiseRetention: Bool { raisedRetentionDirectory != nil }

    var canConfirm: Bool { !isIndexing && !enabledAgents.isEmpty }

    /// One row per found root; an agent with none gets a single muted "Not found" row. Rows
    /// follow `AgentHistoryAgent.allCases`; found sources start checked.
    static func make(
        detected: [AgentHistoryDetectedSource],
        excluded: [String],
        retentions: [ClaudeRetentionStatus]
    ) -> AgentHistoryConsentModel {
        var rows: [SourceRow] = []
        for agent in AgentHistoryAgent.allCases {
            let sources = detected.filter { $0.agent == agent }
            let found = sources.filter(\.isFound)
            if found.isEmpty {
                rows.append(SourceRow(
                    agent: agent, rootPath: sources.first?.rootPath, sessionCount: nil,
                    isFound: false, isEnabled: false, progress: nil
                ))
                continue
            }
            var seenRoots = Set<String>()
            for source in found where seenRoots.insert(source.rootPath ?? "").inserted {
                rows.append(SourceRow(
                    agent: agent, rootPath: source.rootPath, sessionCount: source.sessionCount,
                    isFound: true, isEnabled: true, progress: nil
                ))
            }
        }
        return AgentHistoryConsentModel(
            rows: rows,
            excludedFolders: normalizedFolders(excluded),
            retentions: retentions
        )
    }

    /// The Claude Code config folders whose retention matters: every found root except those
    /// known to hold no conversations, deduplicated in probe order.
    static func claudeRetentionRoots(in detected: [AgentHistoryDetectedSource]) -> [String] {
        var seen = Set<String>()
        return detected
            .filter { $0.agent == .claude && $0.isFound && $0.sessionCount != 0 }
            .compactMap(\.rootPath)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Editing (before indexing starts)

    /// Checks or unchecks every root of `agent`. Ignored while indexing and for missing agents.
    mutating func setEnabled(_ agent: AgentHistoryAgent, _ enabled: Bool) {
        guard !isIndexing else { return }
        for index in rows.indices where rows[index].agent == agent && rows[index].isFound {
            rows[index].isEnabled = enabled
        }
    }

    mutating func addExcludedFolders(_ folders: [String]) {
        excludedFolders = Self.normalizedFolders(excludedFolders + folders)
    }

    mutating func removeExcludedFolder(_ folder: String) {
        let normalized = AppConfig.AgentHistory.normalizedFolder(folder) ?? folder
        excludedFolders.removeAll { $0 == normalized }
    }

    /// Trims, expands `~`, drops relative entries, standardizes and deduplicates, keeping order.
    static func normalizedFolders(_ folders: [String]) -> [String] {
        AppConfig.AgentHistory(excludedFolders: folders, allowAgentsAllProjects: false)
            .normalized()
            .excludedFolders
    }

    // MARK: - Progress

    /// Per-row counters from the matching roots (by root, else by agent) and the overall bar
    /// from the indexer's backfill progress.
    mutating func applyProgress(_ status: AgentHistoryStatus) {
        for index in rows.indices {
            let row = rows[index]
            guard row.isFound, row.isEnabled else {
                rows[index].progress = nil
                continue
            }
            var health = status.sources.filter { $0.agent == row.agent && $0.root == row.rootPath }
            if health.isEmpty {
                health = status.sources.filter { $0.agent == row.agent }
            }
            guard !health.isEmpty else {
                rows[index].progress = nil
                continue
            }
            rows[index].progress = AgentHistoryConsentProgress(
                indexed: health.reduce(0) { $0 + $1.indexed },
                total: health.reduce(0) { $0 + $1.discovered }
            )
        }
        overallProgress = Self.overallProgress(status)
    }

    static func overallProgress(_ status: AgentHistoryStatus) -> AgentHistoryConsentProgress? {
        switch status.state {
        case .backfilling(let progress), .paused(_, let progress?):
            return AgentHistoryConsentProgress(indexed: progress.indexedSessions, total: progress.totalSessions)
        case .watching:
            return AgentHistoryConsentProgress(indexed: status.indexedSessions, total: status.indexedSessions)
        default:
            return nil
        }
    }

    /// The first 50 sessions are searchable, or the backfill is already done.
    static func isReadyForResults(_ status: AgentHistoryStatus) -> Bool {
        status.state == .watching || status.indexedSessions >= resultsThreshold
    }
}

// MARK: - Copy

extension AgentHistoryConsentModel {
    static let title = "Search your past agent sessions"
    static let footnote = "Conversations can contain secrets you pasted. You can exclude folders, remove single sessions, and delete the index any time in Settings."
    static let indexingNote = "Indexing in the background, newest first. You can search while this runs."
    static let declineTitle = "Not Now"
    static let keepOneYearTitle = "Keep 1 Year"
    static let addFolderTitle = "Add Folder…"
    static let raisedRetentionText = "Claude Code keeps conversations for 365 days."
    static let excludedFoldersSaveError = "Couldn't save the excluded folders; nothing was indexed."
    static let stateNotSavedError = "Zentty couldn't save Agent History's settings, so nothing was indexed. Check that your disk has free space, then try again."
    /// Also the Settings alert's message when turning on is refused for the same reason.
    static let configUnreadableError = "Zentty can't read config.toml, so it doesn't know which folders you excluded. Fix the file, then try again."

    func bodyText(formatting: AgentHistoryFormatting) -> String {
        let total = totalFound
        let uncounted = uncountedAgents.map(\.displayName)
        let found: String
        if total > 0 {
            let conversations = total == 1 ? "1 conversation" : "\(formatting.number(total)) conversations"
            found = uncounted.isEmpty
                ? "Zentty found \(conversations) on this Mac."
                : "Zentty found \(conversations) on this Mac, plus the ones in \(Self.list(uncounted))."
        } else {
            found = "Zentty found agent conversations on this Mac."
        }
        return found + " It builds a search index of your prompts and the agents' replies, plus the files and commands they touched. Tool output is skipped. The index stays on this Mac."
    }

    func confirmTitle(formatting: AgentHistoryFormatting) -> String {
        let count = selectedSessionCount
        switch count {
        case 0: return "Index Sessions"
        case 1: return "Index 1 Session"
        default: return "Index \(formatting.number(count)) Sessions"
        }
    }

    /// "1,284 sessions", "Found" (database sources), "Not found", or "312 / 1,284" while indexing.
    func countText(for row: SourceRow, formatting: AgentHistoryFormatting) -> String {
        guard row.isFound else { return "Not found" }
        if isIndexing, row.isEnabled, let progress = row.progress, progress.total > 0 {
            return "\(formatting.number(progress.indexed)) / \(formatting.number(progress.total))"
        }
        guard let count = row.sessionCount else { return "Found" }
        return formatting.sessionCount(count)
    }

    /// Names the folder when there is more than one, or when it isn't a `.claude` folder.
    var retentionNudgeText: String? {
        guard let target = retentionTarget else { return nil }
        let days = target.effectiveDays
        let period = days == 1 ? "1 day" : "\(days) days"
        let folder = displayedFolder(target.configDirectory).map { " in \($0)" } ?? ""
        return "Claude Code deletes conversations\(folder) after \(period), so they'll drop out of Agent History too."
    }

    /// Shown once the folder "Keep 1 Year" raised keeps a year.
    var raisedRetentionText: String? {
        guard let raised = raisedRetentionDirectory,
              let status = retentions.first(where: { $0.configDirectory.path == raised }),
              status.effectiveDays >= ClaudeRetentionSettings.recommendedDays
        else { return nil }
        guard let folder = displayedFolder(status.configDirectory) else { return Self.raisedRetentionText }
        return "Claude Code keeps conversations in \(folder) for 365 days."
    }

    private func displayedFolder(_ directory: URL) -> String? {
        guard retentions.count > 1 || directory.lastPathComponent != ".claude" else { return nil }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
