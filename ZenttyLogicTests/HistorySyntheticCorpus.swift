import Foundation
@testable import Zentty

/// SplitMix64: a tiny, fully specified PRNG, so a seed gives the same corpus on every machine and
/// Swift version (unlike the standard library's `random(in:using:)` helpers).
struct HistorySplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Uniform in `0..<bound` (multiply-high; the bias is irrelevant at these sizes); 0 when
    /// `bound` is not positive.
    mutating func below(_ bound: Int) -> Int {
        Int(next().multipliedFullWidth(by: UInt64(max(bound, 1))).high)
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }

    /// Standard normal (Box–Muller).
    mutating func normal() -> Double {
        let u1 = max(unit(), .leastNonzeroMagnitude)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * unit())
    }

    mutating func logNormal(median: Double, sigma: Double) -> Double {
        median * exp(sigma * normal())
    }

    mutating func hex(_ count: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<count).map { _ in digits[below(16)] })
    }
}

/// A deterministic synthetic Agent History corpus for the search benchmarks (spec §10, §11).
///
/// - Text: a ~5k-word vocabulary drawn with a Zipf distribution (common English and developer
///   words first, then generated pseudo-words), mixed with hex hashes, file paths and code tokens.
/// - Lengths: log-normal, median ~200 characters for user turns and ~900 for agent turns; 1 % of
///   messages are longer than 8 KB.
/// - Shape: sessions spread over 4 agents, 40 repositories (some repo-less, some worktrees) and
///   two years of timestamps, each with alternating user/agent turns and a few artifacts.
///
/// Generation is pure (`sessions()`, `messages(for:)`); `populate(_:)` streams the rows into a
/// `HistorySearchFixture` index through `AgentHistoryStore` in ~5k-row transactions, so the 1M
/// message benchmark never holds the corpus in memory.
struct HistorySyntheticCorpus {
    struct Configuration: Sendable {
        var seed: UInt64 = 0x5EED_2026_1101
        var sessionCount: Int
        var messageCount: Int
        var repoCount = 40
        var vocabularySize = 5_000
        var spanDays = 730
        var rowsPerTransaction = 5_000
        var nowMs = HistorySearchFixture.nowMs

        /// The always-on smoke corpus: 20k messages.
        static let small = Configuration(sessionCount: 200, messageCount: 20_000)
        /// The benchmark corpus of spec §10: 10k sessions, 1M messages.
        static let benchmark = Configuration(sessionCount: 10_000, messageCount: 1_000_000)
    }

    struct SessionPlan: Sendable {
        let index: Int
        let nativeID: String
        let agent: AgentHistoryAgent
        let title: String
        let cwd: String
        let repoRoot: String?
        let mainRepoRoot: String?
        let branch: String
        let archived: Bool
        let startMs: Int64
        let messageCount: Int
    }

    struct MessagePlan: Sendable {
        let seq: Int
        let role: AgentHistoryRole
        let atMs: Int64
        let text: String
    }

    struct Stats: Sendable {
        var sessions = 0
        var messages = 0
        var artifacts = 0
        var characters = 0
        var longMessages = 0
        var userLengths: [Int] = []
        var agentLengths: [Int] = []
        var agents: Set<AgentHistoryAgent> = []
        var repos: Set<String> = []
        var minAtMs = Int64.max
        var maxAtMs = Int64.min
        /// Samples of emitted tokens, for building queries that hit.
        var hexes = Reservoir()
        var paths = Reservoir()
        var codeTokens = Reservoir()
        var phrases = Reservoir()
        var populateSeconds: TimeInterval = 0
    }

    /// A fixed-size uniform sample (Algorithm R).
    struct Reservoir: Sendable {
        static let capacity = 64
        private(set) var values: [String] = []
        private var seen = 0

        mutating func offer(_ value: String, rng: inout HistorySplitMix64) {
            seen += 1
            if values.count < Self.capacity {
                values.append(value)
            } else {
                let slot = rng.below(seen)
                if slot < Self.capacity { values[slot] = value }
            }
        }
    }

    /// One benchmark query: the raw palette text and, optionally, a project scope key.
    struct Query: Sendable {
        let raw: String
        let scopeKey: String?
    }

    static let longMessageThreshold = 8_192
    static let reposRoot = "/synthetic/src"

    let configuration: Configuration
    let vocabulary: [String]
    let repoRoots: [String]
    private let zipf: [Double]

