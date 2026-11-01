import Foundation
import os

/// The metadata tier (spec §7.2): every keystroke, over the indexer's in-memory snapshot of
/// visible sessions. A pure view: the indexer owns the snapshot; this type only caches data
/// derived from it, per snapshot `generation` and exclusion set.
///
/// Everything it returns honours the configured excluded folders at query time (A-10), so a
/// session excluded after indexing never shows before the purge removes its rows. Tombstoned
/// and child sessions never reach the snapshot.
///
/// Thread-safe: the derived cache sits behind a lock and is immutable once built, so the
/// palette may call it on the main thread and the CLI/IPC path off it.
final class HistoryMetadataIndex: @unchecked Sendable {
    static let defaultLimit = 20

    /// Field weights (spec §7.2). The word-level gate uses the unweighted grade.
    static func weight(_ field: HistoryMetadataField) -> Double {
        switch field {
        case .title: 1.0
        case .branch: 0.6
        case .repo: 0.4
        case .folder: 0.3
        }
    }

    private let snapshotProvider: @Sendable () -> AgentHistoryMetadataSnapshot
    private let exclusionsProvider: @Sendable () -> AgentHistoryExclusionMatcher
    private let cache = OSAllocatedUnfairLock<Derived?>(initialState: nil)

    init(
        snapshot: @escaping @Sendable () -> AgentHistoryMetadataSnapshot,
        exclusions: @escaping @Sendable () -> AgentHistoryExclusionMatcher
    ) {
        self.snapshotProvider = snapshot
        self.exclusionsProvider = exclusions
    }

    // MARK: - Lookups

    /// The `limit` most recently updated sessions in `scope`.
    func recent(limit: Int, scope: AgentHistoryScope) -> [AgentHistorySessionSummary] {
        guard limit > 0 else { return [] }
        var result: [AgentHistorySessionSummary] = []
        for entry in currentDerived().entries where Self.admits(entry, scope: scope) {
            result.append(entry.summary)
            if result.count == limit { break }
        }
        return result
    }

    func sessionCount(scope: AgentHistoryScope) -> Int {
        let entries = currentDerived().entries
        guard case .project = scope else { return entries.count }
        return entries.reduce(0) { Self.admits($1, scope: scope) ? $0 + 1 : $0 }
    }

    func summary(forSessionID id: Int64) -> AgentHistorySessionSummary? {
        let derived = currentDerived()
        return derived.indexByID[id].map { derived.entries[$0].summary }
    }

    /// Summaries for live panes ("Running now"), in `keys` order; unknown keys are skipped.
    func sessions(for keys: [AgentHistorySessionKey]) -> [AgentHistorySessionSummary] {
        let derived = currentDerived()
        return keys.compactMap { key in derived.indexByKey[key].map { derived.entries[$0].summary } }
    }

    // MARK: - Search

    /// Grades every session in scope that passes the filters.
    ///
    /// - Each term is graded per field (title, branch, repo name, folder name); its credit is
    ///   the best weighted field grade. Every term must match some field.
    /// - `quality` = mean weighted credit, +0.25 when the typed phrase is in the title.
    ///   `isWordLevel` comes from the mean of the unweighted best grades, so a whole-word
    ///   branch hit stays word-level even though it weighs 0.6.
    /// - `score = quality × usage × repoBoost × archivedPenalty` (`HistoryRanker`).
    /// - The top `limit` by `HistoryRankKey` are kept in a bounded heap; highlights and notes
    ///   are computed for the winners only.
    /// - Without terms (filters only, or empty), sessions come newest first, score 0.
    func search(_ query: HistoryQuery, context: HistorySearchContext, limit: Int = defaultLimit) -> HistoryMetadataResponse {
        let start = DispatchTime.now().uptimeNanoseconds
        let derived = currentDerived()
        let filters = PreparedFilters(query.filters)
        let results: [HistoryMetadataResult]
        if limit <= 0 {
            results = []
        } else if query.terms.isEmpty {
            results = recencyResults(derived, filters: filters, scope: context.scope, limit: limit)
        } else {
            results = gradedResults(derived, query: query, filters: filters, context: context, limit: limit)
        }
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return HistoryMetadataResponse(query: query, generation: derived.generation, results: results, elapsed: elapsed)
    }

