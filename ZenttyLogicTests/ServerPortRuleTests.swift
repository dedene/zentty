import XCTest
@testable import Zentty

final class ServerPortRuleTests: XCTestCase {
    // MARK: - Parsing

    func test_parses_exact_port() {
        let rule = ServerPortRule.parse("9229")

        XCTAssertEqual(rule, ServerPortRule(lowerBound: 9229, upperBound: 9229))
        XCTAssertEqual(rule?.canonicalString, "9229")
    }

    func test_parses_inclusive_range() {
        let rule = ServerPortRule.parse("24678-24680")

        XCTAssertEqual(rule, ServerPortRule(lowerBound: 24678, upperBound: 24680))
        XCTAssertEqual(rule?.canonicalString, "24678-24680")
        XCTAssertTrue(rule?.contains(24679) == true)
        XCTAssertFalse(rule?.contains(24681) == true)
    }

    func test_parses_range_with_surrounding_whitespace() {
        XCTAssertEqual(ServerPortRule.parse(" 3000 - 3002 "), ServerPortRule(lowerBound: 3000, upperBound: 3002))
    }

    func test_rejects_non_numeric_text() {
        XCTAssertNil(ServerPortRule.parse("abc"))
        XCTAssertNil(ServerPortRule.parse(""))
        XCTAssertNil(ServerPortRule.parse("30a0"))
        XCTAssertNil(ServerPortRule.parse("3000-"))
        XCTAssertNil(ServerPortRule.parse("3000-3001-3002"))
    }

    func test_rejects_out_of_range_ports() {
        XCTAssertNil(ServerPortRule.parse("0"))
        XCTAssertNil(ServerPortRule.parse("70000"))
        XCTAssertNil(ServerPortRule.parse("0-100"))
        XCTAssertNil(ServerPortRule.parse("65535-70000"))
    }

    func test_rejects_reversed_range() {
        XCTAssertNil(ServerPortRule.parse("5000-4000"))
    }

    // MARK: - Normalization

    func test_normalize_drops_invalid_and_sorts() {
        let canonical = ServerPortRule.canonicalStrings(["8080", "abc", "70000", "3000"])

        XCTAssertEqual(canonical, ["3000", "8080"])
    }

    func test_normalize_merges_overlapping_ranges() {
        let canonical = ServerPortRule.canonicalStrings(["3000-3005", "3004-3008"])

        XCTAssertEqual(canonical, ["3000-3008"])
    }

    func test_normalize_merges_adjacent_ranges_and_ports() {
        let canonical = ServerPortRule.canonicalStrings(["3000", "3001", "3002-3003"])

        XCTAssertEqual(canonical, ["3000-3003"])
    }

    func test_normalize_keeps_non_adjacent_ranges_separate() {
        let canonical = ServerPortRule.canonicalStrings(["3000", "3002"])

        XCTAssertEqual(canonical, ["3000", "3002"])
    }

    func test_normalize_dedupes_exact_duplicates() {
        let canonical = ServerPortRule.canonicalStrings(["9229", "9229"])

        XCTAssertEqual(canonical, ["9229"])
    }

    // MARK: - Round-trip

    func test_canonical_strings_round_trip() {
        let canonical = ["3000", "8080-8090"]

        XCTAssertEqual(ServerPortRule.canonicalStrings(canonical), canonical)
    }

    // MARK: - Add / remove

    func test_adding_port_merges_into_existing_range() {
        XCTAssertEqual(ServerPortRule.addingPort(3001, to: ["3000", "3002"]), ["3000-3002"])
    }

    func test_removing_port_splits_range() {
        XCTAssertEqual(ServerPortRule.removingPort(3001, from: ["3000-3002"]), ["3000", "3002"])
    }

    func test_removing_boundary_port_shrinks_range() {
        XCTAssertEqual(ServerPortRule.removingPort(3000, from: ["3000-3002"]), ["3001-3002"])
    }

    func test_removing_only_port_clears_rule() {
        XCTAssertEqual(ServerPortRule.removingPort(9229, from: ["9229"]), [])
    }

    func test_removing_absent_port_is_noop() {
        XCTAssertEqual(ServerPortRule.removingPort(4000, from: ["3000", "8080"]), ["3000", "8080"])
    }
}
