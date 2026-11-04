import Foundation
import XCTest
@testable import Zentty

final class HistoryMatchPlanTests: XCTestCase {
    private func plan(_ raw: String, _ tokenizer: AgentHistoryTokenizer) -> HistoryMatchPlan {
        HistoryMatchPlan.make(query: HistoryQueryParser.parse(raw), tokenizer: tokenizer)
    }

    func test_trigram_quotes_terms_and_ands_them() {
        let plan = plan("Login \"auth flow\" crash", .trigram)

        XCTAssertEqual(plan.mode, .fts)
        XCTAssertEqual(plan.matchExpression, "\"login\" \"auth flow\" \"crash\"")
        XCTAssertEqual(plan.ftsTerms, ["login", "auth flow", "crash"])
        XCTAssertEqual(plan.instrFilters, [])
    }

    func test_unicode61_uses_prefix_phrases() {
        let plan = plan("login \"auth flow\"", .unicode61)

        XCTAssertEqual(plan.mode, .fts)
        XCTAssertEqual(plan.matchExpression, "\"login\"* \"auth flow\"*")
        XCTAssertEqual(plan.instrFilters, [])
    }

    func test_escapes_embedded_double_quote() {
        let terms = [HistoryQueryTerm(text: "say \"hi\" now", isPhrase: true)]

        let trigram = HistoryMatchPlan.make(terms: terms, tokenizer: .trigram)
        XCTAssertEqual(trigram.matchExpression, "\"say \"\"hi\"\" now\"")

        let unicode = HistoryMatchPlan.make(terms: terms, tokenizer: .unicode61)
        XCTAssertEqual(unicode.matchExpression, "\"say \"\"hi\"\" now\"*")
    }

    func test_short_terms_become_instr_filters() {
        let plan = plan("crash ui db ok go js", .trigram)

        XCTAssertEqual(plan.mode, .fts)
        XCTAssertEqual(plan.matchExpression, "\"crash\"")
        XCTAssertEqual(plan.instrFilters, ["ui", "db", "ok", "go"])
        XCTAssertEqual(HistoryMatchPlan.maxInstrFilters, 4)
    }

    func test_all_short_terms_is_metadata_only() {
        for tokenizer: AgentHistoryTokenizer in [.trigram, .unicode61, .none] {
            let plan = plan("ui db", tokenizer)
            XCTAssertEqual(plan.mode, .metadataOnly, "\(tokenizer)")
            XCTAssertNil(plan.matchExpression, "\(tokenizer)")
        }
        XCTAssertEqual(plan("", .trigram).mode, .metadataOnly)
        XCTAssertEqual(plan("agent:codex repo:zentty", .trigram).mode, .metadataOnly)
        XCTAssertEqual(plan("!!", .trigram).mode, .metadataOnly)
    }

    func test_two_char_cjk_is_fts_in_unicode61_and_scan_in_trigram() {
        let unicode = plan("中文", .unicode61)
        XCTAssertEqual(unicode.mode, .fts)
        XCTAssertEqual(unicode.matchExpression, "\"中文\"*")
        XCTAssertEqual(unicode.instrFilters, [])

        let trigram = plan("中文", .trigram)
        XCTAssertEqual(trigram.mode, .scan)
        XCTAssertNil(trigram.matchExpression)
        XCTAssertEqual(trigram.instrFilters, ["中文"])

        // A 2-char CJK term next to an FTS-eligible term rides along as an instr filter.
        let mixed = plan("中文 crash", .trigram)
        XCTAssertEqual(mixed.mode, .fts)
        XCTAssertEqual(mixed.matchExpression, "\"crash\"")
        XCTAssertEqual(mixed.instrFilters, ["中文"])

        // Three CJK characters are long enough for trigram.
        XCTAssertEqual(plan("日本語", .trigram).matchExpression, "\"日本語\"")
    }

    func test_punctuation_only_term_goes_to_instr() {
        let mixed = plan("crash ->>", .trigram)
        XCTAssertEqual(mixed.mode, .fts)
        XCTAssertEqual(mixed.matchExpression, "\"crash\"")
        XCTAssertEqual(mixed.instrFilters, ["->>"])

        let unicode = plan("crash ->>", .unicode61)
        XCTAssertEqual(unicode.matchExpression, "\"crash\"*")
        XCTAssertEqual(unicode.instrFilters, ["->>"])

        // Nothing for FTS, but a term of three characters is still worth scanning for.
        let alone = plan("->>", .trigram)
        XCTAssertEqual(alone.mode, .scan)
        XCTAssertNil(alone.matchExpression)
        XCTAssertEqual(alone.instrFilters, ["->>"])
    }

    func test_no_fts_tokenizer_uses_scan_mode() {
        let scan = plan("crash ui \"auth flow\"", .none)
        XCTAssertEqual(scan.mode, .scan)
        XCTAssertNil(scan.matchExpression)
        XCTAssertEqual(scan.ftsTerms, [])
        XCTAssertEqual(scan.instrFilters, ["crash", "ui", "auth flow"])

        // Scan mode keeps every term: the instr filters are the only content match.
        let many = plan("alpha b c d e f", .none)
        XCTAssertEqual(many.mode, .scan)
        XCTAssertEqual(many.instrFilters, ["alpha", "b", "c", "d", "e", "f"])
    }
}
