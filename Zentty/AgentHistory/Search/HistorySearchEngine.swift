import Foundation
import os

/// The content tier (spec §7.2) and the session queries behind the preview, the transcript and
/// the CLI. Every SQLite call runs on a reader connection from the pool (never the writer) on
/// the calling thread, so callers stay off the main thread; `searchContentAsync` does that hop.
///
/// A content search:
/// 1. plans the terms (`HistoryMatchPlan`); `.metadataOnly` returns an empty response;
/// 2. walks the FTS tables newest first with every filter inside the ordered scan
///    (`HistoryContentQuery`), or, without a usable tokenizer, the newest `scanWindow` messages;
/// 3. grades the first 65,536 characters of each candidate's `search_text`, artifacts with path
///    boundaries and a 0.9 discount. A longer candidate that does not grade counts as a mid-word
///    hit only when the cut can be blamed: every term missing from the prefix is one SQL
///    required (FTS or `instr`), and every term in the prefix has a credited occurrence;
/// 4. ranks sessions (`HistoryRanker`), then attaches summaries, snippets, notes and title
///    highlights to the at most 30 winners and the enrichments.
///
/// Sessions whose `cwd` is excluded are dropped at query time (A-10), child and zero-turn
/// sessions never match (`AgentHistorySQL.visibleSessionPredicate`), sessions of disabled
/// sources or of agents the user turned off (`enabledAgents`, even before their purge ran) are
/// skipped, and tombstoned sessions have no rows left to match.
///
/// Cancellation: SQLite's progress handler aborts the running statement once the query's
/// `HistorySearchCancellation` is cancelled, and the row loop checks it every 256 rows. Both
/// surface as `HistorySearchError.cancelled`. The handler is removed when the search ends (and
/// again by the pool on check-in).
///
/// Thread-safe: all state is immutable after init; the providers are `@Sendable`.
final class HistorySearchEngine: @unchecked Sendable {
    struct Tuning: Sendable {
        var messageLimit = HistoryContentQuery.messageLimit
        var artifactLimit = HistoryContentQuery.artifactLimit
        var scanWindow = HistoryContentQuery.scanWindow
        var progressHandlerInstructions: Int32 = 1_000
        var cancellationCheckRows = 256
        /// Test seam: runs on the searching thread before each content row is graded.
        var willGradeRow: (@Sendable () -> Void)?

        init() {}
    }

    static let transcriptLimit = 2_000
    static let defaultMatchingTurnsLimit = 50
    static let queue = DispatchQueue(label: "be.zenjoy.zentty.agent-history.search", qos: .userInitiated)

    let readers: AgentHistoryReaderPool
    let metadataIndex: HistoryMetadataIndex
    let tuning: Tuning
    private let tokenizerProvider: @Sendable () -> AgentHistoryTokenizer
    private let exclusionsProvider: @Sendable () -> AgentHistoryExclusionMatcher
    private let enabledAgentsProvider: @Sendable () -> Set<AgentHistoryAgent>

    /// `enabledAgents` is the user's persisted agent selection; it gates every query at once,
    /// while the index's `sources.enabled` only follows once the agent's purge has run.
    init(
        readers: AgentHistoryReaderPool,
        metadataIndex: HistoryMetadataIndex,
        tokenizer: @escaping @Sendable () -> AgentHistoryTokenizer,
        exclusions: @escaping @Sendable () -> AgentHistoryExclusionMatcher,
        enabledAgents: @escaping @Sendable () -> Set<AgentHistoryAgent>,
        tuning: Tuning = Tuning()
    ) {
        self.readers = readers
        self.metadataIndex = metadataIndex
        self.tokenizerProvider = tokenizer
        self.exclusionsProvider = exclusions
        self.enabledAgentsProvider = enabledAgents
        self.tuning = tuning
    }

    var tokenizer: AgentHistoryTokenizer { tokenizerProvider() }
    var exclusions: AgentHistoryExclusionMatcher { exclusionsProvider() }
    var enabledAgents: Set<AgentHistoryAgent> { enabledAgentsProvider() }

    // MARK: - Content tier

