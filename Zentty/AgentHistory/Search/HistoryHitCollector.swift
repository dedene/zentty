import Foundation

/// Grades content rows into hits and keeps each session's ranking facts. One per search, used
/// on the searching thread only (`HistorySearchEngine`).
final class HistoryHitCollector {
    let query: HistoryQuery
    /// Folded terms every candidate row contains somewhere (FTS terms and `instr` filters).
    let sqlRequiredTerms: Set<String>
    let exclusions: AgentHistoryExclusionMatcher
    let cancellation: HistorySearchCancellation
    let tuning: HistorySearchEngine.Tuning

    private(set) var hits: [HistoryContentHit] = []
    private(set) var facts: [Int64: HistoryRankFacts] = [:]
    /// Sessions seen with an excluded `cwd`.
    private var excluded: Set<Int64> = []
    private(set) var rows = 0

    init(
        query: HistoryQuery,
        sqlRequiredTerms: Set<String>,
        exclusions: AgentHistoryExclusionMatcher,
        cancellation: HistorySearchCancellation,
        tuning: HistorySearchEngine.Tuning
    ) {
        self.query = query
        self.sqlRequiredTerms = sqlRequiredTerms
        self.exclusions = exclusions
        self.cancellation = cancellation
        self.tuning = tuning
    }

    func checkCancelled() throws {
        if cancellation.isCancelled {
            throw HistorySearchError.cancelled
        }
    }

    /// Columns per `HistoryContentQuery.messages` / `.scan`. Returns the number of rows read.
    func collectMessages(_ db: AgentHistoryDatabase, _ statement: HistoryContentQuery.Statement) throws -> Int {
        var count = 0
        try db.query(statement.sql, statement.bindings) { row in
            count += 1
            try beginRow()
            let sessionID = row.int64(1)
            guard admitSession(sessionID, row: row, factsAt: 6) else { return }
            guard let graded = grade(row, column: 4, isCut: row.bool(5), mode: .text) else { return }
            let role = AgentHistoryRole(rawValue: row.string(2)) ?? .agent
            hits.append(HistoryContentHit(
                sessionID: sessionID, rowID: row.int64(0), role: HistoryHitRole(role), atMs: row.int64(3),
                gradedQuality: graded.quality, isWordLevel: graded.isWordLevel))
        }
        return count
    }

    /// Columns per `HistoryContentQuery.artifacts`. Returns the number of rows read.
    func collectArtifacts(_ db: AgentHistoryDatabase, _ statement: HistoryContentQuery.Statement) throws -> Int {
        var count = 0
        try db.query(statement.sql, statement.bindings) { row in
            count += 1
            try beginRow()
            let sessionID = row.int64(1)
            guard let kind = AgentHistoryArtifactKind(rawValue: row.string(2)),
                  admitSession(sessionID, row: row, factsAt: 7),
                  let graded = grade(row, column: 4, isCut: row.bool(6), mode: kind == .path ? .path : .text)
            else { return }
            hits.append(HistoryContentHit(
                sessionID: sessionID, rowID: row.int64(0), role: .artifact(kind), atMs: row.int64(3),
                gradedQuality: graded.quality, isWordLevel: graded.isWordLevel, artifactValue: row.string(5)))
        }
        return count
    }

    private func beginRow() throws {
        rows += 1
        tuning.willGradeRow?()
        if rows % max(1, tuning.cancellationCheckRows) == 0 {
            try checkCancelled()
        }
    }

    /// Reads the session's ranking facts once (columns from `column`, per
    /// `HistoryContentQuery.sessionFactColumns`); false when its `cwd` is excluded.
    private func admitSession(_ sessionID: Int64, row: AgentHistoryRow, factsAt column: Int32) -> Bool {
        if facts[sessionID] != nil { return true }
        if excluded.contains(sessionID) { return false }
        if !exclusions.isEmpty, exclusions.excludesCanonical(row.optionalString(column + 6)) {
            excluded.insert(sessionID)
            return false
        }
        facts[sessionID] = HistoryRankFacts(
            updatedAtMs: row.int64(column),
            opens: Int(row.int64(column + 1)),
            lastOpenedAtMs: row.optionalInt64(column + 2),
            isArchived: row.bool(column + 3),
            mainRepoRoot: row.optionalString(column + 4),
            repoRoot: row.optionalString(column + 5)
        )
        return true
    }

    /// Grades the fetched `search_text` prefix. A row whose text was cut (`isCut`, counted in
    /// characters like `substr`) and does not grade counts as a mid-word hit only when the cut
    /// explains the miss (`cutHidesMatch`).
    private func grade(
        _ row: AgentHistoryRow,
        column: Int32,
        isCut: Bool,
        mode: HistoryMatcher.BoundaryMode
    ) -> (quality: Double, isWordLevel: Bool)? {
        let graded: (quality: Double, isWordLevel: Bool)?? = row.withUTF8Bytes(column) { bytes in
            if let grade = HistoryMatcher.grade(normalizedUTF8: bytes, query: query, mode: mode) {
                return (grade.quality, grade.isWordLevel)
            }
            if isCut, cutHidesMatch(bytes, mode: mode) {
                return (HistoryMatchClass.midWord.credit, false)
            }
            return nil
        }
        return graded ?? nil
    }

    /// True when every term either has a credited occurrence in the prefix, or is absent from
    /// it and SQL guarantees it lies beyond the cut. A term present in the prefix without credit
    /// (a short mid-word hit, a hash or UUID) fails, as does a missing term SQL never checked.
    private func cutHidesMatch(_ prefix: UnsafeBufferPointer<UInt8>, mode: HistoryMatcher.BoundaryMode) -> Bool {
        var someTermBeyondCut = false
        for term in query.terms {
            if HistoryMatcher.contains(normalizedUTF8: prefix, term: term) {
                guard HistoryMatcher.grade(normalizedUTF8: prefix, terms: [term], phraseText: nil, mode: mode) != nil
                else { return false }
            } else {
                guard sqlRequiredTerms.contains(term.text) else { return false }
                someTermBeyondCut = true
            }
        }
        return someTermBeyondCut
    }
}
