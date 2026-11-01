import Foundation

/// How the content tier looks for a query's terms, given the index's FTS tokenizer.
///
/// Rules:
/// - A term is FTS-eligible when it has at least three scalars (or, under `unicode61`, is CJK
///   with at least two) and contains a word character. Eligible terms are AND-ed in one MATCH
///   expression: trigram `"t1" "t2"`, unicode61 `"t1"* "t2"*`, with embedded `"` doubled.
/// - The other terms become `instr` filters on the candidates, at most `maxInstrFilters`.
///   The grader still requires every term afterwards; the filters only narrow the scan.
/// - No eligible term: `.scan` (newest messages, every term as an `instr` filter) when some
///   term is still worth a substring search (three or more scalars, or two-scalar CJK under
///   trigram), else `.metadataOnly`.
/// - Tokenizer `.none` (no FTS5): `.scan` under the same "worth a substring search" test, else
///   `.metadataOnly`.
struct HistoryMatchPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Run `matchExpression` against the FTS tables, plus the `instr` filters.
        case fts
        /// Scan the newest messages with `instr` filters only (no usable FTS for these terms).
        case scan
        /// Nothing for the content tier; the metadata tier answers alone.
        case metadataOnly
    }

    static let maxInstrFilters = 4

    let mode: Mode
    /// The FTS5 MATCH argument; set only in `.fts` mode.
    let matchExpression: String?
    /// Folded term texts inside `matchExpression`, in query order.
    let ftsTerms: [String]
    /// Folded term texts for `instr(search_text, ?) > 0`, in query order.
    let instrFilters: [String]

    static func make(query: HistoryQuery, tokenizer: AgentHistoryTokenizer) -> HistoryMatchPlan {
        make(terms: query.terms, tokenizer: tokenizer)
    }

    static func make(terms: [HistoryQueryTerm], tokenizer: AgentHistoryTokenizer) -> HistoryMatchPlan {
        if tokenizer != .none {
            let eligible = terms.filter { isFTSEligible($0, tokenizer: tokenizer) }
            if !eligible.isEmpty {
                let rest = terms.filter { !isFTSEligible($0, tokenizer: tokenizer) }
                return HistoryMatchPlan(
                    mode: .fts,
                    matchExpression: matchExpression(for: eligible, tokenizer: tokenizer),
                    ftsTerms: eligible.map(\.text),
                    instrFilters: Array(rest.prefix(maxInstrFilters).map(\.text))
                )
            }
        }

        if terms.contains(where: isWorthScanning) {
            return HistoryMatchPlan(
                mode: .scan,
                matchExpression: nil,
                ftsTerms: [],
                instrFilters: terms.map(\.text)
            )
        }
        return HistoryMatchPlan(mode: .metadataOnly, matchExpression: nil, ftsTerms: [], instrFilters: [])
    }

    // MARK: - Rules

    private static func isFTSEligible(_ term: HistoryQueryTerm, tokenizer: AgentHistoryTokenizer) -> Bool {
        let longEnough: Bool
        switch tokenizer {
        case .trigram:
            longEnough = term.scalarCount >= 3
        case .unicode61:
            longEnough = term.scalarCount >= 3 || (term.isCJK && term.scalarCount >= 2)
        case .none:
            return false
        }
        return longEnough && AgentHistorySearchText.containsWordCharacter(term.text)
    }

    /// A term a substring scan can still use when FTS cannot: three or more scalars, or a CJK
    /// term of two (CJK is written without spaces, so two characters already name a word).
    private static func isWorthScanning(_ term: HistoryQueryTerm) -> Bool {
        term.scalarCount >= 3 || (term.isCJK && term.scalarCount >= 2)
    }

    private static func matchExpression(for terms: [HistoryQueryTerm], tokenizer: AgentHistoryTokenizer) -> String {
        let suffix = tokenizer == .unicode61 ? "*" : ""
        return terms
            .map { "\"" + $0.text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + suffix }
            .joined(separator: " ")
    }
}
