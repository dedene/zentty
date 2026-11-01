import Foundation

/// SQL for the content tier (spec §7.2), as plain statement text plus positional `?` bindings.
///
/// Every filter sits inside the ordered scan: `CROSS JOIN` pins the FTS table as the outer loop
/// (`ORDER BY f.rowid DESC` then walks newest first without a temp B-tree), and every candidate
/// row is checked against the session filters, the dates and the `instr` terms before it counts
/// towards the row limit. A quiet project is therefore never crowded out by a busy one.
///
/// How the session filters are checked is the `SessionGate`:
/// - `.perRow` joins each candidate's session and evaluates them per row. The engine uses it
///   when only visibility and the agent selection apply, which are cheap per row.
/// - With a project scope, `repo:` or `branch:` the engine first resolves the admitted sessions
///   once (`admittedSessions`, over the small sessions table) and gates the walk on their ids:
///   `.contentRowIDs` probes each FTS row id against the admitted sessions' content row ids
///   before the content row is read, `.sessions` checks the content row's `session_id`. Either
///   way the walk no longer runs the folding SQL functions per row, and `.contentRowIDs` skips
///   the content and session lookups of every other session's rows.
///
/// For a small admitted set under the trigram tokenizer, `substringScan` lists the admitted
/// sessions' matching message ids instead (the engine keeps the newest `limit` and reads them
/// with `messages(ids:)`): a trigram `MATCH` is a substring test, so the rows are the same, and
/// the cost follows the project's size rather than every term's doclists.
///
/// Row ids of `messages` and `artifacts` are chronological (`AgentHistoryStore.rowIDBase`), so
/// rowid order is time order, and a row's id is never below `rowIDBase(at)`. An `after:` date
/// therefore also bounds the FTS walk itself (`f.rowid >= rowIDBase(after)`), so it stops at the
/// date instead of reading every older posting.
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
        /// How the walk applies the session filters; the engine sets it after resolving them.
        var gate: SessionGate = .perRow

        /// Whether a project scope, `repo:` or `branch:` narrows the sessions. Then the engine
        /// resolves the admitted sessions once instead of filtering every candidate row.
        var restrictsSessions: Bool {
            if case .project = scope { return true }
            return !repoNames.isEmpty || !branches.isEmpty
        }

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

    /// How a content statement applies the session-level filters (visibility, enabled sources and
    /// agents, project scope, `repo:`, `branch:`).
    enum SessionGate: Equatable, Sendable {
        /// Joined per candidate row.
        case perRow
        /// Only these sessions (as resolved by `admittedSessions` in the same read transaction):
        /// the content row's `session_id` must be one of them.
        case sessions([Int64])
        /// Only these sessions: the FTS row id must be a content row id of one of them, checked
        /// before the content row is read. Costs a lookup list of every content row id of the
        /// sessions, so the engine picks it for small admitted sets only.
        case contentRowIDs([Int64])

        var gatesContentRowIDs: Bool {
            if case .contentRowIDs = self { return true }
            return false
        }
    }

    /// Rows each walk reads (newest first) before ranking. The spec's 2,000 / 500 graded four
    /// times as many rows for the same 30 results; on the 1M-message benchmark corpus 500 / 200
    /// keeps every top-1 result and 94.8 % of the top 10 (96.7 % of the top 3), and the misses
    /// are short prefix queries with thousands of near-equal hits, where the hits multiplier
    /// reorders ranks 2–10. It brings the content tier's p50 from 37 to 16 ms (optimized).
    static let messageLimit = 500
    static let artifactLimit = 200
    /// The scan fallback only looks at this many newest messages.
    static let scanWindow = 20_000
    /// Characters of `search_text` fetched for grading.
    static let gradedPrefixLength = 65_536
    /// Whether `search_text` is longer than the fetched prefix (characters, like `substr`).
    private static func prefixCutColumn(_ row: String) -> String {
        "length(\(row).search_text) > \(gradedPrefixLength)"
    }
    static let matchingTurnsScanLimit = 200
    /// The most turns (summed `sessions.turn_count`) the admitted sessions may hold for the
    /// engine to gate on content row ids (`.contentRowIDs`) rather than on session ids.
    static let rowIDGateTurnLimit = 20_000
    /// The most turns the admitted sessions may hold for the engine to find trigram message hits
    /// with `substringScan` instead of the FTS walk.
    static let substringScanTurnLimit = 12_000

    // MARK: - FTS

    /// Columns: `m.id, m.session_id, m.role, m.at, substr(m.search_text, …)`, whether that prefix
    /// was cut, then the ranking facts `s.updated_at, s.opens, s.last_opened_at, s.archived,
    /// s.main_repo_root, s.repo_root, s.cwd`.
    static func messages(match: String, filters: Filters, limit: Int = messageLimit) -> Statement {
        var bindings: [AgentHistoryValue] = [.text(match)]
        let conditions = ["messages_fts MATCH ?"]
            + ftsConditions(filters, row: "m", table: "messages", bindings: &bindings)
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
        let conditions = ["artifacts_fts MATCH ?"]
            + ftsConditions(filters, row: "a", table: "artifacts", bindings: &bindings)
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

    // MARK: - Substring scan of admitted sessions

    /// Ids of the admitted sessions' messages containing every term, read through the
    /// `(session_id, seq)` index: `m.id` only, unordered (the caller keeps the newest `limit`).
    ///
    /// Under the trigram tokenizer `MATCH "term"` is a substring test on the folded
    /// `search_text`, and `terms` are folded the same way, so `instr` finds the same messages.
    /// Its cost follows the size of the admitted sessions, not the length of every term's
    /// trigram doclists, which is what makes the FTS walk slow for a small project and long
    /// or several terms. `filters.gate` must list the admitted sessions.
    static func substringScan(terms: [String], filters: Filters) -> Statement {
        var bindings: [AgentHistoryValue] = []
        var conditions: [String] = []
        switch filters.gate {
        case .sessions(let ids), .contentRowIDs(let ids):
            conditions.append("m.session_id IN (SELECT value FROM json_each(?))")
            bindings.append(.text(jsonArray(ids)))
        case .perRow:
            let sessions = sessionConditions(filters, foldDistinctValues: false, bindings: &bindings)
            conditions.append("m.session_id IN (SELECT s.id FROM sessions s WHERE \(sessions.joined(separator: " AND ")))")
        }
        conditions += rowConditions(filters, row: "m", bindings: &bindings)
        for term in terms {
            conditions.append("instr(m.search_text, ?) > 0")
            bindings.append(.text(term))
        }
        let sql = """
            SELECT m.id FROM messages m
            WHERE \(conditions.joined(separator: "\n  AND "))
            """
        return Statement(sql: sql, bindings: bindings)
    }

    /// The `messages` columns (same order) of the given message ids, in no particular order.
    static func messages(ids: [Int64]) -> Statement {
        let sql = """
            SELECT m.id, m.session_id, m.role, m.at, substr(m.search_text, 1, \(gradedPrefixLength)),
                   \(prefixCutColumn("m")), \(sessionFactColumns)
            FROM messages m
            CROSS JOIN sessions s ON s.id = m.session_id
            WHERE m.id IN (SELECT value FROM json_each(?))
            """
        return Statement(sql: sql, bindings: [.text(jsonArray(ids))])
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

    // MARK: - Admitted sessions

    /// The sessions passing every session-level filter (visibility, enabled sources and agents,
    /// project scope, `repo:`, `branch:`); columns `s.id, s.turn_count`. Reads the sessions
    /// table only. `repo:` names and `branch:` values are folded over the distinct stored roots
    /// and branches (an uncorrelated list per value), so the folding SQL functions run once per
    /// distinct value rather than once per session; the sets match `filterConditions` exactly.
    static func admittedSessions(filters: Filters) -> Statement {
        var bindings: [AgentHistoryValue] = []
        let conditions = sessionConditions(filters, foldDistinctValues: true, bindings: &bindings)
        let sql = """
            SELECT s.id, s.turn_count FROM sessions s
            WHERE \(conditions.joined(separator: "\n  AND "))
            """
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: - Filters

    /// The ranking facts read with every hit row, after the row's own columns.
    static let sessionFactColumns =
        "s.updated_at, s.opens, s.last_opened_at, s.archived, s.main_repo_root, s.repo_root, s.cwd"

    /// `filterConditions` for an FTS statement over `table` (aliased `row`, FTS aliased `f`): the
    /// `after:` bound on the FTS row id first, then the session gate (`.contentRowIDs` on the FTS
    /// row id), then the rest.
    private static func ftsConditions(
        _ filters: Filters,
        row: String,
        table: String,
        bindings: inout [AgentHistoryValue]
    ) -> [String] {
        var conditions: [String] = []
        if let afterMs = filters.afterMs {
            // Necessary for `row.at >= afterMs` (ids never sit below `rowIDBase(at)`), and FTS5
            // takes it as a range on its own rowid walk.
            conditions.append("f.rowid >= ?")
            bindings.append(.integer(AgentHistoryStore.rowIDBase(at: afterMs)))
        }
        if case .contentRowIDs(let ids) = filters.gate {
            // Unary `+` keeps the list a filter: FTS5 must not turn it into rowid lookups, which
            // would lose the ordered walk.
            conditions.append(
                "+f.rowid IN (SELECT id FROM \(table) WHERE session_id IN (SELECT value FROM json_each(?)))")
            bindings.append(.text(jsonArray(ids)))
        }
        return conditions + filterConditions(
            filters, row: row, ftsGatedRowIDs: filters.gate.gatesContentRowIDs, bindings: &bindings)
    }

    /// The session-level conditions over `sessions s`: visibility, enabled sources and agents,
    /// project scope, `repo:` and `branch:`.
    ///
    /// `foldDistinctValues` decides how `repo:` names and `branch:` values are folded: per
    /// session (`zentty_folded_basename(s.main_repo_root) = ?`), or once per distinct stored
    /// value (`s.main_repo_root IN (SELECT r FROM (SELECT DISTINCT main_repo_root …) WHERE
    /// zentty_folded_basename(r) = ?)`). Both admit exactly the same sessions; the distinct form
    /// needs a temp B-tree for `DISTINCT`, so only `admittedSessions` (sessions table only) uses
    /// it, never a content walk.
    private static func sessionConditions(
        _ filters: Filters,
        foldDistinctValues: Bool,
        bindings: inout [AgentHistoryValue]
    ) -> [String] {
        var conditions = [AgentHistorySQL.visibleSessionPredicate]

        conditions.append(sourceCondition(agents: filters.agents, bindings: &bindings))

        if case .project(let project) = filters.scope {
            let predicate = project.sqlPredicate(sessionAlias: "s")
            conditions.append(predicate.sql)
            bindings.append(contentsOf: predicate.bindings)
        }

        if !filters.repoNames.isEmpty {
            let fold = AgentHistorySQLFunctions.foldedBasename
            var alternatives: [String] = []
            for name in filters.repoNames {
                if name.contains("/") {
                    alternatives.append("s.main_repo_root = ? OR s.repo_root = ?")
                    bindings.append(.text(name))
                    bindings.append(.text(name))
                    continue
                }
                if foldDistinctValues {
                    alternatives.append(
                        ["main_repo_root", "repo_root"].map { column in
                            "s.\(column) IN (SELECT r FROM (SELECT DISTINCT \(column) AS r FROM sessions) WHERE \(fold)(r) = ?)"
                        }.joined(separator: " OR "))
                } else {
                    alternatives.append("\(fold)(s.main_repo_root) = ? OR \(fold)(s.repo_root) = ?")
                }
                let folded = HistoryFilterFolding.fold(name)
                bindings.append(.text(folded))
                bindings.append(.text(folded))
            }
            conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
        }

        if !filters.branches.isEmpty {
            let fold = AgentHistorySQLFunctions.fold
            let alternatives = filters.branches.map { _ in
                foldDistinctValues
                    ? "s.branch IN (SELECT b FROM (SELECT DISTINCT branch AS b FROM sessions) WHERE instr(\(fold)(b), ?) > 0)"
                    : "instr(\(fold)(s.branch), ?) > 0"
            }
            bindings.append(contentsOf: filters.branches.map { .text(HistoryFilterFolding.fold($0)) })
            conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
        }
        return conditions
    }

    /// `ids` as a JSON array for `json_each(?)`: one binding, so the statement text (and its
    /// cached prepared statement) does not depend on how many sessions are admitted.
    static func jsonArray(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    /// AND-ed conditions over `sessions s` and the content row alias `row` (`m` or `a`), with
    /// their bindings appended in order. `ftsGatedRowIDs` says the caller already applied a
    /// `.contentRowIDs` gate to the FTS row id (`ftsConditions`); without it (the scan fallback)
    /// that gate falls back to the content row's `session_id`.
    static func filterConditions(
        _ filters: Filters,
        row: String,
        ftsGatedRowIDs: Bool = false,
        bindings: inout [AgentHistoryValue]
    ) -> [String] {
        var conditions: [String] = []
        switch filters.gate {
        case .perRow:
            conditions = sessionConditions(filters, foldDistinctValues: false, bindings: &bindings)
        case .contentRowIDs where ftsGatedRowIDs:
            break
        case .sessions(let ids), .contentRowIDs(let ids):
            // Unary `+`: a filter on the rowid walk, never a reason to read the rows through the
            // session index (which would need a sort).
            conditions = ["+\(row).session_id IN (SELECT value FROM json_each(?))"]
            bindings.append(.text(jsonArray(ids)))
        }

        return conditions + rowConditions(filters, row: row, bindings: &bindings)
    }

    /// The per-row conditions on the content row `row`: dates and `instr` terms.
    private static func rowConditions(
        _ filters: Filters,
        row: String,
        bindings: inout [AgentHistoryValue]
    ) -> [String] {
        var conditions: [String] = []
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