    init(_ configuration: Configuration) {
        self.configuration = configuration
        var rng = HistorySplitMix64(seed: configuration.seed)
        vocabulary = Self.makeVocabulary(size: configuration.vocabularySize, rng: &rng)
        repoRoots = (0..<configuration.repoCount).map { index in
            "\(Self.reposRoot)/\(Self.commonWords[(index * 7) % Self.commonWords.count])-\(index)"
        }
        var cumulative: [Double] = []
        cumulative.reserveCapacity(vocabulary.count)
        var total = 0.0
        for rank in vocabulary.indices {
            total += 1 / pow(Double(rank + 1), 1.05)
            cumulative.append(total)
        }
        zipf = cumulative
    }

    // MARK: - Vocabulary

    /// The head of the Zipf ranking: frequent English and developer words.
    static let commonWords: [String] = """
        the to and of a in is it that for you this with on be not we can are use but if have \
        from so will should need now just then also what when there file test build fix error run \
        code change update function add check new make work let see one like call return value type \
        config main branch commit merge review issue bug crash parser cache index search query worker \
        sidebar render layout window pane session agent model token stream event handler state store \
        reader writer schema migration deploy release version module package import export server client \
        request response timeout retry login auth payment invoice order user account setting theme font \
        color icon button menu toolbar palette preview transcript history terminal shell command script
        """.split(separator: " ").map(String.init)

    /// Pseudo-word syllables (onset + vowel + coda, ~2.7k combinations), varied enough that
    /// trigram doclists look like natural text rather than a few dozen repeated syllables.
    private static let onsets = ["b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s",
                                 "t", "v", "w", "z", "br", "cr", "dr", "st", "tr", "pl", "gr", "sh", "ch", "th"]
    private static let vowels = ["a", "e", "i", "o", "u", "ai", "ea", "ou"]
    private static let codas = ["", "n", "r", "s", "t", "l", "m", "x", "nd", "st", "ck", "ng"]

    private static func makeVocabulary(size: Int, rng: inout HistorySplitMix64) -> [String] {
        var words = commonWords
        var seen = Set(words)
        while words.count < size {
            let parts = 2 + rng.below(2)
            let word = (0..<parts).map { _ in rng.pick(onsets) + rng.pick(vowels) + rng.pick(codas) }.joined()
            guard word.count >= 4, word.count <= 14, seen.insert(word).inserted else { continue }
            words.append(word)
        }
        return Array(words.prefix(size))
    }

    /// A word by Zipf rank.
    func zipfWord(_ rng: inout HistorySplitMix64) -> String {
        let target = rng.unit() * (zipf.last ?? 1)
        var low = 0
        var high = zipf.count - 1
        while low < high {
            let mid = (low + high) / 2
            if zipf[mid] < target { low = mid + 1 } else { high = mid }
        }
        return vocabulary[low]
    }

    // MARK: - Sessions

    /// Every session's metadata and message count; message counts sum to `messageCount`.
    func sessions() -> [SessionPlan] {
        let config = configuration
        var rng = HistorySplitMix64(seed: config.seed ^ 0xA5A5_A5A5)
        let agents = AgentHistoryAgent.allCases
        let spanMs = Int64(config.spanDays) * HistorySearchFixture.dayMs

        // Log-normal session sizes, scaled to the exact total; every session keeps a user turn
        // and an agent reply.
        let minimum = min(2, config.messageCount / max(config.sessionCount, 1))
        let weights = (0..<config.sessionCount).map { _ in rng.logNormal(median: 1, sigma: 1.1) }
        let weightSum = weights.reduce(0, +)
        let spare = config.messageCount - minimum * config.sessionCount
        var counts = weights.map { minimum + Int(Double(spare) * $0 / weightSum) }
        var remainder = config.messageCount - counts.reduce(0, +)
        var cursor = 0
        while remainder > 0 {
            counts[cursor % counts.count] += 1
            remainder -= 1
            cursor += 1
        }

        return (0..<config.sessionCount).map { index in
            let agent = agents[rng.below(agents.count)]
            let titleWords = (0..<(2 + rng.below(4))).map { _ in zipfWord(&rng) }
            let branch = rng.chance(0.55) ? "main" : "feat/\(zipfWord(&rng))-\(zipfWord(&rng))"
            var repoRoot: String?
            var mainRepoRoot: String?
            let cwd: String
            if rng.chance(0.1) {
                cwd = "/synthetic/scratch/\(vocabulary[rng.below(vocabulary.count)])"
            } else {
                // Skewed towards the first repos, like real usage.
                let repo = repoRoots[min(Int(Double(repoRoots.count) * pow(rng.unit(), 2)), repoRoots.count - 1)]
                mainRepoRoot = repo
                if branch != "main", rng.chance(0.3) {
                    repoRoot = "\(repo)-worktrees/\(branch.replacingOccurrences(of: "/", with: "-"))"
                } else {
                    repoRoot = repo
                }
                cwd = rng.chance(0.3) ? "\(repoRoot!)/Sources" : repoRoot!
            }
            // Leave room for the session's own turns before `now`.
            let startMs = config.nowMs - 2 * HistorySearchFixture.dayMs - Int64(rng.unit() * Double(spanMs))
            return SessionPlan(
                index: index,
                nativeID: Self.nativeID(agent: agent, rng: &rng),
                agent: agent,
                title: titleWords.joined(separator: " "),
                cwd: cwd,
                repoRoot: repoRoot,
                mainRepoRoot: mainRepoRoot,
                branch: branch,
                archived: rng.chance(0.05),
                startMs: startMs,
                messageCount: counts[index]
            )
        }
    }

