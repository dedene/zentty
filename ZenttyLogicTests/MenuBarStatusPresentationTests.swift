import XCTest
@testable import Zentty

final class MenuBarStatusPresentationTests: XCTestCase {
    func test_empty_state_uses_terminal_symbol_with_empty_title() {
        let presentation = MenuBarStatusPresentation.resolve(counts: .empty)

        XCTAssertEqual(presentation.title, "")
        XCTAssertEqual(presentation.symbolName, "terminal")
        XCTAssertEqual(presentation.tone, .idle)
        XCTAssertEqual(presentation.accessibilityLabel, "No active agent panes")
    }

    func test_all_idle_uses_terminal_symbol_with_empty_title() {
        let presentation = MenuBarStatusPresentation.resolve(counts: MenuBarAgentCounts(
            running: 0,
            waiting: 0,
            idle: 5
        ))

        XCTAssertEqual(presentation.title, "")
        XCTAssertEqual(presentation.symbolName, "terminal")
        XCTAssertEqual(presentation.tone, .idle)
    }

    func test_only_running_shows_running_count() {
        let presentation = MenuBarStatusPresentation.resolve(counts: MenuBarAgentCounts(
            running: 3,
            waiting: 0,
            idle: 2
        ))

        XCTAssertEqual(presentation.title, "3")
        XCTAssertEqual(presentation.symbolName, "play.circle")
        XCTAssertEqual(presentation.tone, .running)
        XCTAssertEqual(presentation.accessibilityLabel, "Agent status: 3 running, 2 idle")
    }

    func test_only_waiting_shows_zero_running_and_waiting_count() {
        let presentation = MenuBarStatusPresentation.resolve(counts: MenuBarAgentCounts(
            running: 0,
            waiting: 2,
            idle: 1
        ))

        XCTAssertEqual(presentation.title, "0\u{00B7}2")
        XCTAssertEqual(presentation.symbolName, "exclamationmark.circle.fill")
        XCTAssertEqual(presentation.tone, .waiting)
        XCTAssertEqual(presentation.accessibilityLabel, "Agent status: 2 waiting, 1 idle")
    }

    func test_mixed_running_and_waiting_shows_compact_pair() {
        let presentation = MenuBarStatusPresentation.resolve(counts: MenuBarAgentCounts(
            running: 3,
            waiting: 1,
            idle: 5
        ))

        XCTAssertEqual(presentation.title, "3\u{00B7}1")
        XCTAssertEqual(presentation.symbolName, "play.circle")
        XCTAssertEqual(presentation.tone, .waiting)
        XCTAssertEqual(presentation.accessibilityLabel, "Agent status: 3 running, 1 waiting, 5 idle")
    }

    func test_agent_state_counts_map_to_menu_bar_buckets() {
        var counts = MenuBarAgentCounts.empty
        counts.include(.starting)
        counts.include(.running)
        counts.include(.needsInput)
        counts.include(.unresolvedStop)
        counts.include(.idle)

        XCTAssertEqual(counts, MenuBarAgentCounts(running: 2, waiting: 2, idle: 1))
    }
}
