import Foundation

/// Parses a palette or CLI query into folded terms, operator filters and pill tokens.
///
/// Rules:
/// - The input is cut to `maxQueryLength` characters first; that prefix is `HistoryQuery.raw`.
/// - Whitespace separates tokens. A quote (`"`, or any typographic double quote that
///   `AgentHistorySearchText` straightens to `"`) opens a phrase that runs to the next such
///   quote, or to the end when unterminated.
/// - `agent:`, `repo:`, `branch:`, `before:` and `after:` (key case-insensitive) become filters.
///   The value may be quoted. An empty value is a pending pill (no filter, no term); a value
///   that does not parse turns the whole token into a plain term.
/// - `agent:` takes `claude`, `claude-code`, `claudecode`, `cc`, `codex`, `grok`, `opencode`,
///   `open-code`, or a prefix of at least two characters that names exactly one agent.
/// - `before:`/`after:` take `YYYY-MM-DD`, validated by a round trip through the calendar and
///   stored as that day's local start (before exclusive, after inclusive).
/// - Terms are folded with `AgentHistorySearchText.normalize`, deduplicated and capped at
///   `maxTerms`.
enum HistoryQueryParser {
    static let maxQueryLength = 200
    static let maxTerms = 8

    static func parse(_ raw: String, calendar: Calendar = .current) -> HistoryQuery {
        parse(raw, extraAgents: [], calendar: calendar)
    }

    /// `extraAgents` (the CLI's `--agent`) is intersected with any `agent:` operator; when the
    /// two are disjoint the filters exclude every agent.
    static func parse(_ raw: String, extraAgents: Set<AgentHistoryAgent>, calendar: Calendar = .current) -> HistoryQuery {
        let text = String(raw.prefix(maxQueryLength))
        var state = ParseState(calendar: calendar)
        for token in tokenize(text) {
            state.consume(token, in: text)
        }

        var filters = state.filters
        if !extraAgents.isEmpty {
            if filters.agents.isEmpty {
                filters.agents = extraAgents
            } else {
                filters.agents.formIntersection(extraAgents)
                filters.excludesAllAgents = filters.agents.isEmpty
            }
        }

        let terms = state.terms
        let phraseText = terms.count >= 2 ? terms.map(\.text).joined(separator: " ") : nil
        return HistoryQuery(
            raw: text,
            terms: terms,
            filters: filters,
            operatorTokens: state.operatorTokens,
            phraseText: phraseText
        )
    }

    // MARK: - Tokens

    private struct Token {
        enum Kind {
            /// Bare text up to whitespace or a quote.
            case word(String)
            /// Quoted text, quotes stripped.
            case phrase(String)
            /// `key:` followed by a value (quoted value already unquoted).
            case operatorToken(HistoryOperatorToken.Key, value: String)
        }

        let kind: Kind
        let range: Range<String.Index>
    }

    private static func isQuote(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else {
            return false
        }
        return scalar == "\"" || AgentHistorySearchText.straightQuote(for: scalar) == UInt8(ascii: "\"")
    }