    private func recencyResults(
        _ derived: Derived,
        filters: PreparedFilters,
        scope: AgentHistoryScope,
        limit: Int
    ) -> [HistoryMetadataResult] {
        var results: [HistoryMetadataResult] = []
        for entry in derived.entries where Self.admits(entry, scope: scope) && filters.admits(entry) {
            results.append(HistoryMetadataResult(
                session: entry.summary, score: 0, isWordLevel: true, titleHighlights: [], note: nil))
            if results.count == limit { break }
        }
        return results
    }

    private func gradedResults(
        _ derived: Derived,
        query: HistoryQuery,
        filters: PreparedFilters,
        context: HistorySearchContext,
        limit: Int
    ) -> [HistoryMetadataResult] {
        let terms = PreparedTerms(query)
        var heap = HistoryBoundedRankHeap<Candidate>(capacity: limit)
        for (position, entry) in derived.entries.enumerated() {
            guard Self.admits(entry, scope: context.scope),
                  filters.admits(entry),
                  terms.allOccur(in: entry),
                  let evaluation = Self.evaluate(entry, terms: terms)
            else { continue }
            let score = evaluation.quality
                * HistoryRanker.sessionMultiplier(HistoryRankFacts(summary: entry.summary), context: context)
            let key = HistoryRankKey(
                isWordLevel: evaluation.isWordLevel,
                score: score,
                atMs: entry.updatedAtMs,
                sessionID: entry.id
            )
            heap.offer(Candidate(position: position, key: key, noteField: evaluation.noteField))
        }

        return heap.sorted().map { candidate in
            let summary = derived.entries[candidate.position].summary
            return HistoryMetadataResult(
                session: summary,
                score: candidate.key.score,
                isWordLevel: candidate.key.isWordLevel,
                titleHighlights: HistoryMatcher.highlightRanges(in: summary.title, query: query),
                note: candidate.noteField.flatMap { Self.note($0, of: summary) }
            )
        }
    }

    // MARK: - Grading

    private struct Evaluation {
        let quality: Double
        let isWordLevel: Bool
        /// The best-weighted non-title field that won a term, if any.
        let noteField: HistoryMetadataField?
    }

    private struct Candidate: HistoryRankKeyed {
        let position: Int
        let key: HistoryRankKey
        let noteField: HistoryMetadataField?
    }

    private static func evaluate(_ entry: Entry, terms: PreparedTerms) -> Evaluation? {
        var weightedSum = 0.0
        var unweightedSum = 0.0
        var noteField: HistoryMetadataField?
        var noteCredit = 0.0
        for termList in terms.single {
            var bestWeighted = 0.0
            var bestUnweighted = 0.0
            var bestField: HistoryMetadataField?
            for key in entry.fields {
                let field = key.field
                guard let credit = credit(of: termList, in: key.bytes) else { continue }
                bestUnweighted = max(bestUnweighted, credit)
                let weighted = credit * weight(field)
                // Strictly greater: on a tie the earlier field (title, branch, repo, folder) wins.
                if weighted > bestWeighted {
                    bestWeighted = weighted
                    bestField = field
                }
            }
            guard bestUnweighted > 0 else { return nil }
            weightedSum += bestWeighted
            unweightedSum += bestUnweighted
            if let bestField, bestField != .title, bestWeighted > noteCredit {
                noteField = bestField
                noteCredit = bestWeighted
            }
        }

        let count = Double(terms.single.count)
        var quality = weightedSum / count
        if let phrase = terms.phrase, let title = entry.fields.first, title.field == .title,
           credit(of: phrase, in: title.bytes) != nil {
            quality += HistoryMatcher.phraseBonus
        }
        return Evaluation(
            quality: quality,
            isWordLevel: unweightedSum / count >= HistoryMatcher.wordLevelThreshold - 1e-9,
            noteField: noteField
        )
    }

    /// The matcher's credit for a one-term list, or nil when it has none.
    private static func credit(of termList: [HistoryQueryTerm], in bytes: [UInt8]) -> Double? {
        bytes.withUnsafeBufferPointer { buffer in
            HistoryMatcher.grade(normalizedUTF8: buffer, terms: termList, phraseText: nil)?.baseQuality
        }
    }

    private static func note(_ field: HistoryMetadataField, of summary: AgentHistorySessionSummary) -> HistoryMatchNote? {
        let value: String? = switch field {
        case .title: nil
        case .branch: summary.branch
        case .repo: summary.repoName
        case .folder: summary.folderName
        }
        return value.map { .field(field, value: $0) }
    }

    private static func admits(_ entry: Entry, scope: AgentHistoryScope) -> Bool {
        guard case .project(let project) = scope else { return true }
        return project.admits(repoRoot: entry.repoRoot, mainRepoRoot: entry.mainRepoRoot, cwd: entry.cwd)
    }

