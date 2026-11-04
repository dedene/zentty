import Foundation
import XCTest
@testable import Zentty

final class HistorySnippetBuilderTests: XCTestCase {
    private func snippet(_ text: String, _ raw: String, maxLength: Int = 150, leadIn: Int = 40) -> HistorySnippet {
        HistorySnippetBuilder.snippet(
            for: text,
            query: HistoryQueryParser.parse(raw),
            maxLength: maxLength,
            leadIn: leadIn
        )
    }

    private func highlighted(_ snippet: HistorySnippet) -> [String] {
        let ns = snippet.text as NSString
        return snippet.highlights.map { ns.substring(with: $0) }
    }

    /// `count` words of filler, e.g. "w000 w001 …", each five characters including the space.
    private func filler(_ count: Int, prefix: String = "w") -> String {
        (0..<count).map { String(format: "%@%03d", prefix, $0) }.joined(separator: " ")
    }

    // MARK: - Window

    func test_window_starts_about_40_before_match_snapped_to_word() {
        let text = filler(40) + " the login crash happened here " + filler(40, prefix: "z")
        let result = snippet(text, "login")

        XCTAssertTrue(result.truncatedStart)
        XCTAssertTrue(result.truncatedEnd)
        XCTAssertTrue(result.text.hasPrefix("…"))
        XCTAssertTrue(result.text.hasSuffix("…"))

        let body = String(result.text.dropFirst().dropLast())
        // Starts on a word boundary: the first word is a whole filler word.
        let firstWord = body.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertTrue(text.split(separator: " ").contains(Substring(firstWord)), "cut mid-word: \(firstWord)")
        XCTAssertFalse(body.hasPrefix(" "))
        XCTAssertFalse(body.hasSuffix(" "))

        // Lead-in of about 40 characters (snapping moves forward at most 15).
        let lead = (body as NSString).range(of: "login").location
        XCTAssertGreaterThanOrEqual(lead, 40 - 15)
        XCTAssertLessThanOrEqual(lead, 40)

        // The end is snapped back to a word boundary too.
        let lastWord = body.split(separator: " ").last.map(String.init) ?? ""
        XCTAssertTrue(text.split(separator: " ").contains(Substring(lastWord)), "cut mid-word: \(lastWord)")
        XCTAssertEqual(highlighted(result), ["login"])
    }

    func test_match_near_start_has_no_leading_ellipsis() {
        let result = snippet("Fix login crash. " + filler(60), "login")
        XCTAssertFalse(result.truncatedStart)
        XCTAssertTrue(result.truncatedEnd)
        XCTAssertTrue(result.text.hasPrefix("Fix login crash."))
        XCTAssertEqual(highlighted(result), ["login"])
    }

    func test_shortest_span_containing_all_terms_chosen() {
        // "alpha" and "omega" first appear far apart; later they sit side by side.
        let text = "alpha " + filler(60) + " omega " + filler(60, prefix: "y") + " alpha omega together " + filler(30, prefix: "z")
        let result = snippet(text, "alpha omega")
        XCTAssertTrue(result.text.contains("alpha omega together"))
        XCTAssertEqual(highlighted(result), ["alpha", "omega"])
    }

    func test_word_level_occurrence_preferred_over_mid_word() {
        // "auth" mid-word in "oauth2" comes first; the whole word "auth" comes much later.
        let text = "oauth2 setup " + filler(60) + " then auth works " + filler(30, prefix: "z")
        let result = snippet(text, "auth")
        XCTAssertTrue(result.text.contains("then auth works"))
        XCTAssertTrue(result.truncatedStart)
    }

    func test_ellipses_on_truncated_sides_only() {
        let short = snippet("A short message about login.", "login")
        XCTAssertEqual(short.text, "A short message about login.")
        XCTAssertFalse(short.truncatedStart)
        XCTAssertFalse(short.truncatedEnd)

        let tail = snippet(filler(60) + " ends with login", "login")
        XCTAssertTrue(tail.truncatedStart)
        XCTAssertFalse(tail.truncatedEnd)
        XCTAssertTrue(tail.text.hasPrefix("…"))
        XCTAssertTrue(tail.text.hasSuffix("ends with login"))

        let head = snippet("login starts " + filler(60), "login")
        XCTAssertFalse(head.truncatedStart)
        XCTAssertTrue(head.truncatedEnd)
        XCTAssertFalse(head.text.hasPrefix("…"))
        XCTAssertTrue(head.text.hasSuffix("…"))
    }

    // MARK: - Cleanup

    func test_markdown_markers_stripped_and_highlights_recomputed() {
        let text = """
        ## Fixing the **login** crash

        > See [the docs](https://example.com/docs) and `AuthStore.swift`.
        - Use *strict* mode
        ```swift
        let login = true
        ```
        """
        let result = snippet(text, "login")
        XCTAssertEqual(
            result.text,
            "Fixing the login crash See the docs and AuthStore.swift. Use strict mode let login = true"
        )
        XCTAssertEqual(highlighted(result), ["login", "login"])
        XCTAssertEqual(result.highlights.first, NSRange(location: 11, length: 5))
    }

