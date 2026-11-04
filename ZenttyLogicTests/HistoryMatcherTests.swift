import Foundation
import XCTest
@testable import Zentty

final class HistoryMatcherTests: XCTestCase {
    private func grade(
        _ text: String,
        _ raw: String,
        mode: HistoryMatcher.BoundaryMode = .text
    ) -> HistoryGrade? {
        HistoryMatcher.grade(
            normalized: AgentHistorySearchText.normalize(text),
            query: HistoryQueryParser.parse(raw),
            mode: mode
        )
    }

    private func termClass(
        _ text: String,
        _ term: String,
        mode: HistoryMatcher.BoundaryMode = .text
    ) -> HistoryMatchClass {
        let normalized = AgentHistorySearchText.normalize(text)
        let query = HistoryQueryParser.parse(term)
        let utf8 = Array(normalized.utf8)
        let grade = utf8.withUnsafeBufferPointer {
            HistoryMatcher.grade(normalizedUTF8: $0, query: query, mode: mode, collectOccurrences: true)
        }
        return grade?.occurrences.map(\.matchClass).max() ?? .none
    }

    private func assertQuality(
        _ value: Double?,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let value else {
            XCTFail("expected a grade of \(expected), got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - Term classes

    func test_whole_word_scores_1() {
        assertQuality(grade("Fix the login crash", "login")?.quality, 1.0)
        assertQuality(grade("login", "login")?.quality, 1.0)
        assertQuality(grade("(login)", "login")?.quality, 1.0)
        assertQuality(grade("agent_history_store", "history")?.quality, 1.0)
        XCTAssertEqual(termClass("Fix the login crash", "login"), .word)
        XCTAssertEqual(HistoryMatchClass.word.credit, 1.0)
        XCTAssertTrue(grade("Fix the login crash", "login")?.isWordLevel ?? false)
    }

    func test_word_prefix_scores_0_8() {
        assertQuality(grade("the authentication flow", "auth")?.quality, 0.8)
        XCTAssertEqual(termClass("the authentication flow", "auth"), .prefix)
        XCTAssertTrue(grade("the authentication flow", "auth")?.isWordLevel ?? false)
        // Best occurrence wins: a later whole word beats an earlier prefix.
        assertQuality(grade("authentication uses auth tokens", "auth")?.quality, 1.0)
    }

    func test_mid_word_scores_0_3_only_for_4_plus_chars() {
        assertQuality(grade("reauthenticate the session", "then")?.quality, 0.3)
        XCTAssertEqual(termClass("reauthenticate the session", "then"), .midWord)
        XCTAssertFalse(grade("reauthenticate the session", "then")?.isWordLevel ?? true)
        // Three characters mid-word earn nothing, so the candidate fails.
        XCTAssertNil(grade("reauthenticate the session", "uth"))
        // A word suffix is still mid-word.
        assertQuality(grade("enable oauth", "auth")?.quality, 0.3)
    }

    func test_mid_word_inside_hex_hash_gets_no_credit() {
        XCTAssertNil(grade("reverted 3f2a9c1e4b7d by hand", "9c1e"))
        XCTAssertNil(grade("see commit:deadbeefcafe for details", "beef"))
        // A non-hex word next to a hex segment keeps its mid-word credit.
        assertQuality(grade("build-deadbeef1-handler", "andl")?.quality, 0.3)
        // Short hex-looking words are not hashes.
        assertQuality(grade("the facade pattern", "acad")?.quality, 0.3)
    }

    func test_mid_word_inside_uuid_gets_no_credit() {
        let text = "session 0b3e5f6a-1c2d-4e5f-8a9b-0c1d2e3f4a5b resumed"
        XCTAssertNil(grade(text, "3e5f"))
        XCTAssertNil(grade(text, "e5f-8a"))
        XCTAssertNil(grade(text, "e5f-8a9b"))
        XCTAssertNil(grade(text, "d2e3f"))
    }

    func test_prefix_inside_hex_still_counts() {
        assertQuality(grade("reverted 3f2a9c1e4b7d by hand", "3f2a")?.quality, 0.8)
        assertQuality(grade("reverted 3f2a9c1e4b7d by hand", "3f2a9c1e4b7d")?.quality, 1.0)
        let uuid = "session 0b3e5f6a-1c2d-4e5f-8a9b-0c1d2e3f4a5b resumed"
        assertQuality(grade(uuid, "0b3e")?.quality, 0.8)
        // A whole UUID group sits between `-` boundaries, so it is a word.
        assertQuality(grade(uuid, "4e5f")?.quality, 1.0)
    }

    func test_missing_term_fails_candidate() {
        XCTAssertNil(grade("Fix the login crash", "login logout"))
        XCTAssertNil(grade("Fix the login crash", "signup"))
        XCTAssertNil(grade("", "login"))
        XCTAssertNil(grade("Fix the login crash", ""))
    }

    func test_mean_quality_and_word_level_gate() {
        // login 1.0 + prefix 0.8 → mean 0.9, word level.
        let wordLevel = grade("login with authentication is broken", "login authentic")
        assertQuality(wordLevel?.baseQuality, 0.9)
        XCTAssertTrue(wordLevel?.isWordLevel ?? false)

        // login 1.0 + mid-word 0.3 → mean 0.65, not word level; terms are close, so +0.1.
        let midWord = grade("the login flow for the reauthentication module", "login thentic")
        assertQuality(midWord?.baseQuality, 0.65)
        assertQuality(midWord?.quality, 0.75)
        XCTAssertFalse(midWord?.isWordLevel ?? true)

        // Three prefixes average to exactly the gate.
        let prefixes = grade("authentication configuration deployment", "auth config deploy")
        assertQuality(prefixes?.baseQuality, 0.8)
        XCTAssertTrue(prefixes?.isWordLevel ?? false)
    }

    // MARK: - Bonuses

    func test_typed_phrase_bonus_0_25() {
        let phrase = grade("we fixed the auth flow today", "auth flow")
        assertQuality(phrase?.baseQuality, 1.0)
        assertQuality(phrase?.quality, 1.25)

        // Same terms, not in typed order: proximity bonus only.
        let reversed = grade("the flow of auth today", "auth flow")
        assertQuality(reversed?.quality, 1.1)

        // A single term gets no phrase or proximity bonus.
        assertQuality(grade("we fixed the auth flow today", "auth")?.quality, 1.0)
    }

    func test_proximity_bonus_within_60() {
        let filler = String(repeating: "x", count: 50)
        // The covering window from "login" through "crash" is exactly 60 bytes.
        let text = "login " + String(repeating: "y", count: 48) + " crash"
        XCTAssertEqual(text.utf8.count, 60)
        assertQuality(grade(text, "login crash")?.quality, 1.1)
        // The minimal window is used, not the first occurrences.
        let far = "crash " + filler + " " + filler + " login then crash again"
        assertQuality(grade(far, "login crash")?.quality, 1.1)
    }

    func test_no_bonus_beyond_60() {
        let text = "login " + String(repeating: "y", count: 49) + " crash"
        XCTAssertEqual(text.utf8.count, 61)
        let grade = grade(text, "login crash")
        assertQuality(grade?.baseQuality, 1.0)
        assertQuality(grade?.quality, 1.0)
    }

    // MARK: - Boundaries

    func test_path_mode_segment_boundaries() {
        let path = "/Users/peter/src/zentty/AgentHistory/agent-history_store.swift"
        XCTAssertEqual(termClass(path, "zentty", mode: .path), .word)
        XCTAssertEqual(termClass(path, "history", mode: .path), .word)
        XCTAssertEqual(termClass(path, "store", mode: .path), .word)
        XCTAssertEqual(termClass(path, "swift", mode: .path), .word)
        XCTAssertEqual(termClass(path, "agenthis", mode: .path), .prefix)
        XCTAssertEqual(termClass(path, "src/zentty", mode: .path), .word)
        XCTAssertEqual(termClass(path, "entty", mode: .path), .midWord)
        // Text mode agrees: every path delimiter is a non-word character.
        XCTAssertEqual(termClass(path, "store"), .word)
    }

    func test_cjk_scalars_are_boundaries() {
        assertQuality(grade("我在修复login问题", "login")?.quality, 1.0)
        assertQuality(grade("我在修复问题", "修复")?.quality, 1.0)
        assertQuality(grade("ログイン画面のバグ", "画面")?.quality, 1.0)
        // A Latin letter next to the term is still a word character.
        assertQuality(grade("我在修复xlogin问题", "login")?.quality, 0.3)
        // Non-ASCII letters are word characters too.
        assertQuality(grade("übersicht", "bersicht")?.quality, 0.3)
    }

    // MARK: - Highlights

    func test_highlight_ranges_map_to_display_text_with_diacritics_and_emoji() {
        let display = "Café 🎉 Résumé fix"
        let ranges = HistoryMatcher.highlightRanges(in: display, query: HistoryQueryParser.parse("resume cafe"))
        let ns = display as NSString
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["Café", "Résumé"])
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 4), NSRange(location: 8, length: 6)])

