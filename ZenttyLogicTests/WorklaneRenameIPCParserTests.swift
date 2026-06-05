import XCTest
@testable import Zentty

final class WorklaneRenameIPCParserTests: XCTestCase {
    func test_parse_title_sets_value_and_defaults_to_caller_worklane() {
        let parsed = WorklaneRenameIPCParser.parse(["--title", "Nimbu support"])

        XCTAssertEqual(parsed, .init(title: "Nimbu support", worklaneIDOverride: nil))
    }

    func test_parse_clear_means_nil_title() {
        let parsed = WorklaneRenameIPCParser.parse(["--clear"])

        XCTAssertEqual(parsed, .init(title: nil, worklaneIDOverride: nil))
    }

    func test_parse_honors_worklane_id_override() {
        XCTAssertEqual(
            WorklaneRenameIPCParser.parse(["--title", "Docs", "--id", "wl_a"]),
            .init(title: "Docs", worklaneIDOverride: "wl_a")
        )
        XCTAssertEqual(
            WorklaneRenameIPCParser.parse(["--clear", "--id", "wl_b"]),
            .init(title: nil, worklaneIDOverride: "wl_b")
        )
    }

    func test_parse_clear_wins_over_title() {
        let parsed = WorklaneRenameIPCParser.parse(["--clear", "--title", "ignored"])

        XCTAssertEqual(parsed, .init(title: nil, worklaneIDOverride: nil))
    }

    func test_parse_rejects_missing_payload() {
        XCTAssertNil(WorklaneRenameIPCParser.parse([]))
        XCTAssertNil(WorklaneRenameIPCParser.parse(["--title"]))
        XCTAssertNil(WorklaneRenameIPCParser.parse(["--id", "wl_a"]))
    }

    func test_parse_allows_titles_that_look_like_flags() {
        // A worklane can legitimately be named "reset" or even "--clear";
        // tokens are consumed left to right, so flag-looking strings in
        // value position stay values.
        XCTAssertEqual(
            WorklaneRenameIPCParser.parse(["--title", "reset"]),
            .init(title: "reset", worklaneIDOverride: nil)
        )
        XCTAssertEqual(
            WorklaneRenameIPCParser.parse(["--title", "--clear"]),
            .init(title: "--clear", worklaneIDOverride: nil)
        )
        XCTAssertEqual(
            WorklaneRenameIPCParser.parse(["--id", "--title", "--title", "Docs"]),
            .init(title: "Docs", worklaneIDOverride: "--title")
        )
    }

    func test_parse_rejects_dangling_flags() {
        XCTAssertNil(WorklaneRenameIPCParser.parse(["--title", "Docs", "--id"]))
    }
}
