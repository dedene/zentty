import Foundation
import os

/// The content tier (spec §7.2) and the session queries behind the preview, the transcript and
/// the CLI. Every SQLite call runs on a reader connection from the pool (never the writer) on
/// the calling thread, so callers stay off the main thread; `searchContentAsync` does that hop.
///
/// A content search:
/// 1. plans the terms (`HistoryMatchPlan`); `.metadataOnly` returns an empty response;
/// 2. resolves a project scope, `repo:` and `branch:` once into the admitted sessions
///    (`HistoryContentQuery.admittedSessions`) and gates the walk on their ids; then walks the
///    FTS tables newest first with every filter inside the ordered scan (`HistoryContentQuery`).
///    Under the trigram tokenizer, a small admitted set (`substringScanTurnLimit` turns) finds
///    its message hits by `instr` over its own messages instead, which returns the same rows
///    without walking every term's trigram doclists. Without a usable tokenizer it scans the
///    newest `scanWindow` messages;
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
        var rowIDGateTurnLimit = HistoryContentQuery.rowIDGateTurnLimit
        var substringScanTurnLimit = HistoryContentQuery.substringScanTurnLimit
        var progressHandlerInstructions: Int32 = 1_000
        var cancellationCheckRows = 256
        /// Test seam: runs on the searching thread before each content row is graded.
        var willGradeRow: (@Sendable () -> Void)?
        /// Test seam: receives the route a content search chose, before it reads content rows.
        var didChooseRoute: (@Sendable (ContentRoute) -> Void)?

        init() {}
    }

    /// How a content search finds its message hits: the session gate of the walk and where the
    /// message rows come from. Reported to `Tuning.didChooseRoute` and the debug log.
    struct ContentRoute: Equatable, Sendable, CustomStringConvertible {
        enum Gate: String, Sendable {
            case perRow, sessions, contentRowIDs
        }

        enum Messages: String, Sendable {
            case ftsWalk, substringScan, scanFallback
        }

        let gate: Gate
        let messages: Messages

        init(gate: Gate, messages: Messages) {
            self.gate = gate
            self.messages = messages
        }

        init(sessionGate: HistoryContentQuery.SessionGate, messages: Messages) {
            switch sessionGate {
            case .perRow: self.gate = .perRow
            case .sessions: self.gate = .sessions
            case .contentRowIDs: self.gate = .contentRowIDs
            }
            self.messages = messages
        }

        var description: String { "\(gate.rawValue)/\(messages.rawValue)" }
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

    /// `resultLimit` caps the ranked sessions; the palette keeps the default
    /// (`HistoryRanker.contentLimit`), the merged CLI list passes its own limit.
    func searchContent(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excludingSessionIDs: Set<Int64>,
        resultLimit: Int = HistoryRanker.contentLimit,
        cancellation: HistorySearchCancellation
    ) throws -> HistoryContentResponse {
        let start = DispatchTime.now().uptimeNanoseconds
        let tokenizer = self.tokenizer
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
        let collector = HistoryHitCollector(
            query: query, sqlRequiredTerms: Set(plan.ftsTerms + plan.instrFilters), exclusions: exclusions,
            cancellation: cancellation, tuning: tuning)
        let tuning = self.tuning
        var chosenRoute: ContentRoute?

        let response: HistoryContentResponse = try withSearchReader(cancellation: cancellation) { db in
            var filters = filters
            var scansAdmittedMessages = false
            if filters.restrictsSessions {
                guard let admitted = try admittedSessions(filters, db: db) else { return emptyResponse() }
                filters.gate = admitted.turns <= Int64(tuning.rowIDGateTurnLimit)
                    ? .contentRowIDs(admitted.ids)
                    : .sessions(admitted.ids)
                scansAdmittedMessages = tokenizer == .trigram
                    && admitted.turns <= Int64(tuning.substringScanTurnLimit)
            }
            var truncated = false
            func choose(_ messages: ContentRoute.Messages) {
                let route = ContentRoute(sessionGate: filters.gate, messages: messages)
                chosenRoute = route
                tuning.didChooseRoute?(route)
            }
            switch plan.mode {
            case .fts:
                guard let match = plan.matchExpression else { return emptyResponse() }
                choose(scansAdmittedMessages ? .substringScan : .ftsWalk)
                let messageRows = scansAdmittedMessages
                    ? try collectAdmittedMessages(
                        db, terms: plan.ftsTerms, filters: filters, limit: tuning.messageLimit, collector: collector)
                    : try collector.collectMessages(
                        db, HistoryContentQuery.messages(match: match, filters: filters, limit: tuning.messageLimit))
                let artifactRows = try collector.collectArtifacts(
                    db, HistoryContentQuery.artifacts(match: match, filters: filters, limit: tuning.artifactLimit))
                truncated = messageRows >= tuning.messageLimit || artifactRows >= tuning.artifactLimit
            case .scan:
                choose(.scanFallback)
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
                excludingSessionIDs: excludingSessionIDs,
                limit: resultLimit
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
            Content search (\(chosenRoute?.description ?? "none", privacy: .public)): \
            \(collector.rows, privacy: .public) rows, \(collector.hits.count, privacy: .public) hits, \
            \(response.results.count, privacy: .public) results, \(response.enrichments.count, privacy: .public) \
            enrichments, truncated \(response.truncated, privacy: .public), \
            \(Int(response.elapsed * 1000), privacy: .public) ms
            """
        )
        return response
    }

    /// Runs `searchContent` on the search queue and calls `completion` on the main thread. When
    /// the reader pool was revoked after this call (Agent History turned off or its index
    /// deleted, which happens on main), the result is replaced by `.indexUnavailable("off")`.
    func searchContentAsync(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excludingSessionIDs: Set<Int64>,
        cancellation: HistorySearchCancellation,
        completion: @escaping @MainActor @Sendable (Result<HistoryContentResponse, Error>) -> Void
    ) {
        let revocationEpoch = readers.revocationEpoch
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
            DispatchQueue.main.async { [readers] in
                let delivered: Result<HistoryContentResponse, Error> = readers.revocationEpoch == revocationEpoch
                    ? result
                    : .failure(HistorySearchError.indexUnavailable(Self.stateName(.revoked)))
                MainActor.assumeIsolated { completion(delivered) }
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
        // The index gates on the agent selection itself; this keeps the merge honest when it
        // was built with another provider.
        let agents = enabledAgents
        let metadata = metadataIndex.search(query, context: context, limit: limit).results
            .filter { agents.contains($0.session.agent) }
        if cancellation.isCancelled {
            throw HistorySearchError.cancelled
        }
        // Content ranks at least `limit` sessions, or content-only matches could never fill the
        // rows past the palette's cap.
        let content = try searchContent(
            query, context: context, excludingSessionIDs: [],
            resultLimit: max(limit, HistoryRanker.contentLimit), cancellation: cancellation)
        return HistoryRanker.merge(metadata: metadata, content: content.results, limit: limit)
    }

    /// Resolves a project scope, `repo:` and `branch:` once (with visibility and the agent
    /// selection) into the admitted session ids and their summed turn count, so the walk can
    /// gate on ids instead of filtering every candidate row. Nil when no session is admitted.
    private func admittedSessions(
        _ filters: HistoryContentQuery.Filters,
        db: AgentHistoryDatabase
    ) throws -> (ids: [Int64], turns: Int64)? {
        let statement = HistoryContentQuery.admittedSessions(filters: filters)
        var ids: [Int64] = []
        var turns: Int64 = 0
        try db.query(statement.sql, statement.bindings) { row in
            ids.append(row.int64(0))
            turns += row.int64(1)
        }
        return ids.isEmpty ? nil : (ids, turns)
    }

    /// The message hits of a small admitted set under the trigram tokenizer: every matching id
    /// (`HistoryContentQuery.substringScan`), of which the newest `limit` are read and graded,
    /// the same rows the FTS walk would return. Returns the number of matching messages, so
    /// `limit` or more means truncated, as for the walk.
    private func collectAdmittedMessages(
        _ db: AgentHistoryDatabase,
        terms: [String],
        filters: HistoryContentQuery.Filters,
        limit: Int,
        collector: HistoryHitCollector
    ) throws -> Int {
        let scan = HistoryContentQuery.substringScan(terms: terms, filters: filters)
        var ids = try db.query(scan.sql, scan.bindings) { $0.int64(0) }
        let matching = ids.count
        guard matching > 0, limit > 0 else { return matching }
        ids.sort(by: >)
        _ = try collector.collectMessages(db, HistoryContentQuery.messages(ids: Array(ids.prefix(limit))))
        return matching
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
        case .revoked: "off"
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