    func searchContent(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excludingSessionIDs: Set<Int64>,
        cancellation: HistorySearchCancellation
    ) throws -> HistoryContentResponse {
        let start = DispatchTime.now().uptimeNanoseconds
        let plan = HistoryMatchPlan.make(query: query, tokenizer: tokenizer)
        let mode: HistoryContentResponse.Mode = switch plan.mode {
        case .fts: .fts
        case .scan: .scanFallback
        case .metadataOnly: .metadataOnly
        }
        func emptyResponse() -> HistoryContentResponse {
            HistoryContentResponse(
                query: query, generation: cancellation.generation, results: [], enrichments: [:],
                mode: mode, truncated: false, elapsed: Self.seconds(since: start))
        }
        guard !query.terms.isEmpty, plan.mode != .metadataOnly, !query.filters.excludesAllAgents else {
            return emptyResponse()
        }
        if cancellation.isCancelled {
            throw HistorySearchError.cancelled
        }

        let filters = HistoryContentQuery.Filters(
            query: query, plan: plan, scope: context.scope, enabledAgents: enabledAgents)
        guard !filters.agents.isEmpty else {
            return emptyResponse()
        }
        let collector = HitCollector(
            query: query, sqlRequiredTerms: Set(plan.ftsTerms + plan.instrFilters), exclusions: exclusions,
            cancellation: cancellation, tuning: tuning)
        let tuning = self.tuning

        let response: HistoryContentResponse = try withSearchReader(cancellation: cancellation) { db in
            var truncated = false
            switch plan.mode {
            case .fts:
                guard let match = plan.matchExpression else { return emptyResponse() }
                let messageRows = try collector.collectMessages(
                    db, HistoryContentQuery.messages(match: match, filters: filters, limit: tuning.messageLimit))
                let artifactRows = try collector.collectArtifacts(
                    db, HistoryContentQuery.artifacts(match: match, filters: filters, limit: tuning.artifactLimit))
                truncated = messageRows >= tuning.messageLimit || artifactRows >= tuning.artifactLimit
            case .scan:
                let cutoffStatement = HistoryContentQuery.scanCutoff(window: tuning.scanWindow)
                let cutoff = try db.scalarInt64(cutoffStatement.sql, cutoffStatement.bindings)
                let rows = try collector.collectMessages(
                    db, HistoryContentQuery.scan(cutoff: cutoff, filters: filters, limit: tuning.messageLimit))
                truncated = cutoff != nil || rows >= tuning.messageLimit
            case .metadataOnly:
                return emptyResponse()
            }
            try collector.checkCancelled()

            let ranked = HistoryRanker.rankContent(
                hits: collector.hits,
                facts: collector.facts,
                context: context,
                excludingSessionIDs: excludingSessionIDs
            )
            let materialized = try materialize(ranked, query: query, db: db, cancellation: cancellation)
            return HistoryContentResponse(
                query: query,
                generation: cancellation.generation,
                results: materialized.results,
                enrichments: materialized.enrichments,
                mode: mode,
                truncated: truncated,
                elapsed: Self.seconds(since: start)
            )
        }

        AgentHistoryLog.search.debug(
            """
            Content search: \(collector.rows, privacy: .public) rows, \(collector.hits.count, privacy: .public) hits, \
            \(response.results.count, privacy: .public) results, \(response.enrichments.count, privacy: .public) \
            enrichments, truncated \(response.truncated, privacy: .public), \
            \(Int(response.elapsed * 1000), privacy: .public) ms
            """
        )
        return response
    }