    /// Reads a quoted run starting at the opening quote `start`. Returns the inner text and the
    /// index just past the closing quote (or `end` when unterminated).
    private static func readQuoted(_ text: String, from start: String.Index) -> (inner: Substring, next: String.Index) {
        let innerStart = text.index(after: start)
        var index = innerStart
        while index < text.endIndex {
            if isQuote(text[index]) {
                return (text[innerStart..<index], text.index(after: index))
            }
            index = text.index(after: index)
        }
        return (text[innerStart..<text.endIndex], text.endIndex)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            if isQuote(character) {
                let (inner, next) = readQuoted(text, from: index)
                tokens.append(Token(kind: .phrase(String(inner)), range: index..<next))
                index = next
                continue
            }

            let start = index
            while index < text.endIndex, !text[index].isWhitespace, !isQuote(text[index]) {
                index = text.index(after: index)
            }
            let word = text[start..<index]
            guard let (key, value) = operatorParts(word) else {
                tokens.append(Token(kind: .word(String(word)), range: start..<index))
                continue
            }
            if value.isEmpty, index < text.endIndex, isQuote(text[index]) {
                // `key:"quoted value"`
                let (inner, next) = readQuoted(text, from: index)
                tokens.append(Token(kind: .operatorToken(key, value: String(inner)), range: start..<next))
                index = next
            } else {
                tokens.append(Token(kind: .operatorToken(key, value: String(value)), range: start..<index))
            }
        }
        return tokens
    }

    /// Splits `key:value` when `key` is an operator (case-insensitive).
    private static func operatorParts(_ word: Substring) -> (HistoryOperatorToken.Key, Substring)? {
        guard let colon = word.firstIndex(of: ":") else {
            return nil
        }
        guard let key = HistoryOperatorToken.Key(rawValue: word[word.startIndex..<colon].lowercased()) else {
            return nil
        }
        return (key, word[word.index(after: colon)...])
    }

    // MARK: - Values

    private static let agentAliases: [(alias: String, agent: AgentHistoryAgent)] = [
        ("claude", .claude), ("claude-code", .claude), ("claudecode", .claude), ("cc", .claude),
        ("codex", .codex),
        ("grok", .grok),
        ("opencode", .opencode), ("open-code", .opencode),
    ]

    static func agent(forOperatorValue value: String) -> AgentHistoryAgent? {
        let lowered = value.lowercased()
        if let exact = agentAliases.first(where: { $0.alias == lowered }) {
            return exact.agent
        }
        guard lowered.count >= 2 else {
            return nil
        }
        let candidates = Set(agentAliases.filter { $0.alias.hasPrefix(lowered) }.map(\.agent))
        return candidates.count == 1 ? candidates.first : nil
    }

    /// `YYYY-MM-DD` as the local start of that day, or nil when malformed or not a real date.
    static func startOfDay(forOperatorValue value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    // MARK: - State

    private struct ParseState {
        let calendar: Calendar
        var terms: [HistoryQueryTerm] = []
        var seenTerms: Set<String> = []
        var filters = HistoryQueryFilters()
        var operatorTokens: [HistoryOperatorToken] = []

        init(calendar: Calendar) {
            self.calendar = calendar
        }

        mutating func consume(_ token: Token, in text: String) {
            switch token.kind {
            case .word(let word):
                addTerm(word, isPhrase: false)
            case .phrase(let phrase):
                addTerm(phrase, isPhrase: true)
            case .operatorToken(let key, let typed):
                // A quoted value may carry stray spaces; whitespace-only stays pending.
                let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                let isValid = !value.isEmpty && apply(key, value: value)
                operatorTokens.append(HistoryOperatorToken(
                    key: key,
                    rawValue: value,
                    rangeInRaw: token.range,
                    isValid: isValid
                ))
                if !isValid, !value.isEmpty {
                    addTerm(String(text[token.range]), isPhrase: false)
                }
            }
        }

        private mutating func apply(_ key: HistoryOperatorToken.Key, value: String) -> Bool {
            switch key {
            case .agent:
                guard let agent = HistoryQueryParser.agent(forOperatorValue: value) else {
                    return false
                }
                filters.agents.insert(agent)
            case .repo:
                if !filters.repoNames.contains(value) {
                    filters.repoNames.append(value)
                }
            case .branch:
                if !filters.branches.contains(value) {
                    filters.branches.append(value)
                }
            case .before:
                guard let date = HistoryQueryParser.startOfDay(forOperatorValue: value, calendar: calendar) else {
                    return false
                }
                filters.before = min(filters.before ?? date, date)
            case .after:
                guard let date = HistoryQueryParser.startOfDay(forOperatorValue: value, calendar: calendar) else {
                    return false
                }
                filters.after = max(filters.after ?? date, date)
            }
            return true
        }

        private mutating func addTerm(_ text: String, isPhrase: Bool) {
            guard terms.count < HistoryQueryParser.maxTerms else {
                return
            }
            let folded = AgentHistorySearchText.normalize(text)
            guard !folded.isEmpty, seenTerms.insert(folded).inserted else {
                return
            }
            terms.append(HistoryQueryTerm(text: folded, isPhrase: isPhrase))
        }
    }
}