    // MARK: - Derived cache

    private func currentDerived() -> Derived {
        let snapshot = snapshotProvider()
        let exclusions = exclusionsProvider()
        if let cached = cache.withLock({ $0 }),
           cached.isBuilt(from: snapshot), cached.exclusions == exclusions {
            return cached
        }
        // Built outside the lock; a concurrent rebuild of the same generation is harmless.
        let built = Derived(snapshot: snapshot, exclusions: exclusions)
        cache.withLock { $0 = built }
        return built
    }
}

// MARK: - Derived data

extension HistoryMetadataIndex {
    fileprivate struct FieldKey: Sendable {
        let field: HistoryMetadataField
        let bytes: [UInt8]
    }

    /// One visible, non-excluded session with its search keys as bytes. A class, and the hot
    /// fields copied out of the summary, so the per-keystroke loop moves one reference per
    /// session instead of copying the whole summary.
    fileprivate final class Entry: Sendable {
        let summary: AgentHistorySessionSummary
        let id: Int64
        let agent: AgentHistoryAgent
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let cwd: String?
        let repoRoot: String?
        let mainRepoRoot: String?
        /// Non-empty folded keys in grading order: title, branch, repo, folder.
        let fields: [FieldKey]
        /// All keys joined by NUL, for the per-term presence pre-check.
        let haystack: [UInt8]
        let mainRepoNameLower: String?
        let repoNameLower: String?
        let branchLower: String?

        init(_ summary: AgentHistorySessionSummary) {
            self.summary = summary
            id = summary.id
            agent = summary.agent
            createdAtMs = summary.createdAtMs
            updatedAtMs = summary.updatedAtMs
            cwd = summary.cwd
            repoRoot = summary.repoRoot
            mainRepoRoot = summary.mainRepoRoot
            var fields: [FieldKey] = []
            let keys: [(HistoryMetadataField, String?)] = [
                (.title, summary.titleKey), (.branch, summary.branchKey),
                (.repo, summary.repoKey), (.folder, summary.folderKey),
            ]
            var haystack: [UInt8] = []
            for (field, key) in keys {
                guard let key, !key.isEmpty else { continue }
                let bytes = Array(key.utf8)
                fields.append(FieldKey(field: field, bytes: bytes))
                if !haystack.isEmpty { haystack.append(0) }
                haystack.append(contentsOf: bytes)
            }
            self.fields = fields
            self.haystack = haystack
            self.mainRepoNameLower = Self.basename(summary.mainRepoRoot)?.lowercased()
            self.repoNameLower = Self.basename(summary.repoRoot)?.lowercased()
            self.branchLower = summary.branch?.lowercased()
        }

        private static func basename(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? nil : name
        }
    }

    /// Immutable per-(generation, exclusions) view of the snapshot.
    fileprivate final class Derived: Sendable {
        let generation: UInt64
        /// The snapshot's session array, kept so its buffer identity can be compared: a new
        /// indexer (after off/on) restarts generations at zero, so a generation alone could
        /// match a cache built from the previous indexer's snapshot.
        let sessions: [AgentHistorySessionSummary]
        let exclusions: AgentHistoryExclusionMatcher
        /// Snapshot order (updated desc, then id desc), excluded folders dropped.
        let entries: [Entry]
        let indexByID: [Int64: Int]
        let indexByKey: [AgentHistorySessionKey: Int]

        init(snapshot: AgentHistoryMetadataSnapshot, exclusions: AgentHistoryExclusionMatcher) {
            generation = snapshot.generation
            sessions = snapshot.sessions
            self.exclusions = exclusions
            var entries: [Entry] = []
            entries.reserveCapacity(snapshot.sessions.count)
            var indexByID: [Int64: Int] = [:]
            var indexByKey: [AgentHistorySessionKey: Int] = [:]
            indexByID.reserveCapacity(snapshot.sessions.count)
            indexByKey.reserveCapacity(snapshot.sessions.count)
            for summary in snapshot.sessions where !exclusions.excludesCanonical(summary.cwd) {
                indexByID[summary.id] = entries.count
                indexByKey[summary.key] = entries.count
                entries.append(Entry(summary))
            }
            self.entries = entries
            self.indexByID = indexByID
            self.indexByKey = indexByKey
        }

        /// Same generation and the very same session array (O(1); no element compare).
        func isBuilt(from snapshot: AgentHistoryMetadataSnapshot) -> Bool {
            guard generation == snapshot.generation, sessions.count == snapshot.sessions.count else {
                return false
            }
            if sessions.isEmpty {
                return true
            }
            let cachedBase = sessions.withUnsafeBufferPointer { $0.baseAddress }
            let snapshotBase = snapshot.sessions.withUnsafeBufferPointer { $0.baseAddress }
            return cachedBase == snapshotBase
        }
    }

