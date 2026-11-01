import Foundation

/// SQL for the content tier (spec §7.2), as plain statement text plus positional `?` bindings.
///
/// Every filter sits inside the ordered scan: `CROSS JOIN` pins the FTS table as the outer loop
/// (`ORDER BY f.rowid DESC` then walks newest first without a temp B-tree), and scope, agent,
/// repo, branch, date and `instr` filters are evaluated per candidate row. A quiet project is
/// therefore never crowded out of the row limit by a busy one.
///
/// Row ids of `messages` and `artifacts` are chronological (`AgentHistoryStore.rowIDBase`), so
/// rowid order is time order.
enum HistoryContentQuery {
    struct Statement: Equatable, Sendable {
        let sql: String
        let bindings: [AgentHistoryValue]
    }

    /// The candidate filters shared by every content statement.
    struct Filters: Equatable, Sendable {
        /// Empty means every agent.
        var agents: Set<AgentHistoryAgent> = []
        /// `repo:` values; one containing `/` is an exact root, otherwise a basename folded by
        /// `HistoryFilterFolding` on both sides.
        var repoNames: [String] = []
        /// `branch:` values, matched as `HistoryFilterFolding`-folded substrings.
        var branches: [String] = []
        var beforeMs: Int64?
        var afterMs: Int64?
        /// Folded terms that must occur in `search_text` (`instr`).
        var instrTerms: [String] = []
        var scope: AgentHistoryScope = .all

        init(
            agents: Set<AgentHistoryAgent> = [],
            repoNames: [String] = [],
            branches: [String] = [],
            beforeMs: Int64? = nil,
            afterMs: Int64? = nil,
            instrTerms: [String] = [],
            scope: AgentHistoryScope = .all
        ) {
            self.agents = agents
            self.repoNames = repoNames
            self.branches = branches
            self.beforeMs = beforeMs
            self.afterMs = afterMs
            self.instrTerms = instrTerms
            self.scope = scope
        }

        /// `agents` is the query's `agent:` set narrowed to `enabledAgents` (all of them without
        /// an `agent:` filter); empty when no enabled agent is left, which the caller must check.
        init(query: HistoryQuery, plan: HistoryMatchPlan, scope: AgentHistoryScope, enabledAgents: Set<AgentHistoryAgent>) {
            self.init(
                agents: query.filters.agents.isEmpty ? enabledAgents : query.filters.agents.intersection(enabledAgents),
                repoNames: query.filters.repoNames,
                branches: query.filters.branches,
                beforeMs: query.filters.before.map(HistoryContentQuery.milliseconds),
                afterMs: query.filters.after.map(HistoryContentQuery.milliseconds),
                instrTerms: plan.instrFilters,
                scope: scope
            )
        }
    }

    static let messageLimit = 2_000
    static let artifactLimit = 500
    /// The scan fallback only looks at this many newest messages.
    static let scanWindow = 20_000
    /// Characters of `search_text` fetched for grading.
    static let gradedPrefixLength = 65_536
    /// Whether `search_text` is longer than the fetched prefix (characters, like `substr`).
    private static func prefixCutColumn(_ row: String) -> String {
        "length(\(row).search_text) > \(gradedPrefixLength)"
    }
    static let matchingTurnsScanLimit = 200

    // MARK: - FTS

    /// Columns: `m.id, m.session_id, m.role, m.at, substr(m.search_text, …)`, whether that prefix
    /// was cut, then the ranking facts `s.updated_at, s.opens, s.last_opened_at, s.archived,
    /// s.main_repo_root, s.repo_root, s.cwd`.
    static func messages(match: String, filters: Filters, limit: Int = messageLimit) -> Statement {
        var bindings: [AgentHistoryValue] = [.text(match)]
        let conditions = ["messages_fts MATCH ?"] + filterConditions(filters, row: "m", bindings: &bindings)
        bindings.append(.integer(Int64(limit)))
        let sql = """
            SELECT m.id, m.session_id, m.role, m.at, substr(m.search_text, 1, \(gradedPrefixLength)),
                   \(prefixCutColumn("m")), \(sessionFactColumns)
            FROM messages_fts f
            CROSS JOIN messages m ON m.id = f.rowid
            CROSS JOIN sessions s ON s.id = m.session_id
            WHERE \(conditions.joined(separator: "\n  AND "))
            ORDER BY f.rowid DESC
            LIMIT ?
            """
        return Statement(sql: sql, bindings: bindings)
    }