    private static func nativeID(agent: AgentHistoryAgent, rng: inout HistorySplitMix64) -> String {
        switch agent {
        case .opencode:
            "ses_\(rng.hex(26))"
        default:
            "\(rng.hex(8))-\(rng.hex(4))-4\(rng.hex(3))-a\(rng.hex(3))-\(rng.hex(12))"
        }
    }

    // MARK: - Messages

    /// The session's turns, alternating user and agent, one to 120 seconds apart.
    func messages(for session: SessionPlan) -> [MessagePlan] {
        var rng = sessionRNG(session)
        var atMs = session.startMs
        return (0..<session.messageCount).map { seq in
            let role: AgentHistoryRole = seq.isMultiple(of: 2) ? .user : .agent
            let length = messageLength(role: role, rng: &rng)
            let message = MessagePlan(seq: seq, role: role, atMs: atMs, text: text(length: length, rng: &rng))
            atMs += 1_000 + Int64(rng.below(119_000))
            return message
        }
    }

    private func sessionRNG(_ session: SessionPlan) -> HistorySplitMix64 {
        HistorySplitMix64(seed: configuration.seed &+ UInt64(session.index + 1) &* 0x9E37_79B9_7F4A_7C15)
    }

    private func messageLength(role: AgentHistoryRole, rng: inout HistorySplitMix64) -> Int {
        if rng.chance(0.01) {
            return Self.longMessageThreshold + 1 + rng.below(24_000)
        }
        let length = role == .user
            ? rng.logNormal(median: 200, sigma: 0.8)
            : rng.logNormal(median: 900, sigma: 0.9)
        return min(max(Int(length), 12), Self.longMessageThreshold)
    }

    /// Text of about `length` characters: Zipf words with hashes, paths and code tokens mixed in.
    private func text(length: Int, rng: inout HistorySplitMix64) -> String {
        var text = ""
        text.reserveCapacity(length + 64)
        var wordsInSentence = 0
        // ASCII only, so `utf8.count` (O(1)) is the character count.
        while text.utf8.count < length {
            if !text.isEmpty {
                text += wordsInSentence == 0 ? (rng.chance(0.15) ? "\n" : " ") : " "
            }
            let roll = rng.unit()
            if roll < 0.02 {
                text += rng.chance(0.5) ? rng.hex(7) : rng.hex(40)
            } else if roll < 0.045 {
                text += path(&rng)
            } else if roll < 0.08 {
                text += codeToken(&rng)
            } else {
                let word = zipfWord(&rng)
                text += wordsInSentence == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
            }
            wordsInSentence += 1
            if wordsInSentence >= 6 + rng.below(12) {
                text += "."
                wordsInSentence = 0
            }
        }
        return text
    }

    private func path(_ rng: inout HistorySplitMix64) -> String {
        let folder = zipfWord(&rng)
        let name = zipfWord(&rng).capitalized + zipfWord(&rng).capitalized
        let ext = rng.pick(["swift", "ts", "rb", "go", "md", "json"])
        return rng.chance(0.5) ? "Sources/\(folder)/\(name).\(ext)" : "src/\(folder)/\(name.lowercased()).\(ext)"
    }

