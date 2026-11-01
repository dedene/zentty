import Foundation
import XCTest
@testable import Zentty

/// `repo:` and `branch:` must admit the same sessions in the metadata tier (Swift) and the content
/// tier (SQL), including non-ASCII values that SQLite's ASCII-only `lower()` / `LIKE` cannot fold.
final class HistoryFilterFoldingTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private static let term = "deploy"

    /// Sessions both tiers admit for `filter`: the metadata tier filter-only, the content tier
    /// with a term every fixture message contains.
    private func tiers(
        _ filter: String, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (metadata: Set<String>, content: Set<String>) {
        let engine = try fixture.engine()
        let metadata = try fixture.metadataIndex().search(Fixture.query(filter), context: fixture.context())
        let content = try engine.searchContent(
            Fixture.query("\(filter) \(Self.term)"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation())
        return (Set(metadata.results.map(\.session.nativeID)), Set(content.results.map(\.session.nativeID)))
    }

    private func assertParity(
        _ filter: String, expected: Set<String>, fixture: Fixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (metadata, content) = try tiers(filter, fixture: fixture)
        XCTAssertEqual(metadata, expected, "metadata tier for \(filter)", file: file, line: line)
        XCTAssertEqual(content, expected, "content tier for \(filter)", file: file, line: line)
    }

    private func addSession(
        _ fixture: Fixture, _ name: String, repo: String? = nil, branch: String? = nil
    ) throws {
        let session = try fixture.addSession(name, cwd: repo, repo: repo, mainRepo: repo, branch: branch)
        try fixture.addMessage(session: session, daysAgo: 1, text: "\(Self.term) the \(name) service")
    }

    private func seed(_ fixture: Fixture) throws {
        try addSession(fixture, "upper-accent", repo: "/work/École", branch: "FÉATURE/Login")
        // Decomposed (NFD) `É`, as HFS+-era paths and some tools store it.
        try addSession(fixture, "decomposed", repo: "/work/E\u{301}COLE-two", branch: "fe\u{301}ature-2")
        try addSession(fixture, "plain", repo: "/work/ecole", branch: "feature/plain")
        try addSession(fixture, "greek", repo: "/work/ΣΟΦΙΑ", branch: "ΔΟΚΙΜΗ")
    }

    func test_branch_filter_folds_non_ascii_case_in_both_tiers() throws {
        for tokenizer: AgentHistoryTokenizer in [.trigram, .none] {
            let fixture = try Fixture(testCase: self, tokenizer: tokenizer)
            try seed(fixture)

            try assertParity("branch:féature", expected: ["upper-accent", "decomposed"], fixture: fixture)
            try assertParity("branch:FÉATURE/login", expected: ["upper-accent"], fixture: fixture)
            try assertParity("branch:δοκιμη", expected: ["greek"], fixture: fixture)
            try assertParity("branch:feature", expected: ["plain"], fixture: fixture)
        }
    }

    func test_repo_name_filter_folds_non_ascii_case_in_both_tiers() throws {
        for tokenizer: AgentHistoryTokenizer in [.trigram, .none] {
            let fixture = try Fixture(testCase: self, tokenizer: tokenizer)
            try seed(fixture)

            try assertParity("repo:école", expected: ["upper-accent"], fixture: fixture)
            try assertParity("repo:ÉCOLE", expected: ["upper-accent"], fixture: fixture)
            try assertParity("repo:école-two", expected: ["decomposed"], fixture: fixture)
            try assertParity("repo:σοφια", expected: ["greek"], fixture: fixture)
            try assertParity("repo:ECOLE", expected: ["plain"], fixture: fixture)
        }
    }

    func test_repo_path_filter_stays_exact_in_both_tiers() throws {
        let fixture = try Fixture(testCase: self)
        try seed(fixture)

        try assertParity("repo:/work/École", expected: ["upper-accent"], fixture: fixture)
        try assertParity("repo:/work/école", expected: [], fixture: fixture)
    }

    func test_fold_is_unicode_lowercase_in_canonical_composition() {
        XCTAssertEqual(HistoryFilterFolding.fold("FÉATURE"), "féature")
        XCTAssertEqual(HistoryFilterFolding.fold("E\u{301}cole"), "\u{e9}cole")
        XCTAssertEqual(HistoryFilterFolding.foldedBasename("/work/École/"), "école")
        XCTAssertNil(HistoryFilterFolding.foldedBasename("/"))
        XCTAssertNil(HistoryFilterFolding.foldedBasename(""))
        XCTAssertTrue(HistoryFilterFolding.contains("féature/login", "ature/l"))
        XCTAssertFalse(HistoryFilterFolding.contains("féature", "e\u{301}"))
    }
}
