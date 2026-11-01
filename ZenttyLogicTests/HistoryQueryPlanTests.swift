import Foundation
import XCTest
@testable import Zentty

/// Guards the content tier's SQL against plan regressions (spec §7.2): the FTS table must stay the
/// outer loop of an ordered scan, every filter must be evaluated inside it, and no statement may
/// sort through a temp B-tree, whatever filter combination or tokenizer is in play.
final class HistoryQueryPlanTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private static let tokenizers: [AgentHistoryTokenizer] = [.trigram, .unicode61]

    /// One entry per filter the content statements can carry, plus a combination of all of them.
    private static var filterMatrix: [(name: String, filters: HistoryContentQuery.Filters)] {
        let after = Fixture.ms(daysAgo: 30)
        let before = Fixture.ms(daysAgo: 1)
        return [
            ("none", HistoryContentQuery.Filters()),
            ("project scope with cwd prefix",
             HistoryContentQuery.Filters(scope: Fixture.projectScope("/repos/app", allowsCWDPrefix: true))),
            ("project scope without cwd prefix",
             HistoryContentQuery.Filters(scope: Fixture.projectScope("/Users/me", allowsCWDPrefix: false))),
            ("agent", HistoryContentQuery.Filters(agents: [.codex])),
            ("agents", HistoryContentQuery.Filters(agents: [.claude, .codex])),
            ("repo name", HistoryContentQuery.Filters(repoNames: ["app"])),
            ("repo path", HistoryContentQuery.Filters(repoNames: ["/repos/app"])),
            ("branch", HistoryContentQuery.Filters(branches: ["feat/x", "main"])),
            ("before+after", HistoryContentQuery.Filters(beforeMs: before, afterMs: after)),
            ("instr", HistoryContentQuery.Filters(instrTerms: ["go", "ui"])),
            ("all", HistoryContentQuery.Filters(
                agents: [.claude, .grok], repoNames: ["app", "/repos/lib"], branches: ["main"],
                beforeMs: before, afterMs: after, instrTerms: ["go"],
                scope: Fixture.projectScope("/repos/app"))),
        ]
    }

    private static func matchExpression(for tokenizer: AgentHistoryTokenizer) -> String {
        tokenizer == .trigram ? "\"deploy\"" : "\"deploy\"*"
    }

    private func plan(_ db: AgentHistoryDatabase, _ statement: HistoryContentQuery.Statement) throws -> [String] {
        try db.explainQueryPlan(statement.sql, statement.bindings)
    }

    private func assertNoTempBTree(
        _ plan: [String], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            plan.contains { $0.contains("USE TEMP B-TREE") },
            "\(label) sorts through a temp B-tree:\n\(plan.joined(separator: "\n"))", file: file, line: line)
    }

    /// FTS first (`SCAN f VIRTUAL TABLE`), then the content row and its session by primary key.
    private func assertOrderedFTSScan(
        _ plan: [String], row: String, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let rendered = plan.joined(separator: "\n")
        assertNoTempBTree(plan, label, file: file, line: line)
        XCTAssertTrue(
            plan.first?.hasPrefix("SCAN f VIRTUAL TABLE") == true,
            "\(label) does not drive the scan from FTS:\n\(rendered)", file: file, line: line)
        XCTAssertTrue(
            plan.contains { $0.hasPrefix("SEARCH \(row) USING INTEGER PRIMARY KEY (rowid=?)") },
            "\(label) does not look up \(row) by rowid:\n\(rendered)", file: file, line: line)
        XCTAssertTrue(
            plan.contains { $0.hasPrefix("SEARCH s USING INTEGER PRIMARY KEY (rowid=?)") },
            "\(label) does not look up the session by rowid:\n\(rendered)", file: file, line: line)
    }

    // MARK: - FTS statements

    func test_message_query_plan_has_no_temp_btree_all_filter_combinations() throws {
        for tokenizer in Self.tokenizers {
            let fixture = try Fixture(testCase: self, tokenizer: tokenizer)
            let db = try fixture.writer
            for (name, filters) in Self.filterMatrix {
                let statement = HistoryContentQuery.messages(match: Self.matchExpression(for: tokenizer), filters: filters)
                assertOrderedFTSScan(try plan(db, statement), row: "m", "messages [\(tokenizer.rawValue), \(name)]")
            }
        }
    }

    func test_artifact_query_plan_has_no_temp_btree() throws {
        for tokenizer in Self.tokenizers {
            let fixture = try Fixture(testCase: self, tokenizer: tokenizer)
            let db = try fixture.writer
            for (name, filters) in Self.filterMatrix {
                let statement = HistoryContentQuery.artifacts(match: Self.matchExpression(for: tokenizer), filters: filters)
                assertOrderedFTSScan(try plan(db, statement), row: "a", "artifacts [\(tokenizer.rawValue), \(name)]")
            }
        }
    }

    // MARK: - Scan fallback

    func test_scan_fallback_plan_uses_rowid_range() throws {
        let fixture = try Fixture(testCase: self, tokenizer: .none)
        let db = try fixture.writer

        let cutoff = try plan(db, HistoryContentQuery.scanCutoff())
        assertNoTempBTree(cutoff, "scan cutoff")

        for (name, filters) in Self.filterMatrix {
            let label = "scan [\(name)]"
            let scan = try plan(db, HistoryContentQuery.scan(cutoff: 42, filters: filters))
            let rendered = scan.joined(separator: "\n")
            assertNoTempBTree(scan, label)
            XCTAssertTrue(
                scan.first?.hasPrefix("SEARCH m USING INTEGER PRIMARY KEY (rowid>?)") == true,
                "\(label) does not walk the newest rowid range:\n\(rendered)")
            XCTAssertTrue(
                scan.contains { $0.hasPrefix("SEARCH s USING INTEGER PRIMARY KEY (rowid=?)") },
                "\(label) does not look up the session by rowid:\n\(rendered)")
        }
    }

    // MARK: - Sessions

    func test_matching_turns_uses_session_seq_index() throws {
        let fixture = try Fixture(testCase: self)
        let db = try fixture.writer
        for terms in [[], ["cache"], ["cache", "key"]] {
            let label = "matching turns [\(terms.count) terms]"
            let turns = try plan(db, HistoryContentQuery.matchingTurns(sessionID: 1, terms: terms))
            let rendered = turns.joined(separator: "\n")
            assertNoTempBTree(turns, label)
            XCTAssertEqual(turns.count, 1, "\(label):\n\(rendered)")
            XCTAssertTrue(
                turns.first?.hasPrefix("SEARCH messages USING INDEX sqlite_autoindex_messages_1 (session_id=?)") == true,
                "\(label) does not use the (session_id, seq) index:\n\(rendered)")
        }
    }
}