    private func codeToken(_ rng: inout HistorySplitMix64) -> String {
        let first = zipfWord(&rng)
        let second = zipfWord(&rng)
        switch rng.below(4) {
        case 0: return first + second.capitalized
        case 1: return "\(first)_\(second)"
        case 2: return "\(first)\(second.capitalized)()"
        default: return "--\(first)-\(second)"
        }
    }

    // MARK: - Populate

    /// Inserts the corpus into `fixture` (sources first), in transactions of about
    /// `rowsPerTransaction` message rows.
    @discardableResult
    func populate(_ fixture: HistorySearchFixture) throws -> Stats {
        let start = Date()
        var sourceIDs: [AgentHistoryAgent: Int64] = [:]
        for agent in AgentHistoryAgent.allCases {
            sourceIDs[agent] = try fixture.addSource(agent)
        }
        let writer = try fixture.writer
        let store = try fixture.store()
        var stats = Stats()
        var sampleRNG = HistorySplitMix64(seed: configuration.seed ^ 0x5A5A_5A5A)
        var pending: [SessionPlan] = []
        var pendingRows = 0

        func flush() throws {
            guard !pending.isEmpty else { return }
            try writer.transaction {
                for session in pending {
                    try insert(session, sourceID: sourceIDs[session.agent]!, store: store,
                               stats: &stats, sampleRNG: &sampleRNG)
                }
            }
            pending.removeAll(keepingCapacity: true)
            pendingRows = 0
        }

        for session in sessions() {
            pending.append(session)
            pendingRows += session.messageCount
            if pendingRows >= configuration.rowsPerTransaction {
                try flush()
            }
        }
        try flush()
        stats.populateSeconds = Date().timeIntervalSince(start)
        return stats
    }

    private func insert(
        _ session: SessionPlan,
        sourceID: Int64,
        store: AgentHistoryStore,
        stats: inout Stats,
        sampleRNG: inout HistorySplitMix64
    ) throws {
        let messages = messages(for: session)
        var draft = AgentHistorySessionDraft(nativeID: session.nativeID)
        draft.title = session.title
        draft.titleKind = session.index.isMultiple(of: 3) ? .generated : .firstPrompt
        draft.cwd = session.cwd
        draft.repoRoot = session.repoRoot
        draft.mainRepoRoot = session.mainRepoRoot
        draft.branch = session.branch
        draft.archived = session.archived
        draft.createdAtMs = messages.first?.atMs ?? session.startMs
        draft.updatedAtMs = messages.last?.atMs ?? session.startMs
        draft.lastUserAtMs = messages.last { $0.role == .user }?.atMs
        let sessionID = try store.upsertSession(sourceID: sourceID, unitKey: session.nativeID, draft)

        try store.upsertMessages(sessionID: sessionID, messages.map { message in
            AgentHistoryMessageDraft(
                sessionNativeID: session.nativeID, seq: message.seq, role: message.role, atMs: message.atMs,
                text: message.text, searchText: AgentHistorySearchText.normalize(message.text))
        })
        try store.refreshTurnCount(sessionID: sessionID)

        var artifacts: [AgentHistoryArtifactDraft] = []
        for message in messages {
            record(message, into: &stats, artifacts: &artifacts, session: session, sampleRNG: &sampleRNG)
        }
        try store.upsertArtifacts(sessionID: sessionID, artifacts)

        stats.sessions += 1
        stats.artifacts += artifacts.count
        stats.agents.insert(session.agent)
        if let repo = session.mainRepoRoot { stats.repos.insert(repo) }
    }