    /// Columns: `a.id, a.session_id, a.kind, a.at, substr(a.search_text, …), a.value`, whether
    /// the prefix was cut, then the ranking facts as in `messages`.
    static func artifacts(match: String, filters: Filters, limit: Int = artifactLimit) -> Statement {
        var bindings: [AgentHistoryValue] = [.text(match)]
        let conditions = ["artifacts_fts MATCH ?"] + filterConditions(filters, row: "a", bindings: &bindings)
        bindings.append(.integer(Int64(limit)))
        let sql = """
            SELECT a.id, a.session_id, a.kind, a.at, substr(a.search_text, 1, \(gradedPrefixLength)), a.value,
                   \(prefixCutColumn("a")), \(sessionFactColumns)
            FROM artifacts_fts f
            CROSS JOIN artifacts a ON a.id = f.rowid
            CROSS JOIN sessions s ON s.id = a.session_id
            WHERE \(conditions.joined(separator: "\n  AND "))
            ORDER BY f.rowid DESC
            LIMIT ?
            """
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: - Scan fallback

    /// The id of the `window`-th newest message; nil when there are fewer messages.
    static func scanCutoff(window: Int = scanWindow) -> Statement {
        Statement(
            sql: "SELECT id FROM messages ORDER BY id DESC LIMIT 1 OFFSET ?",
            bindings: [.integer(Int64(max(window, 1) - 1))]
        )
    }

    /// The newest messages at or above `cutoff`, filtered like `messages` (same columns) but
    /// with `instr` only. A nil cutoff scans every message.
    static func scan(cutoff: Int64?, filters: Filters, limit: Int = messageLimit) -> Statement {
        var bindings: [AgentHistoryValue] = [.integer(cutoff ?? Int64.min)]
        let conditions = ["m.id >= ?"] + filterConditions(filters, row: "m", bindings: &bindings)
        bindings.append(.integer(Int64(limit)))
        let sql = """
            SELECT m.id, m.session_id, m.role, m.at, substr(m.search_text, 1, \(gradedPrefixLength)),
                   \(prefixCutColumn("m")), \(sessionFactColumns)
            FROM messages m
            CROSS JOIN sessions s ON s.id = m.session_id
            WHERE \(conditions.joined(separator: "\n  AND "))
            ORDER BY m.id DESC
            LIMIT ?
            """
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: - Sessions

    /// Messages of one session containing every term (`instr` on `search_text`), in `seq`
    /// order. Columns: `id, seq, role, at, text`. The caller grades them.
    static func matchingTurns(sessionID: Int64, terms: [String], limit: Int = matchingTurnsScanLimit) -> Statement {
        var bindings: [AgentHistoryValue] = [.integer(sessionID)]
        var conditions = ["session_id = ?"]
        for term in terms {
            conditions.append("instr(search_text, ?) > 0")
            bindings.append(.text(term))
        }
        bindings.append(.integer(Int64(limit)))
        let sql = """
            SELECT id, seq, role, at, text FROM messages
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY seq
            LIMIT ?
            """
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: - Filters

    /// The ranking facts read with every hit row, after the row's own columns.
    static let sessionFactColumns =
        "s.updated_at, s.opens, s.last_opened_at, s.archived, s.main_repo_root, s.repo_root, s.cwd"

    /// AND-ed conditions over `sessions s` and the content row alias `row` (`m` or `a`), with
    /// their bindings appended in order.
    static func filterConditions(_ filters: Filters, row: String, bindings: inout [AgentHistoryValue]) -> [String] {
        var conditions = [AgentHistorySQL.visibleSessionPredicate]

        conditions.append(sourceCondition(agents: filters.agents, bindings: &bindings))

        if case .project(let project) = filters.scope {
            let predicate = project.sqlPredicate(sessionAlias: "s")
            conditions.append(predicate.sql)
            bindings.append(contentsOf: predicate.bindings)
        }

        if !filters.repoNames.isEmpty {
            var alternatives: [String] = []
            for name in filters.repoNames {
                if name.contains("/") {
                    alternatives.append("s.main_repo_root = ? OR s.repo_root = ?")
                    bindings.append(.text(name))
                    bindings.append(.text(name))
                } else {
                    let fold = AgentHistorySQLFunctions.foldedBasename
                    alternatives.append("\(fold)(s.main_repo_root) = ? OR \(fold)(s.repo_root) = ?")
                    let folded = HistoryFilterFolding.fold(name)
                    bindings.append(.text(folded))
                    bindings.append(.text(folded))
                }
            }
            conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
        }

        if !filters.branches.isEmpty {
            let alternatives = filters.branches.map { _ in "instr(\(AgentHistorySQLFunctions.fold)(s.branch), ?) > 0" }
            bindings.append(contentsOf: filters.branches.map { .text(HistoryFilterFolding.fold($0)) })
            conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
        }

        if let beforeMs = filters.beforeMs {
            conditions.append("\(row).at < ?")
            bindings.append(.integer(beforeMs))
        }
        if let afterMs = filters.afterMs {
            conditions.append("\(row).at >= ?")
            bindings.append(.integer(afterMs))
        }

        for term in filters.instrTerms {
            conditions.append("instr(\(row).search_text, ?) > 0")
            bindings.append(.text(term))
        }
        return conditions
    }

    /// Sessions `s` of enabled `sources` rows, of `agents` only unless it is empty. The agent list
    /// carries the user's opt-out, which applies before a purge turns `sources.enabled` off.
    static func sourceCondition(agents: Set<AgentHistoryAgent>, bindings: inout [AgentHistoryValue]) -> String {
        var condition = "s.source_id IN (SELECT id FROM sources WHERE enabled = 1"
        if !agents.isEmpty {
            let names = agents.map(\.rawValue).sorted()
            condition += " AND agent IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))"
            bindings.append(contentsOf: names.map { .text($0) })
        }
        return condition + ")"
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
