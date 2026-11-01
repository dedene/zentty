import Foundation

/// Per-session reads: matching turns, the preview, the full transcript, the CLI's last turns,
/// lookups by native id and counts. Like the content tier they read on a pooled reader on the
/// calling thread, and never return a hidden (child, zero-turn), disabled-source, turned-off
/// agent or excluded session.
extension HistorySearchEngine {
    /// Sessions of enabled sources of agents the user has on (mirrors the content tier); nil
    /// when every agent is off.
    func enabledSourceCondition(_ bindings: inout [AgentHistoryValue]) -> String? {
        let agents = enabledAgents
        guard !agents.isEmpty else { return nil }
        return HistoryContentQuery.sourceCondition(agents: agents, bindings: &bindings)
    }

    /// The session's messages that contain every term and grade as a match, in `seq` order,
    /// at most `limit`, with highlight ranges on their display text. Throws `sessionNotFound`
    /// for a session search would not show (hidden, disabled source, agent off, excluded).
    func matchingTurns(
        sessionID: Int64,
        query: HistoryQuery,
        limit: Int = HistorySearchEngine.defaultMatchingTurnsLimit
    ) throws -> [HistoryTurnMatch] {
        try withReadTransaction { db in
            _ = try admittedSummary(sessionID: sessionID, db: db)
            return try matchingTurns(sessionID: sessionID, query: query, limit: limit, db: db)
        }
    }

    /// Matching turns when the query has content terms and some turn matches; otherwise the
    /// first user prompt and the latest agent reply (`turnsAreMatches == false`). With
    /// `expecting`, throws `sessionNotFound` once the row id belongs to another session.
    func preview(
        sessionID: Int64,
        query: HistoryQuery,
        expecting key: AgentHistorySessionKey? = nil
    ) throws -> HistoryPreview {
        try withReadTransaction { db in
            let summary = try admittedSummary(sessionID: sessionID, expecting: key, db: db)
            if query.hasContentTerms(tokenizer: tokenizer) {
                let matches = try matchingTurns(
                    sessionID: sessionID, query: query, limit: Self.defaultMatchingTurnsLimit, db: db)
                if !matches.isEmpty {
                    return HistoryPreview(session: summary, turns: matches, turnsAreMatches: true)
                }
            }

            let columns = "SELECT id, seq, role, at, text FROM messages WHERE session_id = ? AND role = ?"
            let firstPrompt = try db.queryOne(
                columns + " ORDER BY seq LIMIT 1",
                [.integer(sessionID), .text(AgentHistoryRole.user.rawValue)],
                map: TurnRow.init(row:))
            let latestReply = try db.queryOne(
                columns + " ORDER BY seq DESC LIMIT 1",
                [.integer(sessionID), .text(AgentHistoryRole.agent.rawValue)],
                map: TurnRow.init(row:))
            let turns = [firstPrompt, latestReply].compactMap { $0 }.sorted { $0.seq < $1.seq }.map {
                $0.turn(highlights: HistoryMatcher.highlightRanges(in: $0.text, query: query))
            }
            return HistoryPreview(session: summary, turns: turns, turnsAreMatches: false)
        }
    }

    /// The whole conversation, oldest first; the latest `transcriptLimit` turns when longer.
    /// Every term occurrence is highlighted; `firstMatchMessageID` is the first turn that grades
    /// as a match. `expecting` as for `preview`.
    func transcript(
        sessionID: Int64,
        query: HistoryQuery,
        expecting key: AgentHistorySessionKey? = nil
    ) throws -> HistoryTranscript {
        try withReadTransaction { db in
            _ = try admittedSummary(sessionID: sessionID, expecting: key, db: db)
            let (rows, total) = try latestTurnRows(sessionID: sessionID, limit: Self.transcriptLimit, db: db)
            var firstMatch: Int64?
            var turns: [HistoryTurnMatch] = []
            turns.reserveCapacity(rows.count)
            for row in rows {
                guard !query.terms.isEmpty else {
                    turns.append(row.turn(highlights: []))
                    continue
                }
                let folded = AgentHistorySearchText.normalizeWithMap(row.text)
                let (occurrences, matched) = folded.utf8.withUnsafeBufferPointer { buffer in
                    (
                        HistoryMatcher.creditedOccurrences(normalizedUTF8: buffer, terms: query.terms),
                        firstMatch == nil && HistoryMatcher.grade(normalizedUTF8: buffer, query: query) != nil
                    )
                }
                if matched {
                    firstMatch = row.id
                }
                turns.append(row.turn(highlights: HistoryMatcher.highlightRanges(for: occurrences, in: folded)))
            }
            return HistoryTranscript(turns: turns, firstMatchMessageID: firstMatch, isTruncated: total > rows.count)
        }
    }