    /// Updates the stats and reservoirs; in about a third of the agent turns, the first path,
    /// hash and flag become artifacts.
    private func record(
        _ message: MessagePlan,
        into stats: inout Stats,
        artifacts: inout [AgentHistoryArtifactDraft],
        session: SessionPlan,
        sampleRNG: inout HistorySplitMix64
    ) {
        stats.messages += 1
        let length = message.text.utf8.count
        stats.characters += length
        if length > Self.longMessageThreshold { stats.longMessages += 1 }
        if message.role == .user { stats.userLengths.append(length) } else { stats.agentLengths.append(length) }
        stats.minAtMs = min(stats.minAtMs, message.atMs)
        stats.maxAtMs = max(stats.maxAtMs, message.atMs)

        let tokens = message.text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        var artifactKinds: Set<AgentHistoryArtifactKind> = []
        let emitsArtifacts = message.role == .agent && sampleRNG.chance(0.3)
        for (offset, token) in tokens.enumerated() {
            let value = String(token.hasSuffix(".") ? token.dropLast() : token)
            let kind: AgentHistoryArtifactKind?
            if value.contains("/"), value.contains(".") {
                stats.paths.offer(value, rng: &sampleRNG)
                kind = .path
            } else if (value.count == 7 || value.count == 40), value.allSatisfy(\.isHexDigit),
                      value.contains(where: \.isNumber) {
                stats.hexes.offer(value, rng: &sampleRNG)
                kind = .commit
            } else if value.contains("_") || value.hasSuffix("()") || value.hasPrefix("--") {
                stats.codeTokens.offer(value, rng: &sampleRNG)
                kind = value.hasPrefix("--") ? .command : nil
            } else {
                kind = nil
                if offset + 1 < tokens.count, value.count >= 4, value.allSatisfy(\.isLowercase),
                   tokens[offset + 1].allSatisfy(\.isLowercase), sampleRNG.chance(0.01) {
                    stats.phrases.offer("\(value) \(tokens[offset + 1])", rng: &sampleRNG)
                }
            }
            guard emitsArtifacts, let kind, artifactKinds.insert(kind).inserted else { continue }
            let artifactValue = kind == .command ? "swift test \(value)" : value
            artifacts.append(AgentHistoryArtifactDraft(
                sessionNativeID: session.nativeID, seq: message.seq, kind: kind, value: artifactValue,
                searchText: AgentHistorySearchText.normalize(artifactValue), atMs: message.atMs))
        }
    }

    // MARK: - Queries

    /// `count` mixed palette queries: common, mid-frequency and rare words, prefixes, two-word
    /// and quoted phrases, hashes, paths, code tokens, operator filters, project scopes and misses.
    func mixedQueries(count: Int, stats: Stats) -> [Query] {
        var rng = HistorySplitMix64(seed: configuration.seed ^ 0x0BE7_C4)
        let agents = AgentHistoryAgent.allCases
        func word(_ ranks: Range<Int>) -> String {
            let upper = min(ranks.upperBound, vocabulary.count)
            return vocabulary[ranks.lowerBound + rng.below(max(upper - ranks.lowerBound, 1))]
        }
        func sampled(_ reservoir: Reservoir, fallback: String) -> String {
            reservoir.values.isEmpty ? fallback : rng.pick(reservoir.values)
        }
        func repoName() -> String { (rng.pick(repoRoots) as NSString).lastPathComponent }

        return (0..<count).map { index in
            switch index % 14 {
            case 0: return Query(raw: word(20..<200), scopeKey: nil)
            case 1: return Query(raw: word(200..<2_000), scopeKey: nil)
            case 2: return Query(raw: word(2_000..<vocabulary.count), scopeKey: nil)
            case 3: return Query(raw: String(word(100..<3_000).prefix(3 + rng.below(3))), scopeKey: nil)
            case 4:
                return Query(raw: sampled(stats.phrases, fallback: "\(word(20..<200)) \(word(200..<2_000))"),
                             scopeKey: nil)
            case 5: return Query(raw: "\"\(sampled(stats.phrases, fallback: word(20..<200)))\"", scopeKey: nil)
            case 6: return Query(raw: String(sampled(stats.hexes, fallback: "a3f9c1e").prefix(7)), scopeKey: nil)
            case 7:
                let path = sampled(stats.paths, fallback: "src/app/main.swift")
                return Query(raw: rng.chance(0.5) ? (path as NSString).lastPathComponent : path, scopeKey: nil)
            case 8: return Query(raw: sampled(stats.codeTokens, fallback: word(20..<200)), scopeKey: nil)
            case 9: return Query(raw: "\(word(20..<1_000)) agent:\(rng.pick(agents).rawValue)", scopeKey: nil)
            case 10: return Query(raw: "\(word(20..<1_000)) repo:\(repoName())", scopeKey: nil)
            case 11: return Query(raw: "\(word(20..<1_000)) \(word(20..<1_000))", scopeKey: rng.pick(repoRoots))
            case 12: return Query(raw: "\(word(50..<2_000)) after:2026-06-01", scopeKey: nil)
            default: return Query(raw: "zq\(rng.hex(6))xv", scopeKey: nil)
            }
        }
    }
}