    /// Query filters with their values lowered once per query.
    fileprivate struct PreparedFilters {
        let filters: HistoryQueryFilters
        /// `repo:` values with a `/`: exact paths.
        let repoPaths: [String]
        /// `repo:` values without a `/`: basenames, lowercased.
        let repoNames: [String]
        let branches: [String]
        let afterMs: Int64?
        let beforeMs: Int64?
        let isEmpty: Bool

        init(_ filters: HistoryQueryFilters) {
            self.filters = filters
            isEmpty = filters.isEmpty
            repoPaths = filters.repoNames.filter { $0.contains("/") }
            repoNames = filters.repoNames.filter { !$0.contains("/") }.map { $0.lowercased() }
            branches = filters.branches.map { $0.lowercased() }
            afterMs = filters.after.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            beforeMs = filters.before.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        }

        func admits(_ entry: Entry) -> Bool {
            if isEmpty { return true }
            guard filters.admits(agent: entry.agent) else { return false }
            if !repoPaths.isEmpty || !repoNames.isEmpty {
                let pathMatch = repoPaths.contains { $0 == entry.mainRepoRoot || $0 == entry.repoRoot }
                let nameMatch = repoNames.contains { $0 == entry.mainRepoNameLower || $0 == entry.repoNameLower }
                guard pathMatch || nameMatch else { return false }
            }
            if !branches.isEmpty {
                guard let branch = entry.branchLower, branches.contains(where: { branch.contains($0) }) else {
                    return false
                }
            }
            if let afterMs, entry.updatedAtMs < afterMs { return false }
            if let beforeMs, entry.createdAtMs >= beforeMs { return false }
            return true
        }
    }

    /// Per-query term lists, built once so the per-session loop does not allocate.
    fileprivate struct PreparedTerms {
        /// One single-term list per query term.
        let single: [[HistoryQueryTerm]]
        /// The typed phrase as one term (two or more terms only); graded on the title.
        let phrase: [HistoryQueryTerm]?

        init(_ query: HistoryQuery) {
            single = query.terms.map { [$0] }
            if query.terms.count >= 2, let phraseText = query.phraseText, !phraseText.isEmpty {
                phrase = [HistoryQueryTerm(text: phraseText, isPhrase: true)]
            } else {
                phrase = nil
            }
        }

        /// Cheap pre-check: every term's bytes occur in some key. Grading still decides.
        func allOccur(in entry: Entry) -> Bool {
            entry.haystack.withUnsafeBufferPointer { haystack in
                guard let base = haystack.baseAddress else { return false }
                for termList in single {
                    let found = termList[0].utf8.withUnsafeBufferPointer { needle in
                        guard let needleBase = needle.baseAddress else { return false }
                        return memmem(base, haystack.count, needleBase, needle.count) != nil
                    }
                    if !found { return false }
                }
                return true
            }
        }
    }
}

// MARK: - Bounded heap

protocol HistoryRankKeyed {
    var key: HistoryRankKey { get }
}

/// Keeps the best `capacity` elements by `HistoryRankKey` in O(n log k). The root is the worst
/// kept element, so a newcomer only has to beat it.
struct HistoryBoundedRankHeap<Element: HistoryRankKeyed> {
    let capacity: Int
    private var storage: [Element] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func offer(_ element: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(element)
            siftUp(storage.count - 1)
        } else if element.key.ranks(before: storage[0].key) {
            storage[0] = element
            siftDown(0)
        }
    }

    /// Best first.
    func sorted() -> [Element] {
        storage.sorted { $0.key.ranks(before: $1.key) }
    }

    /// Heap order: a parent ranks after (is worse than) its children.
    private func isWorse(_ lhs: Int, _ rhs: Int) -> Bool {
        storage[rhs].key.ranks(before: storage[lhs].key)
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(child, parent) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var worst = parent
            if left < storage.count, isWorse(left, worst) { worst = left }
            if right < storage.count, isWorse(right, worst) { worst = right }
            guard worst != parent else { return }
            storage.swapAt(parent, worst)
            parent = worst
        }
    }
}