    /// The last `limit` turns (newest last) and the session's total message count (CLI `show`).
    func lastTurns(sessionID: Int64, limit: Int) throws -> (turns: [HistoryTurnMatch], total: Int) {
        try withReadTransaction { db in
            _ = try admittedSummary(sessionID: sessionID, db: db)
            let (rows, total) = try latestTurnRows(sessionID: sessionID, limit: max(0, limit), db: db)
            return (rows.map { $0.turn(highlights: []) }, total)
        }
    }

    /// CLI `show`: among the visible sessions with this native id in `scope` (newest first),
    /// the one `choose` picks, with its last `limit` turns. One read transaction, so the turns
    /// are always the picked session's: the indexer can delete that session and give its row
    /// id to another project's session between two separate reads. nil when `choose` picks
    /// none. `choose` runs inside the transaction; keep it cheap.
    func lastTurns(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        limit: Int,
        choose: ([AgentHistorySessionSummary]) throws -> AgentHistorySessionSummary?
    ) throws -> HistorySessionTail? {
        try withReadTransaction { db in
            let candidates = try sessions(nativeID: nativeID, agent: agent, scope: scope, db: db)
            guard let session = try choose(candidates) else { return nil }
            guard candidates.contains(where: { $0.id == session.id }) else {
                throw HistorySearchError.sessionNotFound
            }
            let (rows, total) = try latestTurnRows(sessionID: session.id, limit: max(0, limit), db: db)
            return HistorySessionTail(session: session, turns: rows.map { $0.turn(highlights: []) }, total: total)
        }
    }

    /// Visible sessions with this native id (any agent, or one), newest first, in `scope`.
    func sessions(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope
    ) throws -> [AgentHistorySessionSummary] {
        try withReadTransaction { db in
            try sessions(nativeID: nativeID, agent: agent, scope: scope, db: db)
        }
    }

    private func sessions(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        db: AgentHistoryDatabase
    ) throws -> [AgentHistorySessionSummary] {
        var bindings: [AgentHistoryValue] = [.text(nativeID)]
        guard let sourceCondition = enabledSourceCondition(&bindings) else { return [] }
        var conditions = ["s.native_id = ?", AgentHistorySQL.visibleSessionPredicate, sourceCondition]
        if let agent {
            conditions.append("src.agent = ?")
            bindings.append(.text(agent.rawValue))
        }
        if case .project(let project) = scope {
            let predicate = project.sqlPredicate(sessionAlias: "s")
            conditions.append(predicate.sql)
            bindings.append(contentsOf: predicate.bindings)
        }
        let sql = AgentHistorySessionSummary.selectSQL
            + " WHERE " + conditions.joined(separator: " AND ")
            + " ORDER BY s.updated_at DESC, s.id DESC"
        let exclusions = self.exclusions
        return try db.query(sql, bindings, map: AgentHistorySessionSummary.init(row:))
            .filter { !exclusions.excludesCanonical($0.cwd) }
    }

    /// Visible, non-excluded sessions of enabled sources in `scope`.
    func visibleSessionCount(scope: AgentHistoryScope) throws -> Int {
        var bindings: [AgentHistoryValue] = []
        guard let sourceCondition = enabledSourceCondition(&bindings) else { return 0 }
        var conditions = [AgentHistorySQL.visibleSessionPredicate, sourceCondition]
        if case .project(let project) = scope {
            let predicate = project.sqlPredicate(sessionAlias: "s")
            conditions.append(predicate.sql)
            bindings.append(contentsOf: predicate.bindings)
        }
        let whereClause = " FROM sessions s WHERE " + conditions.joined(separator: " AND ")
        let exclusions = self.exclusions
        return try withReadTransaction { db in
            if exclusions.isEmpty {
                return Int(try db.scalarInt64("SELECT count(*)" + whereClause, bindings) ?? 0)
            }
            return try db.query("SELECT s.cwd" + whereClause, bindings) { $0.optionalString(0) }
                .reduce(0) { exclusions.excludesCanonical($1) ? $0 : $0 + 1 }
        }
    }

    // MARK: - Shared reads