    /// Runs `searchContent` on the search queue and calls `completion` on the main thread.
    func searchContentAsync(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excludingSessionIDs: Set<Int64>,
        cancellation: HistorySearchCancellation,
        completion: @escaping @MainActor @Sendable (Result<HistoryContentResponse, Error>) -> Void
    ) {
        Self.queue.async { [self] in
            let result: Result<HistoryContentResponse, Error>
            if cancellation.isCancelled {
                result = .failure(HistorySearchError.cancelled)
            } else {
                result = Result {
                    try searchContent(
                        query, context: context, excludingSessionIDs: excludingSessionIDs,
                        cancellation: cancellation)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// The CLI's single list: both tiers, one row per session (`HistoryRanker.merge`). Off-main.
    func searchMerged(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        limit: Int,
        cancellation: HistorySearchCancellation
    ) throws -> [HistoryMergedResult] {
        let metadata = metadataIndex.search(query, context: context, limit: limit)
        if cancellation.isCancelled {
            throw HistorySearchError.cancelled
        }
        let content = try searchContent(query, context: context, excludingSessionIDs: [], cancellation: cancellation)
        return HistoryRanker.merge(metadata: metadata.results, content: content.results, limit: limit)
    }

    // MARK: - Winners

    private struct Materialized {
        var results: [HistoryContentResult] = []
        var enrichments: [Int64: HistoryContentResult] = [:]
    }

    /// Summaries (snapshot first, then SQL), display texts, snippets, notes and title
    /// highlights for the ranked sessions and the enrichments. Sessions without a visible,
    /// non-excluded summary are dropped.
    private func materialize(
        _ ranked: HistoryRankedContent,
        query: HistoryQuery,
        db: AgentHistoryDatabase,
        cancellation: HistorySearchCancellation
    ) throws -> Materialized {
        let sessions = ranked.results + ranked.enrichments.values.sorted { $0.sessionID < $1.sessionID }
        guard !sessions.isEmpty else { return Materialized() }

        let summaries = try summaries(forSessionIDs: sessions.map(\.sessionID), db: db)
        let messageIDs = sessions.compactMap { $0.best.role.isArtifact ? nil : $0.best.rowID }
        let texts = try displayTexts(messageIDs: messageIDs, db: db)
        try checkCancelled(cancellation)

        func result(_ ranked: HistoryRankedSession) -> HistoryContentResult? {
            guard let summary = summaries[ranked.sessionID] else { return nil }
            var snippet: HistorySnippet?
            var note: HistoryMatchNote?
            if case .artifact(let kind) = ranked.best.role {
                note = ranked.best.artifactValue.map { .artifact(kind, value: $0) }
            } else if let text = texts[ranked.best.rowID] {
                snippet = HistorySnippetBuilder.snippet(for: text, query: query)
            }
            return HistoryContentResult(
                session: summary,
                best: ranked.best,
                bestQualityHits: ranked.bestQualityHits,
                totalHits: ranked.totalHits,
                score: ranked.score,
                isWordLevel: ranked.isWordLevel,
                snippet: snippet,
                note: note,
                titleHighlights: HistoryMatcher.highlightRanges(in: summary.title, query: query)
            )
        }

        var materialized = Materialized()
        materialized.results = ranked.results.compactMap(result)
        for (sessionID, session) in ranked.enrichments {
            materialized.enrichments[sessionID] = result(session)
        }
        return materialized
    }

    private func displayTexts(messageIDs: [Int64], db: AgentHistoryDatabase) throws -> [Int64: String] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        var texts: [Int64: String] = [:]
        for (id, text) in try db.query(
            "SELECT id, text FROM messages WHERE id IN (\(placeholders))",
            messageIDs.map { .integer($0) },
            map: { ($0.int64(0), $0.string(1)) }
        ) {
            texts[id] = text
        }
        return texts
    }

    // MARK: - Reader plumbing

    /// A reader with a read transaction and the cancellation progress handler. Database
    /// errors become `.cancelled` (interrupt, or the query was cancelled) or `.indexUnavailable`.
    private func withSearchReader<T>(
        cancellation: HistorySearchCancellation,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> T {
        do {
            return try readers.withReader { db in
                db.setProgressHandler(everyInstructions: tuning.progressHandlerInstructions) {
                    cancellation.isCancelled
                }
                defer { db.setProgressHandler(everyInstructions: 0, nil) }
                return try db.readTransaction { try body(db) }
            }
        } catch let error as AgentHistoryDatabaseError {
            if error.kind == .interrupted || cancellation.isCancelled {
                throw HistorySearchError.cancelled
            }
            throw Self.unavailable(error)
        }
    }

    /// A reader with a read transaction for the session queries; database errors become
    /// `.indexUnavailable`.
    func withReadTransaction<T>(_ body: (AgentHistoryDatabase) throws -> T) throws -> T {
        do {
            return try readers.withReader { db in try db.readTransaction { try body(db) } }
        } catch let error as AgentHistoryDatabaseError {
            throw Self.unavailable(error)
        }
    }

    static func unavailable(_ error: AgentHistoryDatabaseError) -> HistorySearchError {
        AgentHistoryLog.search.error("Index read failed: \(error.description, privacy: .public)")
        return .indexUnavailable(stateName(error.kind))
    }

    static func stateName(_ kind: AgentHistoryDatabaseError.Kind) -> String {
        switch kind {
        case .corrupt: "corrupt"
        case .notADatabase: "notADatabase"
        case .full: "full"
        case .busy: "busy"
        case .readOnly: "readOnly"
        case .cantOpen: "cantOpen"
        case .constraint: "constraint"
        case .interrupted: "interrupted"
        case .schemaTooNew: "newerSchema"
        case .misuse: "misuse"
        case .other: "other"
        }
    }

    private func checkCancelled(_ cancellation: HistorySearchCancellation) throws {
        if cancellation.isCancelled {
            throw HistorySearchError.cancelled
        }
    }

    private static func seconds(since start: UInt64) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

extension HistoryQuery {
    /// Whether the content tier would run for this query (some term is long enough for FTS or
    /// a substring scan). The palette uses it for the "type 3+ characters" hint and the preview.
    func hasContentTerms(tokenizer: AgentHistoryTokenizer) -> Bool {
        !terms.isEmpty && HistoryMatchPlan.make(query: self, tokenizer: tokenizer).mode != .metadataOnly
    }
}

// MARK: - Hit collection

/// Grades content rows into hits and keeps each session's ranking facts. One per search, used
/// on the searching thread only.
private final class HitCollector {
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
