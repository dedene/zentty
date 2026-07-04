import XCTest
@testable import Zentty

final class PaneRenameIPCParserTests: XCTestCase {
    func test_parse_title() {
        let parsed = PaneRenameIPCParser.parse(["--title", "Nimbu API"])
        XCTAssertEqual(parsed, PaneRenameIPCParser.Parsed(title: "Nimbu API", worklaneIDOverride: nil, paneIDOverride: nil))
    }

    func test_parse_clear() {
        let parsed = PaneRenameIPCParser.parse(["--clear"])
        XCTAssertEqual(parsed, PaneRenameIPCParser.Parsed(title: nil, worklaneIDOverride: nil, paneIDOverride: nil))
    }

    func test_parse_with_overrides() {
        XCTAssertEqual(
            PaneRenameIPCParser.parse(["--title", "Docs", "--id", "wl_a", "--rename-pane-id", "pn_a"]),
            PaneRenameIPCParser.Parsed(title: "Docs", worklaneIDOverride: "wl_a", paneIDOverride: "pn_a")
        )
        XCTAssertEqual(
            PaneRenameIPCParser.parse(["--clear", "--rename-pane-id", "pn_b"]),
            PaneRenameIPCParser.Parsed(title: nil, worklaneIDOverride: nil, paneIDOverride: "pn_b")
        )
    }

    func test_parse_clear_wins_over_title() {
        let parsed = PaneRenameIPCParser.parse(["--clear", "--title", "ignored"])
        XCTAssertEqual(parsed?.title, nil)
    }

    func test_parse_rejects_invalid_arguments() {
        XCTAssertNil(PaneRenameIPCParser.parse([]))
        XCTAssertNil(PaneRenameIPCParser.parse(["--title"]))
        XCTAssertNil(PaneRenameIPCParser.parse(["--rename-pane-id", "pn_a"]))
        XCTAssertNil(PaneRenameIPCParser.parse(["--title", "Docs", "--rename-pane-id"]))
    }

    func test_parse_ignores_reserved_pane_selector_flag() {
        // `--pane-id` is consumed by ParsedPaneSelectors before handler args
        // reach PaneRenameIPCParser; it must not be treated as a rename target.
        XCTAssertEqual(
            PaneRenameIPCParser.parse(["--title", "Docs", "--pane-id", "pn_a"]),
            PaneRenameIPCParser.Parsed(title: "Docs", worklaneIDOverride: nil, paneIDOverride: nil)
        )
    }
}