    /// Visible, non-excluded summaries of enabled sources and agents by id: the metadata
    /// snapshot first, then SQL for ids it does not hold (newer than the snapshot, or not in it
    /// yet). Both paths drop agents the user turned off.
    func summaries(forSessionIDs ids: [Int64], db: AgentHistoryDatabase) throws -> [Int64: AgentHistorySessionSummary] {
        let agents = enabledAgents
        var result: [Int64: AgentHistorySessionSummary] = [:]
        var missing: [Int64] = []
        var seen: Set<Int64> = []
        for id in ids where seen.insert(id).inserted {
            if let summary = metadataIndex.summary(forSessionID: id) {
                if agents.contains(summary.agent) {
                    result[id] = summary
                }
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty, !agents.isEmpty else { return result }

        let exclusions = self.exclusions
        let placeholders = Array(repeating: "?", count: missing.count).joined(separator: ", ")
        let sql = AgentHistorySessionSummary.selectSQL
            + " WHERE s.id IN (\(placeholders)) AND \(AgentHistorySQL.visibleSessionPredicate)"
            + " AND src.enabled = 1"
        for summary in try db.query(sql, missing.map { .integer($0) }, map: AgentHistorySessionSummary.init(row:))
        where agents.contains(summary.agent) && !exclusions.excludesCanonical(summary.cwd) {
            result[summary.id] = summary
        }
        return result
    }

    /// The single admission point for per-session reads: the session's summary when search
    /// could show it (see `summaries(forSessionIDs:db:)`), otherwise `sessionNotFound`. Call it
    /// inside the read transaction before touching the session's messages.
    ///
    /// Row ids are reused: a deleted session's id goes to the next insert. So the row must
    /// still be the summary's session (the metadata snapshot can predate the delete), and the
    /// one the caller expects when it says.
    private func admittedSummary(
        sessionID: Int64,
        expecting key: AgentHistorySessionKey? = nil,
        db: AgentHistoryDatabase
    ) throws -> AgentHistorySessionSummary {
        guard let summary = try summaries(forSessionIDs: [sessionID], db: db)[sessionID],
              key == nil || summary.key == key
        else {
            throw HistorySearchError.sessionNotFound
        }
        let row = try db.queryOne(
            "SELECT source_id, native_id FROM sessions WHERE id = ?", [.integer(sessionID)]
        ) { (sourceID: $0.int64(0), nativeID: $0.string(1)) }
        guard let row, row.sourceID == summary.sourceID, row.nativeID == summary.nativeID else {
            throw HistorySearchError.sessionNotFound
        }
        return summary
    }

    /// Callers admit the session first (`admittedSummary`).
    private func matchingTurns(
        sessionID: Int64,
        query: HistoryQuery,
        limit: Int,
        db: AgentHistoryDatabase
    ) throws -> [HistoryTurnMatch] {
        guard !query.terms.isEmpty, limit > 0 else { return [] }
        let statement = HistoryContentQuery.matchingTurns(sessionID: sessionID, terms: query.terms.map(\.text))
        var matches: [HistoryTurnMatch] = []
        for row in try db.query(statement.sql, statement.bindings, map: TurnRow.init(row:)) {
            let folded = AgentHistorySearchText.normalizeWithMap(row.text)
            let grade = folded.utf8.withUnsafeBufferPointer {
                HistoryMatcher.grade(normalizedUTF8: $0, query: query, collectOccurrences: true)
            }
            guard let grade else { continue }
            matches.append(row.turn(highlights: HistoryMatcher.highlightRanges(for: grade.occurrences, in: folded)))
            if matches.count == limit { break }
        }
        return matches
    }

    /// The latest `limit` messages in `seq` order, and the session's message count.
    private func latestTurnRows(sessionID: Int64, limit: Int, db: AgentHistoryDatabase) throws -> ([TurnRow], Int) {
        let total = Int(try db.scalarInt64(
            "SELECT count(*) FROM messages WHERE session_id = ?", [.integer(sessionID)]) ?? 0)
        guard limit > 0 else { return ([], total) }
        let rows = try db.query(
            "SELECT id, seq, role, at, text FROM messages WHERE session_id = ? ORDER BY seq DESC LIMIT ?",
            [.integer(sessionID), .integer(Int64(limit))],
            map: TurnRow.init(row:))
        return (rows.reversed(), total)
    }
}

/// One `messages` row as `SELECT id, seq, role, at, text`.
private struct TurnRow {
    let id: Int64
    let seq: Int
    let role: AgentHistoryRole
    let atMs: Int64
    let text: String

    init(row: AgentHistoryRow) {
        id = row.int64(0)
        seq = Int(row.int64(1))
        role = AgentHistoryRole(rawValue: row.string(2)) ?? .agent
        atMs = row.int64(3)
        text = row.string(4)
    }

    func turn(highlights: [NSRange]) -> HistoryTurnMatch {
        HistoryTurnMatch(
            messageID: id,
            seq: seq,
            role: role,
            at: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000),
            text: text,
            highlights: highlights
        )
    }
}