        // Decomposed input maps back to whole graphemes.
        let decomposed = "🙂 Re\u{301}sume\u{301}!"
        let nfd = HistoryMatcher.highlightRanges(in: decomposed, query: HistoryQueryParser.parse("résumé"))
        XCTAssertEqual(nfd.map { (decomposed as NSString).substring(with: $0) }, ["Re\u{301}sume\u{301}"])

        // Fullwidth input.
        let fullwidth = "ｌｏｇｉｎ ok"
        let wide = HistoryMatcher.highlightRanges(in: fullwidth, query: HistoryQueryParser.parse("login"))
        XCTAssertEqual(wide, [NSRange(location: 0, length: 5)])
    }

    func test_highlight_ranges_coalesced_and_sorted() {
        let display = "crash in login: login crash, auth crashes"
        let ranges = HistoryMatcher.highlightRanges(in: display, query: HistoryQueryParser.parse("crash login \"login cr\""))
        let ns = display as NSString
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["crash", "login", "login crash", "crash"])
        XCTAssertEqual(ranges, ranges.sorted { $0.location < $1.location })
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThan(NSMaxRange(a), b.location, "ranges must not touch or overlap")
        }

        // Partial matches still highlight; uncredited occurrences do not.
        let partial = HistoryMatcher.highlightRanges(in: "oauth login", query: HistoryQueryParser.parse("login missing uth"))
        XCTAssertEqual(partial, [NSRange(location: 6, length: 5)])
        XCTAssertEqual(HistoryMatcher.highlightRanges(in: "", query: HistoryQueryParser.parse("login")), [])
    }

    func test_collect_occurrences_reports_credited_byte_ranges_sorted() {
        let normalized = "auth then oauth and auth"
        let utf8 = Array(normalized.utf8)
        let grade = utf8.withUnsafeBufferPointer {
            HistoryMatcher.grade(
                normalizedUTF8: $0,
                query: HistoryQueryParser.parse("auth then"),
                collectOccurrences: true
            )
        }
        XCTAssertEqual(grade?.occurrences.map(\.bytes), [0..<4, 5..<9, 11..<15, 20..<24])
        XCTAssertEqual(grade?.occurrences.map(\.termIndex), [0, 1, 0, 0])
        XCTAssertEqual(grade?.occurrences.map(\.matchClass), [.word, .word, .midWord, .word])

        let quiet = utf8.withUnsafeBufferPointer {
            HistoryMatcher.grade(normalizedUTF8: $0, query: HistoryQueryParser.parse("auth"))
        }
        XCTAssertEqual(quiet?.occurrences.count, 0)
    }
}