    func test_strip_markdown_keeps_code_spans_and_identifiers_literal() {
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("run `ls **/*.swift` now"), "run ls **/*.swift now")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("snake_case and __init__"), "snake_case and __init__")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("2 * 3 and a*b"), "2 * 3 and a*b")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("~~old~~ new"), "old new")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("![logo](a.png) text"), "logo text")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("one\n\n---\ntwo"), "one\n\ntwo")
        XCTAssertEqual(HistorySnippetBuilder.stripMarkdown("* item\n1. first"), "item\n1. first")
    }

    func test_newlines_collapsed() {
        let result = snippet("first line\n\n\nsecond\tline\r\nthird   line about login", "login")
        XCTAssertEqual(result.text, "first line second line third line about login")
        XCTAssertFalse(result.text.contains("\n"))
        XCTAssertEqual(highlighted(result), ["login"])
    }

    // MARK: - Fallbacks and limits

    func test_no_match_falls_back_to_prefix() {
        let text = filler(60)
        let result = snippet(text, "absent")
        XCTAssertFalse(result.truncatedStart)
        XCTAssertTrue(result.truncatedEnd)
        XCTAssertTrue(result.highlights.isEmpty)
        XCTAssertTrue(result.text.hasPrefix("w000 w001"))
        XCTAssertLessThanOrEqual(result.text.count, 150)

        let empty = snippet("Short text.", "")
        XCTAssertEqual(empty.text, "Short text.")
        XCTAssertTrue(empty.highlights.isEmpty)
        XCTAssertFalse(empty.truncatedEnd)

        XCTAssertEqual(snippet("", "login").text, "")
    }

    func test_max_length_respected_with_multibyte_text() {
        let unit = "café 🎉 日本語 résumé 👩‍👩‍👧 "
        let text = String(repeating: unit, count: 20) + "needle here " + String(repeating: unit, count: 20)
        for maxLength in [20, 60, 150] {
            let result = snippet(text, "needle", maxLength: maxLength)
            XCTAssertLessThanOrEqual(result.text.count, maxLength, "maxLength \(maxLength)")
            XCTAssertEqual(highlighted(result), ["needle"], "maxLength \(maxLength)")
            for range in result.highlights {
                XCTAssertLessThanOrEqual(NSMaxRange(range), (result.text as NSString).length)
            }
        }
        let prefix = snippet(text, "absent", maxLength: 30)
        XCTAssertLessThanOrEqual(prefix.text.count, 30)
        XCTAssertTrue(prefix.truncatedEnd)
    }

    func test_long_span_keeps_match_start_visible() {
        let text = filler(30) + " alpha " + filler(40, prefix: "m") + " omega " + filler(30, prefix: "z")
        let result = snippet(text, "alpha omega", maxLength: 60)
        XCTAssertLessThanOrEqual(result.text.count, 60)
        XCTAssertTrue(result.text.contains("alpha"))
    }

    // MARK: - Cleanup fast paths

    /// The character-by-character rule the slice-copying `collapseWhitespace` must match.
    private static func referenceCollapse(_ text: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace {
                    output.append(" ")
                    pendingSpace = false
                }
                output.append(character)
            }
        }
        return output
    }

    func test_collapse_whitespace_matches_the_per_character_rule() {
        let samples = [
            "", "   ", "a", "  lead and trail  ", "tabs\tand\nnew\r\nlines\u{0B}\u{0C}end",
            "no\u{00A0}break\u{2028}line\u{2029}para\u{3000}ideo\u{0085}next",
            "space then mark \u{0301}x", "\u{0301}leading mark", "e\u{0301}  te\u{0301}",
            "emoji 👩‍💻  family 👨‍👩‍👧 \t flags 🇧🇪", "漢字  かな\nカナ", "\r\n\r\nCRLF only\r\n",
            "\u{1C}\u{1D}\u{1E}\u{1F} separators are not whitespace",
        ]
        for sample in samples {
            XCTAssertEqual(
                HistorySnippetBuilder.collapseWhitespace(sample).unicodeScalars.map(\.value),
                Self.referenceCollapse(sample).unicodeScalars.map(\.value), sample.debugDescription)
        }
    }

    func test_strip_markdown_keeps_lines_without_inline_markers_verbatim() {
        let text = "plain line with é and 漢字\n  indented [link](x) and `code`\nA ~~gone~~ **bold** line"
        XCTAssertEqual(
            HistorySnippetBuilder.stripMarkdown(text),
            "plain line with é and 漢字\nindented link and code\nA gone bold line")
    }
}
