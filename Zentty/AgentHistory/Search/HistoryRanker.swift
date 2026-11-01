import Foundation

/// The session columns ranking needs. The content tier reads them with every hit row
/// (`s.updated_at, s.opens, s.last_opened_at, s.archived, s.main_repo_root, s.repo_root`);
/// the metadata tier and the CLI build them from a summary.
struct HistoryRankFacts: Hashable, Sendable {
    let updatedAtMs: Int64
    let opens: Int
    let lastOpenedAtMs: Int64?
    let isArchived: Bool
    let mainRepoRoot: String?
    let repoRoot: String?

    init(
        updatedAtMs: Int64,
        opens: Int,
        lastOpenedAtMs: Int64?,
        isArchived: Bool,
        mainRepoRoot: String?,
        repoRoot: String?
    ) {
        self.updatedAtMs = updatedAtMs
        self.opens = opens
        self.lastOpenedAtMs = lastOpenedAtMs
        self.isArchived = isArchived
        self.mainRepoRoot = mainRepoRoot
        self.repoRoot = repoRoot
    }

    init(summary: AgentHistorySessionSummary) {
        self.init(
            updatedAtMs: summary.updatedAtMs,
            opens: summary.opens,
            lastOpenedAtMs: summary.lastOpenedAtMs,
            isArchived: summary.isArchived,
            mainRepoRoot: summary.mainRepoRoot,
            repoRoot: summary.repoRoot
        )
    }
}

/// One session of the content tier after grouping and scoring, before the engine attaches the
/// summary, snippet and note.
struct HistoryRankedSession: Equatable, Sendable {
    let sessionID: Int64
    let best: HistoryContentHit
    /// Hits within `HistoryRanker.qualityEpsilon` of `best.quality`.
    let bestQualityHits: Int
    let totalHits: Int
    let score: Double
    /// At least one hit is word-level.
    let isWordLevel: Bool
}

struct HistoryRankedContent: Equatable, Sendable {
    /// Ranked, at most `limit`, without excluded sessions.
    let results: [HistoryRankedSession]
    /// Sessions the caller excluded (already shown by the metadata tier) that had hits.
    let enrichments: [Int64: HistoryRankedSession]
}

/// The order every search list uses: word-level before mid-word-only, then score, then the
/// newest matching time, then the higher session id.
struct HistoryRankKey: Sendable {
    let isWordLevel: Bool
    let score: Double
    let atMs: Int64
    let sessionID: Int64

    func ranks(before other: HistoryRankKey) -> Bool {
        if isWordLevel != other.isWordLevel { return isWordLevel }
        if score != other.score { return score > other.score }
        if atMs != other.atMs { return atMs > other.atMs }
        return sessionID > other.sessionID
    }
}

/// Ranks sessions (spec §7.5).
///
/// - Content hits are grouped by session. The best hit has the highest quality (artifact hits
///   already carry their 0.9 discount); ties within 1e-9 go to user, then agent, then
///   artifact, then the newest, then the higher row id.
/// - `score = quality × (1 + 0.15·log2(1 + bestQualityHits)) × usage × repoBoost × archivedPenalty`,
///   where only hits at the best quality count, so many weak hits never beat one strong one.
/// - `usage = min(2.5, 1 + 2^(−ageDays/14) + 0.5·log2(1 + opens·2^(−daysSinceOpen/14)))`, with
///   age from `updatedAtMs`. Opens without a last-opened time add nothing.
/// - `repoBoost = 1.2` only with scope `.all` when the current repository is the session's main
///   repo root or repo root; `archivedPenalty = 0.8`.
/// - Order: `HistoryRankKey` (word-level gate first).
enum HistoryRanker {
    static let contentLimit = 30
    static let qualityEpsilon = 1e-9
    static let hitsWeight = 0.15
    static let usageCap = 2.5
    static let usageHalfLifeDays = 14.0
    static let opensWeight = 0.5
    static let repoBoostFactor = 1.2
    static let archivedPenaltyFactor = 0.8

    private static let dayMs = 86_400_000.0

    // MARK: - Factors

    static func usage(_ facts: HistoryRankFacts, now: Date) -> Double {
        let nowMs = now.timeIntervalSince1970 * 1000
        let ageDays = max(0, nowMs - Double(facts.updatedAtMs)) / dayMs
        let recency = pow(2, -ageDays / usageHalfLifeDays)
        var opensTerm = 0.0
        if facts.opens > 0, let lastOpenedAtMs = facts.lastOpenedAtMs {
            let daysSinceOpen = max(0, nowMs - Double(lastOpenedAtMs)) / dayMs
            let decayedOpens = Double(facts.opens) * pow(2, -daysSinceOpen / usageHalfLifeDays)
            opensTerm = opensWeight * log2(1 + decayedOpens)
        }
        return min(usageCap, 1 + recency + opensTerm)
    }

    static func repoBoost(_ facts: HistoryRankFacts, context: HistorySearchContext) -> Double {
        guard case .all = context.scope, let current = context.currentRepositoryKey else { return 1 }
        return facts.mainRepoRoot == current || facts.repoRoot == current ? repoBoostFactor : 1
    }

    static func archivedPenalty(_ facts: HistoryRankFacts) -> Double {
        facts.isArchived ? archivedPenaltyFactor : 1
    }

