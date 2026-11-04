import Foundation
import XCTest
@testable import Zentty

final class HistoryQueryParserTests: XCTestCase {
    private var brussels: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }

    private func parse(_ raw: String) -> HistoryQuery {
        HistoryQueryParser.parse(raw, calendar: brussels)
    }

    private func termTexts(_ query: HistoryQuery) -> [String] {
        query.terms.map(\.text)
    }

    func test_splits_terms_and_keeps_quoted_phrase() {
        let query = parse("Fix \"Login Flow\"  crash")

        XCTAssertEqual(termTexts(query), ["fix", "login flow", "crash"])
        XCTAssertEqual(query.terms.map(\.isPhrase), [false, true, false])
        XCTAssertTrue(query.filters.isEmpty)
        XCTAssertTrue(query.operatorTokens.isEmpty)
        XCTAssertEqual(query.phraseText, "fix login flow crash")
        XCTAssertFalse(query.isEmpty)

        let phrase = query.terms[1]
        XCTAssertEqual(phrase.utf8, Array("login flow".utf8))
        XCTAssertEqual(phrase.scalarCount, 10)
        XCTAssertFalse(phrase.isCJK)
    }

    func test_single_term_has_no_phrase_text_and_empty_query_is_empty() {
        XCTAssertNil(parse("crash").phraseText)
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("   \t ").isEmpty)
        XCTAssertTrue(parse("\"\"").isEmpty)
    }

    func test_smart_quotes_form_a_phrase() {
        let curly = parse("\u{201C}Café Crème\u{201D} bug")
        XCTAssertEqual(termTexts(curly), ["cafe creme", "bug"])
        XCTAssertEqual(curly.terms.map(\.isPhrase), [true, false])

        let lowHigh = parse("\u{201E}merge conflict\u{201C}")
        XCTAssertEqual(termTexts(lowHigh), ["merge conflict"])
        XCTAssertTrue(lowHigh.terms[0].isPhrase)

        let guillemets = parse("«build cache»")
        XCTAssertEqual(termTexts(guillemets), ["build cache"])
        XCTAssertTrue(guillemets.terms[0].isPhrase)

        // A straight opening quote pairs with a curly closing one.
        let mixed = parse("\"Token refresh\u{201D} later")
        XCTAssertEqual(termTexts(mixed), ["token refresh", "later"])
    }

    func test_unterminated_quote_runs_to_end() {
        let query = parse("deploy \"staging   server  ")
        XCTAssertEqual(termTexts(query), ["deploy", "staging server"])
        XCTAssertEqual(query.terms.map(\.isPhrase), [false, true])
    }

    func test_agent_operator_aliases_and_prefix() {
        let cases: [(String, AgentHistoryAgent)] = [
            ("claude", .claude), ("claude-code", .claude), ("claudecode", .claude), ("cc", .claude),
            ("cl", .claude), ("claude-c", .claude),
            ("codex", .codex), ("co", .codex), ("cod", .codex),
            ("grok", .grok), ("gr", .grok),
            ("opencode", .opencode), ("open-code", .opencode), ("op", .opencode), ("open-", .opencode),
        ]
        for (value, agent) in cases {
            let query = parse("agent:\(value) crash")
            XCTAssertEqual(query.filters.agents, [agent], "agent:\(value)")
            XCTAssertEqual(termTexts(query), ["crash"], "agent:\(value)")
            XCTAssertEqual(query.operatorTokens.count, 1)
            XCTAssertEqual(query.operatorTokens.first?.key, .agent)
            XCTAssertEqual(query.operatorTokens.first?.rawValue, value)
            XCTAssertEqual(query.operatorTokens.first?.isValid, true)
        }

        let union = parse("agent:claude agent:grok")
        XCTAssertEqual(union.filters.agents, [.claude, .grok])
        XCTAssertTrue(union.terms.isEmpty)
        XCTAssertFalse(union.isEmpty)
    }

    func test_unknown_agent_value_becomes_plain_term() {
        // "c" is shorter than the 2-character prefix minimum; "zed" names no agent.
        for value in ["zed", "c", "cx"] {
            let query = parse("agent:\(value) crash")
            XCTAssertTrue(query.filters.agents.isEmpty, "agent:\(value)")
            XCTAssertEqual(termTexts(query), ["agent:\(value)", "crash"], "agent:\(value)")
            XCTAssertEqual(query.operatorTokens.count, 1)
            XCTAssertEqual(query.operatorTokens.first?.isValid, false)
        }
    }

    func test_repo_and_branch_operators_multiple_values_or() {
        let query = parse("repo:zentty repo:Nimbu branch:feat/history branch:main repo:zentty fix")

        XCTAssertEqual(query.filters.repoNames, ["zentty", "Nimbu"])
        XCTAssertEqual(query.filters.branches, ["feat/history", "main"])
        XCTAssertEqual(termTexts(query), ["fix"])
        XCTAssertEqual(query.operatorTokens.map(\.key), [.repo, .repo, .branch, .branch, .repo])
        XCTAssertTrue(query.operatorTokens.allSatisfy(\.isValid))
    }

    func test_quoted_operator_value() {
        let raw = "repo:\"my project\" branch:\u{201C}fix login\u{201D} crash"
        let query = parse(raw)

        XCTAssertEqual(query.filters.repoNames, ["my project"])
        XCTAssertEqual(query.filters.branches, ["fix login"])
        XCTAssertEqual(termTexts(query), ["crash"])
        XCTAssertEqual(query.operatorTokens.map(\.rawValue), ["my project", "fix login"])
        XCTAssertEqual(String(query.raw[query.operatorTokens[0].rangeInRaw]), "repo:\"my project\"")
        XCTAssertEqual(String(query.raw[query.operatorTokens[1].rangeInRaw]), "branch:\u{201C}fix login\u{201D}")

        let unterminated = parse("deploy repo:\"my project")
        XCTAssertEqual(unterminated.filters.repoNames, ["my project"])
        XCTAssertEqual(termTexts(unterminated), ["deploy"])
    }

    func test_before_after_parse_local_start_of_day() throws {
        let query = parse("before:2026-03-29 after:2026-01-15 deploy")

        let before = try XCTUnwrap(query.filters.before)
        let after = try XCTUnwrap(query.filters.after)
        XCTAssertEqual(before, brussels.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        XCTAssertEqual(after, brussels.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        XCTAssertEqual(brussels.startOfDay(for: before), before)
        XCTAssertEqual(brussels.startOfDay(for: after), after)
        // 2026-01-15 00:00 in Brussels (UTC+1) is 2026-01-14 23:00 UTC.
        XCTAssertEqual(after.timeIntervalSince1970, 1_768_431_600)
        XCTAssertEqual(termTexts(query), ["deploy"])

        let utc = HistoryQueryParser.parse("after:2026-01-15", calendar: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }())
        XCTAssertEqual(utc.filters.after?.timeIntervalSince1970, 1_768_435_200)

        // Repeated bounds keep the tightest window.
        let tight = parse("before:2026-05-01 before:2026-04-01 after:2026-01-01 after:2026-02-01")
        XCTAssertEqual(tight.filters.before, brussels.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        XCTAssertEqual(tight.filters.after, brussels.date(from: DateComponents(year: 2026, month: 2, day: 1)))
    }

    func test_invalid_date_becomes_term() {
        for value in ["2026-02-30", "2026-13-01", "2026-1-5", "yesterday", "2026-01-15x", "20260115"] {
            let query = parse("before:\(value)")
            XCTAssertNil(query.filters.before, "before:\(value)")
            XCTAssertEqual(termTexts(query), [AgentHistorySearchText.normalize("before:\(value)")], "before:\(value)")
            XCTAssertEqual(query.operatorTokens.first?.isValid, false)
        }
        let leap = parse("after:2028-02-29")
        XCTAssertNotNil(leap.filters.after)
        XCTAssertTrue(leap.terms.isEmpty)
    }

    func test_empty_operator_value_is_pending_not_term() {
        let query = parse("crash agent: repo:\"\"")

        XCTAssertEqual(termTexts(query), ["crash"])
        XCTAssertTrue(query.filters.isEmpty)
        XCTAssertEqual(query.operatorTokens.map(\.key), [.agent, .repo])
        XCTAssertTrue(query.operatorTokens.allSatisfy(\.isPending))
        XCTAssertTrue(query.operatorTokens.allSatisfy { !$0.isValid })
        XCTAssertEqual(String(query.raw[query.operatorTokens[0].rangeInRaw]), "agent:")

        XCTAssertTrue(parse("branch:").isEmpty)
    }

    func test_operator_key_case_insensitive() {
        let query = parse("AGENT:Codex Repo:Zentty BRANCH:Main Before:2026-01-02 aFtEr:2026-01-01")

        XCTAssertEqual(query.filters.agents, [.codex])
        XCTAssertEqual(query.filters.repoNames, ["Zentty"])
        XCTAssertEqual(query.filters.branches, ["Main"])
        XCTAssertNotNil(query.filters.before)
        XCTAssertNotNil(query.filters.after)
        XCTAssertTrue(query.terms.isEmpty)
        XCTAssertEqual(query.operatorTokens.map(\.key), [.agent, .repo, .branch, .before, .after])

        // A non-operator key with a colon stays a plain term.
        XCTAssertEqual(termTexts(parse("https://example.com")), ["https://example.com"])
    }

    func test_truncates_to_200_characters() {
        let long = String(repeating: "é", count: 150) + " " + String(repeating: "b", count: 100)
        let query = parse(long)

        XCTAssertEqual(query.raw.count, HistoryQueryParser.maxQueryLength)
        XCTAssertEqual(termTexts(query), [String(repeating: "e", count: 150), String(repeating: "b", count: 49)])

        // An operator cut by the limit is parsed from what remains.
        let cut = parse(String(repeating: "x", count: 190) + " agent:codex")
        XCTAssertEqual(cut.raw.count, 200)
        XCTAssertEqual(cut.operatorTokens.first?.rawValue, "cod")
        XCTAssertEqual(cut.filters.agents, [.codex])
    }

    func test_caps_terms_at_8_and_dedupes() {
        let query = parse("one Two two TWO three four five six seven eight nine ten")

        XCTAssertEqual(query.terms.count, HistoryQueryParser.maxTerms)
        XCTAssertEqual(termTexts(query), ["one", "two", "three", "four", "five", "six", "seven", "eight"])

        let accents = parse("café cafe CAFÉ")
        XCTAssertEqual(termTexts(accents), ["cafe"])
    }

    func test_cjk_terms_are_marked() {
        let query = parse("東京 データ abc 한국")
        XCTAssertEqual(query.terms.map(\.isCJK), [true, true, false, true])
        XCTAssertEqual(query.terms.map(\.scalarCount), [2, 3, 3, 2])
    }

    func test_content_key_ignores_whitespace_differences() {
        let compact = parse("fix login agent:codex")
        let spaced = parse("  fix\t\tlogin   agent:codex  ")
        let reordered = parse("agent:codex fix login")

        XCTAssertNotEqual(compact.raw, spaced.raw)
        XCTAssertEqual(compact.contentKey, spaced.contentKey)
        XCTAssertEqual(compact.contentKey, reordered.contentKey)
        XCTAssertEqual(compact.contentKey, parse("FIX Login agent:cod").contentKey)
        XCTAssertNotEqual(compact.contentKey, parse("fix login").contentKey)
        XCTAssertNotEqual(compact.contentKey, parse("fix logins agent:codex").contentKey)
    }

    func test_extra_agents_intersect_with_agent_operator() {
        let onlyExtra = HistoryQueryParser.parse("crash", extraAgents: [.codex], calendar: brussels)
        XCTAssertEqual(onlyExtra.filters.agents, [.codex])
        XCTAssertFalse(onlyExtra.filters.excludesAllAgents)
        XCTAssertTrue(onlyExtra.filters.admits(agent: .codex))
        XCTAssertFalse(onlyExtra.filters.admits(agent: .claude))

        let overlap = HistoryQueryParser.parse("agent:claude agent:codex crash", extraAgents: [.codex, .grok], calendar: brussels)
        XCTAssertEqual(overlap.filters.agents, [.codex])

        let disjoint = HistoryQueryParser.parse("agent:claude crash", extraAgents: [.codex], calendar: brussels)
        XCTAssertTrue(disjoint.filters.agents.isEmpty)
        XCTAssertTrue(disjoint.filters.excludesAllAgents)
        XCTAssertFalse(disjoint.filters.isEmpty)
        for agent in AgentHistoryAgent.allCases {
            XCTAssertFalse(disjoint.filters.admits(agent: agent))
        }

        let noExtra = HistoryQueryParser.parse("agent:claude", extraAgents: [], calendar: brussels)
        XCTAssertEqual(noExtra.filters.agents, [.claude])

        let unfiltered = parse("crash")
        for agent in AgentHistoryAgent.allCases {
            XCTAssertTrue(unfiltered.filters.admits(agent: agent))
        }
    }
}
