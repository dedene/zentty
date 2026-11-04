import Foundation

/// One search term, folded with `AgentHistorySearchText` (the ingest fold), so its bytes can be
/// compared directly against `messages.search_text`.
struct HistoryQueryTerm: Hashable, Sendable {
    /// Folded text. A phrase keeps its single inner spaces.
    let text: String
    let utf8: [UInt8]
    let scalarCount: Int
    /// Typed inside quotes (`"…"`, curly quotes or guillemets).
    let isPhrase: Bool
    /// Every non-space scalar is CJK (written without word spaces); such terms are useful from
    /// two characters on.
    let isCJK: Bool

    init(text: String, isPhrase: Bool) {
        self.text = text
        self.utf8 = Array(text.utf8)
        self.scalarCount = text.unicodeScalars.count
        self.isPhrase = isPhrase
        let wordScalars = text.unicodeScalars.filter { $0 != " " }
        self.isCJK = !wordScalars.isEmpty && wordScalars.allSatisfy(AgentHistorySearchText.isCJK)
    }
}

/// Filters from `agent:`, `repo:`, `branch:`, `before:` and `after:` operators.
///
/// Repo names and branches keep the value as typed; matching is case-insensitive downstream
/// (repo by basename, branch by substring). Several values of one operator are OR-ed.
struct HistoryQueryFilters: Hashable, Sendable {
    /// Empty means every agent, unless `excludesAllAgents` is set.
    var agents: Set<AgentHistoryAgent> = []
    var repoNames: [String] = []
    var branches: [String] = []
    /// Local start of day; exclusive upper bound.
    var before: Date?
    /// Local start of day; inclusive lower bound.
    var after: Date?
    /// The CLI's `--agent` and the query's `agent:` operators named disjoint agents, so no
    /// session can match. Kept separate because an empty `agents` set means "no agent filter".
    var excludesAllAgents = false

    var isEmpty: Bool {
        agents.isEmpty && !excludesAllAgents && repoNames.isEmpty && branches.isEmpty
            && before == nil && after == nil
    }

    func admits(agent: AgentHistoryAgent) -> Bool {
        if excludesAllAgents {
            return false
        }
        return agents.isEmpty || agents.contains(agent)
    }
}

/// An operator as typed, for the palette's filter pills.
struct HistoryOperatorToken: Hashable, Sendable {
    enum Key: String, Sendable, CaseIterable {
        case agent, repo, branch, before, after
    }

    let key: Key
    /// The value as typed, without its quotes or surrounding spaces. Empty while the user has
    /// typed only `key:`.
    let rawValue: String
    /// The whole token in `HistoryQuery.raw`, key and quotes included.
    let rangeInRaw: Range<String.Index>
    /// The value parsed into a filter. Invalid tokens were also added as a plain term.
    let isValid: Bool

    /// `key:` with nothing after it yet: a pending pill, neither a filter nor a term.
    var isPending: Bool { rawValue.isEmpty }
}

/// A parsed palette or CLI query. Build with `HistoryQueryParser.parse`.
struct HistoryQuery: Hashable, Sendable {
    /// The input, truncated to `HistoryQueryParser.maxQueryLength` characters.
    let raw: String
    let terms: [HistoryQueryTerm]
    let filters: HistoryQueryFilters
    let operatorTokens: [HistoryOperatorToken]
    /// All term texts joined by a space when there are at least two terms (phrase bonus).
    let phraseText: String?

    var isEmpty: Bool { terms.isEmpty && filters.isEmpty }

    /// Identity of the content search: queries that differ only in whitespace, case, operator
    /// spelling or operator position share a key, so the content tier can skip re-running.
    var contentKey: ContentKey { ContentKey(terms: terms.map(\.text), filters: filters) }

    struct ContentKey: Hashable, Sendable {
        let terms: [String]
        let filters: HistoryQueryFilters
    }
}
