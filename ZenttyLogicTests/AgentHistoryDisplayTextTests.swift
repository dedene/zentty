import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryDisplayTextTests: XCTestCase {
    func test_ansi_crlf_controls_blank_lines() {
        XCTAssertEqual(
            AgentHistoryDisplayText.displayText("\u{1B}[1;31mError\u{1B}[0m: build failed"),
            "Error: build failed"
        )
        // OSC 8 hyperlink (BEL and ST terminated) and a charset designator.
        XCTAssertEqual(
            AgentHistoryDisplayText.displayText(
                "\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\ and \u{1B}(Btext"
            ),
            "link and text"
        )
        XCTAssertEqual(AgentHistoryDisplayText.displayText("one\r\ntwo\rthree\nfour"), "one\ntwo\nthree\nfour")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("a\u{00}b\u{07}c\u{08}d\u{7F}e\u{85}f\tg"), "abcdef\tg")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("a\n\n\n\n\n\nb"), "a\n\n\nb")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("a\n  \n\t\n \n \nb"), "a\n\n\nb")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("a\n\nb"), "a\n\nb")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("a\n\n\nb"), "a\n\n\nb")
        XCTAssertEqual(AgentHistoryDisplayText.displayText("  \n\n  indented\n  kept\n\n  "), "indented\n  kept")
        XCTAssertNil(AgentHistoryDisplayText.displayText(""))
        XCTAssertNil(AgentHistoryDisplayText.displayText(" \n\t\r\n "))
        XCTAssertNil(AgentHistoryDisplayText.displayText("\u{1B}[0m\u{1B}[2K"))
        XCTAssertEqual(AgentHistoryDisplayText.displayText("日本語 ✓ café"), "日本語 ✓ café")
    }

    func test_cap_at_grapheme_with_ellipsis() {
        let max = AgentHistoryDisplayText.maxStoredCharacters
        let exact = String(repeating: "a", count: max)
        XCTAssertEqual(AgentHistoryDisplayText.displayText(exact), exact)

        let family = "👨‍👩‍👧‍👦"
        let long = String(repeating: "a", count: max - 2) + family + family + "tail"
        let capped = AgentHistoryDisplayText.displayText(long)
        XCTAssertEqual(capped?.count, max)
        XCTAssertEqual(capped?.hasSuffix(family + "…"), true)
        XCTAssertEqual(capped?.unicodeScalars.last, "…")

        let huge = String(repeating: "é", count: max * 3)
        let hugeCapped = AgentHistoryDisplayText.displayText(huge)
        XCTAssertEqual(hugeCapped?.count, max)
        XCTAssertEqual(hugeCapped?.last, "…")
    }

    func test_envelope_single_and_sibling_tags() {
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope("<system-reminder>Remember things</system-reminder>"))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope(
            "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
        ))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope(
            "  <environment_context>\n  <cwd>/tmp/x</cwd>\n</environment_context>\n"
        ))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope("<local-command-stdout></local-command-stdout>"))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope("<user_instructions attr=\"1\">x</user_instructions>"))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope("<a><a>nested</a></a><b/>"))
        XCTAssertTrue(AgentHistoryDisplayText.isEnvelope("# AGENTS.md instructions for /Users/me/repo\n\n<INSTRUCTIONS>…"))
    }

    func test_inline_tag_not_envelope() {
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("Please fix <b>this</b> now"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("<b>this</b> now"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("<a>x</a> text <a>y</a>"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("<unclosed>text"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("<a>x</b>"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("a < b and c > d"))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope(""))
        XCTAssertFalse(AgentHistoryDisplayText.isEnvelope("Read AGENTS.md instructions first"))
    }

    func test_slash_command_from_envelope() {
        XCTAssertEqual(
            AgentHistoryDisplayText.slashCommand(fromEnvelope:
                "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>PR 12</command-args>"
            ),
            "/review PR 12"
        )
        XCTAssertEqual(
            AgentHistoryDisplayText.slashCommand(fromEnvelope:
                "<command-name>/clear</command-name>\n<command-args></command-args>"
            ),
            "/clear"
        )
        XCTAssertEqual(
            AgentHistoryDisplayText.slashCommand(fromEnvelope: "<command-name>compact</command-name>"),
            "/compact"
        )
        XCTAssertEqual(
            AgentHistoryDisplayText.slashCommand(fromEnvelope: "<command-name>/x</command-name><command-args>  y  "),
            "/x y"
        )
        XCTAssertNil(AgentHistoryDisplayText.slashCommand(fromEnvelope: "<system-reminder>x</system-reminder>"))
        XCTAssertNil(AgentHistoryDisplayText.slashCommand(fromEnvelope: "<command-name>  </command-name>"))
    }

    func test_first_prompt_title_80() {
        XCTAssertEqual(AgentHistoryDisplayText.firstPromptTitle("Fix the parser"), "Fix the parser")
        XCTAssertEqual(
            AgentHistoryDisplayText.firstPromptTitle("Fix the parser\n\n  and   add\ttests"),
            "Fix the parser and add tests"
        )
        let long = String(repeating: "word ", count: 40)
        let title = AgentHistoryDisplayText.firstPromptTitle(long)
        XCTAssertEqual(title.count, 80)
        XCTAssertEqual(title.last, "…")
        XCTAssertFalse(title.dropLast().hasSuffix(" "))

        let exact = String(repeating: "x", count: 80)
        XCTAssertEqual(AgentHistoryDisplayText.firstPromptTitle(exact), exact)
        XCTAssertEqual(AgentHistoryDisplayText.firstPromptTitle(exact + "y").count, 80)

        XCTAssertEqual(AgentHistoryDisplayText.firstPromptTitle("abcdef", limit: 4), "abc…")
        XCTAssertEqual(AgentHistoryDisplayText.firstPromptTitle("  "), "")
    }
}