    /// `usage × repoBoost × archivedPenalty`: everything but the match itself. The metadata tier
    /// scores `quality × sessionMultiplier`.
    static func sessionMultiplier(_ facts: HistoryRankFacts, context: HistorySearchContext) -> Double {
        usage(facts, now: context.now) * repoBoost(facts, context: context) * archivedPenalty(facts)
    }

    static func hitsMultiplier(bestQualityHits: Int) -> Double {
        1 + hitsWeight * log2(1 + Double(max(0, bestQualityHits)))
    }

    // MARK: - Content tier

    /// Groups, scores and orders content hits. Hits of a session missing from `facts` are
    /// dropped (the engine reads facts with every hit row, so this does not happen).
    static func rankContent(
        hits: [HistoryContentHit],
        facts: [Int64: HistoryRankFacts],
        context: HistorySearchContext,
        excludingSessionIDs: Set<Int64> = [],
        limit: Int = contentLimit
    ) -> HistoryRankedContent {
        var groups: [Int64: [HistoryContentHit]] = [:]
        for hit in hits where facts[hit.sessionID] != nil {
            groups[hit.sessionID, default: []].append(hit)
        }

        var ranked: [HistoryRankedSession] = []
        ranked.reserveCapacity(groups.count)
        var enrichments: [Int64: HistoryRankedSession] = [:]
        for (sessionID, sessionHits) in groups {
            guard let sessionFacts = facts[sessionID],
                  let session = rankSession(sessionID, hits: sessionHits, facts: sessionFacts, context: context)
            else { continue }
            if excludingSessionIDs.contains(sessionID) {
                enrichments[sessionID] = session
            } else {
                ranked.append(session)
            }
        }

        ranked.sort { rankKey($0).ranks(before: rankKey($1)) }
        if ranked.count > limit {
            ranked.removeSubrange(max(0, limit)...)
        }
        return HistoryRankedContent(results: ranked, enrichments: enrichments)
    }

    /// Whether `lhs` is a better representative of its session than `rhs`.
    static func isBetterHit(_ lhs: HistoryContentHit, than rhs: HistoryContentHit) -> Bool {
        if abs(lhs.quality - rhs.quality) > qualityEpsilon { return lhs.quality > rhs.quality }
        if lhs.role.tieBreakPriority != rhs.role.tieBreakPriority {
            return lhs.role.tieBreakPriority < rhs.role.tieBreakPriority
        }
        if lhs.atMs != rhs.atMs { return lhs.atMs > rhs.atMs }
        return lhs.rowID > rhs.rowID
    }

    private static func rankSession(
        _ sessionID: Int64,
        hits: [HistoryContentHit],
        facts: HistoryRankFacts,
        context: HistorySearchContext
    ) -> HistoryRankedSession? {
        guard var best = hits.first else { return nil }
        var isWordLevel = false
        for hit in hits {
            if isBetterHit(hit, than: best) { best = hit }
            isWordLevel = isWordLevel || hit.isWordLevel
        }
        let bestQualityHits = hits.reduce(0) { count, hit in
            abs(hit.quality - best.quality) <= qualityEpsilon ? count + 1 : count
        }
        let score = best.quality
            * hitsMultiplier(bestQualityHits: bestQualityHits)
            * sessionMultiplier(facts, context: context)
        return HistoryRankedSession(
            sessionID: sessionID,
            best: best,
            bestQualityHits: bestQualityHits,
            totalHits: hits.count,
            score: score,
            isWordLevel: isWordLevel
        )
    }

    private static func rankKey(_ session: HistoryRankedSession) -> HistoryRankKey {
        HistoryRankKey(
            isWordLevel: session.isWordLevel,
            score: session.score,
            atMs: session.best.atMs,
            sessionID: session.sessionID
        )
    }

    // MARK: - Merged (CLI)

    /// One row per session: whichever of its metadata and content matches ranks first under
    /// `HistoryRankKey` (so the higher score within the same word-level class; content wins an
    /// exact tie because it carries a snippet). Rows are then ordered by the same key, using
    /// the content hit's time or the session's `updatedAtMs`, and cut at `limit`.
    static func merge(
        metadata: [HistoryMetadataResult],
        content: [HistoryContentResult],
        limit: Int
    ) -> [HistoryMergedResult] {
        var bySession: [Int64: (key: HistoryRankKey, result: HistoryMergedResult)] = [:]

        func offer(_ result: HistoryMergedResult, atMs: Int64, winsTies: Bool) {
            let key = HistoryRankKey(
                isWordLevel: result.isWordLevel, score: result.score, atMs: atMs, sessionID: result.session.id)
            if let existing = bySession[result.session.id] {
                let better = key.isWordLevel != existing.key.isWordLevel
                    ? key.isWordLevel
                    : (key.score != existing.key.score ? key.score > existing.key.score : winsTies)
                guard better else { return }
            }
            bySession[result.session.id] = (key, result)
        }

        for row in metadata {
            offer(
                HistoryMergedResult(
                    session: row.session, score: row.score, isWordLevel: row.isWordLevel,
                    match: .metadata(note: row.note)),
                atMs: row.session.updatedAtMs,
                winsTies: false
            )
        }
        for row in content {
            offer(
                HistoryMergedResult(
                    session: row.session, score: row.score, isWordLevel: row.isWordLevel,
                    match: .content(role: row.best.role, at: row.best.at, snippet: row.snippet, note: row.note)),
                atMs: row.best.atMs,
                winsTies: true
            )
        }

        let ordered = bySession.values.sorted { $0.key.ranks(before: $1.key) }
        return ordered.prefix(max(0, limit)).map(\.result)
    }
}
