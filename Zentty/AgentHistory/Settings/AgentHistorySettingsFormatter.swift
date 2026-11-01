import Foundation

/// One line under the Status card's summary. `isWarning` lines render amber.
struct AgentHistorySettingsActivity: Equatable, Sendable {
    let text: String
    let isWarning: Bool
}

/// What the Sources card shows for one agent; roots of the same agent are grouped.
struct AgentHistorySettingsSourceRow: Equatable, Sendable {
    let agent: AgentHistoryAgent
    let title: String
    /// A root was found on disk (indexer health or the pre-consent probe). Undetected rows are
    /// shown with a disabled switch.
    let isDetected: Bool
    /// The agent is switched on in Agent History.
    let isEnabled: Bool
    /// Root paths with `~` for the home folder, one per line. nil when undetected.
    let rootsText: String?
    /// "1,879 found · 1,850 indexed · 29 skipped" while indexing ran, "1,284 found" or "Found"
    /// from the probe, "Not found" when the probe found nothing, nil when nothing is known yet.
    let summaryText: String?
    /// The most recently scanned root's problem: "~/.claude: Permission denied".
    let errorText: String?
    /// For undetected agents: the paths that were checked, one per line.
    let checkedPathsText: String?
}

/// Turns `AgentHistoryStatus` (and the stat-only probe) into the Settings section's copy.
/// Pure: locale, home folder and clock are injected so tests pin `en_US` and a fixed time.
struct AgentHistorySettingsFormatter {
    private let locale: Locale
    private let homeDirectory: String
    private let now: () -> Date

    init(
        locale: Locale = .current,
        homeDirectory: String = NSHomeDirectory(),
        now: @escaping () -> Date = Date.init
    ) {
        self.locale = locale
        self.homeDirectory = homeDirectory
        self.now = now
    }

    // MARK: - Summary

    /// Until Agent History's saved state has been read: on or off isn't known yet.
    static let loadingSummary = "Checking Agent History…"

    /// "1,284 sessions · 412 MB on disk · updated 3 minutes ago", or the off / not-yet copy.
    func summary(for status: AgentHistoryStatus) -> String {
        guard status.isStateLoaded else {
            return Self.loadingSummary
        }
        guard status.isEnabled else {
            return status.hasConsented
                ? "Off. The index is kept until you delete it."
                : "Off. Nothing has been read."
        }
        guard let lastUpdatedAt = status.lastUpdatedAt else {
            return "Not indexed yet"
        }
        let sessions = status.indexedSessions == 1 ? "1 session" : "\(number(status.indexedSessions)) sessions"
        return "\(sessions) · \(byteCount(status.indexSizeBytes)) on disk · updated \(relativeTime(lastUpdatedAt))"
    }

    // MARK: - Activity

    /// What the indexer is doing when that needs saying; nil while idle or quietly watching.
    func activity(for status: AgentHistoryStatus) -> AgentHistorySettingsActivity? {
        switch status.state {
        case .off, .starting:
            return nil
        case .backfilling(let progress):
            let text = progress.totalSessions > 0
                ? "Indexing \(number(progress.indexedSessions)) of \(number(progress.totalSessions)) sessions"
                : "Looking for sessions"
            return AgentHistorySettingsActivity(text: text, isWarning: false)
        case .paused(let reason, _):
            return pausedActivity(reason)
        case .failed(let reason):
            return AgentHistorySettingsActivity(text: failureText(reason), isWarning: true)
        case .watching:
            guard status.tokenizer == AgentHistoryTokenizer.none else {
                return nil
            }
            return AgentHistorySettingsActivity(text: "Limited search", isWarning: true)
        }
    }

    private func pausedActivity(_ reason: AgentHistoryPauseReason) -> AgentHistorySettingsActivity {
        switch reason {
        case .lowPower:
            return AgentHistorySettingsActivity(text: "Paused while Low Power Mode is on", isWarning: true)
        case .thermal:
            return AgentHistorySettingsActivity(text: "Paused while the Mac is hot", isWarning: true)
        case .diskFull:
            return AgentHistorySettingsActivity(text: "Paused: the disk is full", isWarning: true)
        case .anotherInstance:
            return AgentHistorySettingsActivity(
                text: "Another running copy of Zentty keeps the index up to date.",
                isWarning: false
            )
        case .configUnreadable:
            return AgentHistorySettingsActivity(
                text: "Paused: config.toml can't be read, so the excluded folders aren't known. "
                    + "Fix the file to resume.",
                isWarning: true
            )
        }
    }

    private func failureText(_ reason: AgentHistoryFailureReason) -> String {
        switch reason {
        case .openFailed(let code):
            return "Indexing failed: the index couldn't be opened (SQLite error \(code))."
        case .corrupt:
            return "Indexing failed: the index is damaged. Rebuild it to start over."
        case .newerSchema:
            return "Index was created by a newer Zentty. Rebuild it to keep searching."
        case .removalsUnreadable:
            return "Indexing stopped: the list of removed sessions can't be read. Delete the index to start over."
        }
    }

