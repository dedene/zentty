import AppKit
import SwiftUI
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryTextStylerTests: XCTestCase {
    private lazy var theme = AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil))

    private func highlightedSubstrings(_ attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(attributed[run.range].characters)
        }
    }

    private func style(_ text: String, _ ranges: [NSRange]) -> AttributedString {
        AgentHistoryTextStyler.attributed(
            AgentHistoryHighlightedText(text, ranges: ranges),
            theme: theme,
            font: .body,
            color: theme.primaryText
        )
    }

    func test_highlights_ranges_and_keeps_base_style_elsewhere() {
        let attributed = style("fix the crash in sidebar", [NSRange(location: 8, length: 5)])
        XCTAssertEqual(String(attributed.characters), "fix the crash in sidebar")
        XCTAssertEqual(highlightedSubstrings(attributed), ["crash"])
        for run in attributed.runs {
            XCTAssertEqual(run.foregroundColor, theme.primaryText)
            if run.backgroundColor != nil {
                XCTAssertEqual(run.backgroundColor, theme.highlightBackground)
            }
        }
    }

    func test_clamps_ranges_past_either_edge() {
        XCTAssertEqual(highlightedSubstrings(style("hello", [NSRange(location: 3, length: 10)])), ["lo"])
        XCTAssertEqual(highlightedSubstrings(style("hello", [NSRange(location: -2, length: 4)])), ["he"])
    }

    func test_drops_empty_negative_and_out_of_bounds_ranges() {
        let attributed = style("hello", [
            NSRange(location: 1, length: 0),
            NSRange(location: 10, length: 2),
            NSRange(location: -4, length: 2),
            NSRange(location: NSNotFound, length: 3),
        ])
        XCTAssertEqual(highlightedSubstrings(attributed), [])
        XCTAssertEqual(String(attributed.characters), "hello")
    }

    func test_handles_utf16_ranges_after_emoji() {
        // "😀" is two UTF-16 units: "fix" starts at 3.
        XCTAssertEqual(highlightedSubstrings(style("😀 fix it", [NSRange(location: 3, length: 3)])), ["fix"])
    }
}
