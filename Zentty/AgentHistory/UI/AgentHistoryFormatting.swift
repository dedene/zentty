import Foundation

/// The footer's index health line. `isWarning` lines render amber.
struct AgentHistoryFooterHealth: Equatable {
    let text: String
    let isWarning: Bool
}

/// The palette's copy: row times, counts, footer health, notes and row labels. Pure: locale,
/// calendar and the clock are injected so tests pin `en_US`, UTC and a fixed time.
struct AgentHistoryFormatting {
    private let locale: Locale
    private let calendar: Calendar

    init(locale: Locale = .current, calendar: Calendar = .current) {
        self.locale = locale
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
    }

    // MARK: - Times and counts

    /// "just now", "5m ago", "3h ago", "Yesterday", "4 days ago", then the date ("Oct 12", with
    /// the year when it isn't this year). Future times read "just now".
    func relativeTime(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return "just now"
        }
        if elapsed < 3600 {
            return "\(Int(elapsed / 60))m ago"
        }
        if elapsed < 86_400 {
            return "\(Int(elapsed / 3600))h ago"
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? Int(elapsed / 86_400)
        if days <= 1 {
            return "Yesterday"
        }
        if days < 7 {
            return "\(days) days ago"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    /// "1 session", "1,284 sessions".
    func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(number(count)) sessions"
    }

    /// "3 matches"; nil for one match or none.
    func matches(_ count: Int) -> String? {
        count > 1 ? "\(number(count)) matches" : nil
    }

    /// "1 turn", "2,000 turns".
    func turnCount(_ count: Int) -> String {
        count == 1 ? "1 turn" : "\(number(count)) turns"
    }

    /// Above a capped transcript: "Showing the latest 2,000 turns. Earlier turns aren't shown."
    func transcriptTruncationNote(shownTurns: Int) -> String {
        "Showing the latest \(turnCount(shownTurns)). Earlier turns aren't shown."
    }

    // MARK: - Footer

    func footerHealth(status: AgentHistoryStatus, now: Date) -> AgentHistoryFooterHealth {
        switch status.state {
        case .off:
            return AgentHistoryFooterHealth(text: "Agent History is off", isWarning: false)
        case .starting:
            return AgentHistoryFooterHealth(text: "Starting…", isWarning: false)
        case .backfilling(let progress):
            let text = progress.totalSessions > 0
                ? "Indexing \(number(progress.indexedSessions)) of \(number(progress.totalSessions)) sessions"
                : "Looking for sessions"
            return AgentHistoryFooterHealth(text: text, isWarning: false)
        case .paused(.lowPower, _):
            return AgentHistoryFooterHealth(text: "Indexing paused while Low Power Mode is on", isWarning: true)
        case .paused(.thermal, _):
            return AgentHistoryFooterHealth(text: "Indexing paused while the Mac is hot", isWarning: true)
        case .paused(.diskFull, _):
            return AgentHistoryFooterHealth(text: "Indexing paused: the disk is full", isWarning: true)
        case .paused(.anotherInstance, _):
            return AgentHistoryFooterHealth(text: indexedLine(status, now: now), isWarning: false)
        case .paused(.configUnreadable, _):
            return AgentHistoryFooterHealth(text: "Paused: config.toml can't be read", isWarning: true)
        case .failed:
            return AgentHistoryFooterHealth(text: "Index unavailable", isWarning: true)
        case .watching:
            if status.tokenizer == AgentHistoryTokenizer.none {
                return AgentHistoryFooterHealth(
                    text: "\(sessionCount(status.indexedSessions)) · Limited search",
                    isWarning: true
                )
            }
            return AgentHistoryFooterHealth(text: indexedLine(status, now: now), isWarning: false)
        }
    }

    /// The amber footer link to Settings when an enabled source has problems: "opencode: 2
    /// skipped", "Codex: Permission denied", or "2 sources have problems".
    func problemLink(status: AgentHistoryStatus) -> String? {
        let problems = AgentHistoryAgent.allCases.compactMap { agent -> String? in
            let roots = status.sources.filter { $0.agent == agent && $0.isEnabled }
            if let problem = roots.compactMap(\.problem).last {
                return "\(agent.displayName): \(AgentHistoryIndexer.describe(problem))"
            }
            let skipped = roots.reduce(0) { $0 + $1.skipped }
            if skipped > 0 {
                return "\(agent.displayName): \(number(skipped)) skipped"
            }
            if roots.contains(where: { $0.lastError != nil }) {
                return "\(agent.displayName): needs attention"
            }
            return nil
        }
        guard let first = problems.first else {
            return nil
        }
        return problems.count == 1 ? first : "\(problems.count) sources have problems"
    }

    private func indexedLine(_ status: AgentHistoryStatus, now: Date) -> String {
        let count = sessionCount(status.indexedSessions)
        guard let updated = status.lastUpdatedAt else {
            return count
        }
        let when = relativeTime(updated, now: now)
        return "\(count) · updated \(when == "Yesterday" ? "yesterday" : when)"
    }

    // MARK: - Rows

    /// "Branch: main", "Repo: zentty", "Changed: Sources/App.swift", "Ran: swift test".
    func noteText(_ note: HistoryMatchNote) -> String {
        switch note {
        case .field(let field, let value):
            switch field {
            case .title: return value
            case .branch: return "Branch: \(value)"
            case .repo: return "Repo: \(value)"
            case .folder: return "Folder: \(value)"
            }
        case .artifact(let kind, let value):
            switch kind {
            case .path: return "Changed: \(value)"
            case .command: return "Ran: \(value)"
            case .commit: return "Commit: \(value)"
            case .pr: return "PR: \(value)"
            }
        }
    }

    /// "You", "Agent", or the artifact label, for the snippet line's lead-in.
    func snippetRoleLabel(_ role: HistoryHitRole) -> String {
        switch role {
        case .user: "You"
        case .agent: "Agent"
        case .artifact: "Matched"
        }
    }

    /// One VoiceOver label for a whole row, e.g. "Claude Code, Fix the sidebar, zentty, main,
    /// Branch: main, running now, 3 matches, 2h ago, You said fix the sidebar".
    func rowAccessibilityLabel(_ row: AgentHistoryResultRow, isFolderGone: Bool, now: Date) -> String {
        var parts = [row.agent.displayName, row.title.text]
        if let repo = row.summary?.repoName {
            parts.append(repo)
        }
        if let branch = row.summary?.branch {
            parts.append(branch)
        }
        if let note = row.note {
            parts.append(noteText(note))
        }
        if row.live != nil {
            parts.append("running now")
        }
        if row.summary?.isArchived == true {
            parts.append("archived")
        }
        if isFolderGone {
            parts.append("folder gone")
        }
        if let count = matches(row.hitCount) {
            parts.append(count)
        }
        if let date = row.displayDate {
            parts.append(relativeTime(date, now: now))
        }
        if let snippet = row.snippet {
            let lead: String
            switch snippet.role {
            case .user: lead = "You said"
            case .agent: lead = "Agent said"
            case .artifact: lead = "Matched"
            }
            parts.append("\(lead) \(snippet.text.text)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