    // MARK: - Progress

    /// Backfill progress in 0...1, or nil when there is no backfill or nothing to count.
    func progressFraction(for status: AgentHistoryStatus) -> Double? {
        let progress: AgentHistoryBackfillProgress?
        switch status.state {
        case .backfilling(let value):
            progress = value
        case .paused(_, let value):
            progress = value
        case .off, .starting, .watching, .failed:
            progress = nil
        }
        guard let progress, progress.totalSessions > 0 else {
            return nil
        }
        let fraction = Double(progress.indexedSessions) / Double(progress.totalSessions)
        return min(1, max(0, fraction))
    }

    // MARK: - Sources

    /// One row per `AgentHistoryAgent.allCases`. Indexer health (per root) wins over the probe;
    /// the probe covers agents the indexer isn't watching (off, or the agent switched off).
    func sourceRows(
        for status: AgentHistoryStatus,
        detected: [AgentHistoryDetectedSource]
    ) -> [AgentHistorySettingsSourceRow] {
        AgentHistoryAgent.allCases.map { agent in
            let health = status.sources.filter { $0.agent == agent }
            let probed = detected.filter { $0.agent == agent }
            let isEnabled = status.enabledAgents.contains(agent)
            if !health.isEmpty {
                return healthRow(agent: agent, health: health, isEnabled: isEnabled)
            }
            let found = probed.filter(\.isFound)
            if !found.isEmpty {
                return probedRow(agent: agent, found: found, isEnabled: isEnabled)
            }
            let checked = uniquePaths(probed.flatMap(\.checkedPaths))
            return AgentHistorySettingsSourceRow(
                agent: agent,
                title: agent.displayName,
                isDetected: false,
                isEnabled: isEnabled,
                rootsText: nil,
                summaryText: probed.isEmpty ? nil : "Not found",
                errorText: nil,
                checkedPathsText: checked.isEmpty ? nil : checked.map(tildePath).joined(separator: "\n")
            )
        }
    }

    private func healthRow(
        agent: AgentHistoryAgent,
        health: [AgentHistorySourceHealth],
        isEnabled: Bool
    ) -> AgentHistorySettingsSourceRow {
        let discovered = health.reduce(0) { $0 + $1.discovered }
        let indexed = health.reduce(0) { $0 + $1.indexed }
        let skipped = health.reduce(0) { $0 + $1.skipped }
        let failing = health.compactMap { root -> (root: AgentHistorySourceHealth, reason: String)? in
            guard let reason = root.problem.map(AgentHistoryIndexer.describe) ?? root.lastError else {
                return nil
            }
            return (root, reason)
        }
        // Latest scan wins; on equal (or missing) scan times the later root in order wins.
        let latest = failing.enumerated().max { lhs, rhs in
            let lhsTime = lhs.element.root.lastScanAt ?? .distantPast
            let rhsTime = rhs.element.root.lastScanAt ?? .distantPast
            return lhsTime == rhsTime ? lhs.offset < rhs.offset : lhsTime < rhsTime
        }?.element
        return AgentHistorySettingsSourceRow(
            agent: agent,
            title: agent.displayName,
            isDetected: true,
            isEnabled: isEnabled,
            rootsText: uniquePaths(health.map(\.root)).map(tildePath).joined(separator: "\n"),
            summaryText: "\(number(discovered)) found · \(number(indexed)) indexed · \(number(skipped)) skipped",
            errorText: latest.map { "\(tildePath($0.root.root)): \($0.reason)" },
            checkedPathsText: nil
        )
    }

    private func probedRow(
        agent: AgentHistoryAgent,
        found: [AgentHistoryDetectedSource],
        isEnabled: Bool
    ) -> AgentHistorySettingsSourceRow {
        let counts = found.map(\.sessionCount)
        let summary: String
        if counts.allSatisfy({ $0 != nil }) {
            summary = "\(number(counts.reduce(0) { $0 + ($1 ?? 0) })) found"
        } else {
            summary = "Found"
        }
        let problem = found.last { $0.problem != nil }
        return AgentHistorySettingsSourceRow(
            agent: agent,
            title: agent.displayName,
            isDetected: true,
            isEnabled: isEnabled,
            rootsText: uniquePaths(found.compactMap(\.rootPath)).map(tildePath).joined(separator: "\n"),
            summaryText: summary,
            errorText: problem.flatMap { source in
                source.problem.map { "\(tildePath(source.rootPath ?? "")): \(AgentHistoryIndexer.describe($0))" }
            },
            checkedPathsText: nil
        )
    }

    // MARK: - Helpers

    private func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func byteCount(_ bytes: Int64) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        )
        return style.format(max(0, bytes))
    }

    /// "just now" under a minute (and for times in the future), else "3 minutes ago".
    private func relativeTime(_ date: Date) -> String {
        let reference = now()
        guard reference.timeIntervalSince(date) >= 60 else {
            return "just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    private func tildePath(_ path: String) -> String {
        let home = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory
        guard !home.isEmpty, home != "/" else {
            return path
        }
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
