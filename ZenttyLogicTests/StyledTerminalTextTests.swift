import AppKit
import XCTest
@testable import Zentty

/// SGR text from `readStyledText` → attributed string for the pill peek.
@MainActor
final class StyledTerminalTextTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let foreground = NSColor.white

    private func render(_ text: String) -> NSAttributedString {
        StyledTerminalText.attributedString(
            from: text,
            style: StyledTerminalText.Style(font: font, foreground: foreground)
        )
    }

    private func color(_ string: NSAttributedString, at index: Int, _ key: NSAttributedString.Key = .foregroundColor) -> String? {
        (string.attribute(key, at: index, effectiveRange: nil) as? NSColor)?.themeToken
    }

    func test_plain_text_uses_the_default_foreground() {
        let result = render("hello")

        XCTAssertEqual(result.string, "hello")
        XCTAssertEqual(color(result, at: 0), foreground.themeToken)
    }

    func test_basic_and_bright_colors_map_to_the_palette_and_reset() {
        let result = render("\u{1B}[31mred\u{1B}[0m \u{1B}[94mblue")

        XCTAssertEqual(result.string, "red blue")
        XCTAssertEqual(color(result, at: 0), StyledTerminalText.defaultPalette[1].themeToken)
        XCTAssertEqual(color(result, at: 3), foreground.themeToken)
        XCTAssertEqual(color(result, at: 4), StyledTerminalText.defaultPalette[12].themeToken)
    }

    func test_256_and_truecolor_foreground_and_background() {
        let result = render("\u{1B}[38;5;196ma\u{1B}[48;2;10;20;30mb")

        XCTAssertEqual(color(result, at: 0), StyledTerminalText.color(index: 196, palette: [])?.themeToken)
        XCTAssertEqual(
            color(result, at: 1, .backgroundColor),
            NSColor(srgbRed: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1).themeToken
        )
        XCTAssertEqual(color(result, at: 1), StyledTerminalText.color(index: 196, palette: [])?.themeToken, "fg carries over")
    }

    func test_bold_italic_and_underline_attributes() {
        let result = render("\u{1B}[1;3;4mx\u{1B}[22;23;24my")

        let boldFont = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertNotNil(result.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let plainFont = result.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertNil(result.attribute(.underlineStyle, at: 1, effectiveRange: nil))
    }

    func test_inverse_swaps_foreground_and_background() {
        let result = render("\u{1B}[32;7mx")

        XCTAssertEqual(color(result, at: 0, .backgroundColor), StyledTerminalText.defaultPalette[2].themeToken)
        XCTAssertEqual(color(result, at: 0), NSColor.black.themeToken)
    }

    func test_non_sgr_sequences_and_osc_are_dropped() {
        let result = render("a\u{1B}[2Kb\u{1B}]0;title\u{07}c\u{1B}]8;;url\u{1B}\\d\re")

        XCTAssertEqual(result.string, "abcde")
    }

    func test_tail_drops_trailing_blank_rows_and_keeps_the_last_lines() {
        let screen = (1...12).map { "line \($0)" }.joined(separator: "\n")
            + "\n\u{1B}[0m   \n\n"

        let tail = StyledTerminalText.tail(screen, maxLines: 10)

        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first, "line 3")
        XCTAssertEqual(lines.last, "line 12")
    }

    func test_tail_of_a_short_prompt_on_an_empty_screen_keeps_the_prompt() {
        let screen = "$ ls\nREADME.md\n$ " + String(repeating: "\n", count: 30)

        XCTAssertEqual(StyledTerminalText.tail(screen, maxLines: 10), "$ ls\nREADME.md\n$ ")
    }
}
