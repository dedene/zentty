import Foundation
import XCTest
@testable import Zentty

/// `HistoryIPCService` over `AgentHistoryIPCDataSource` and a real temp index: the scope and
/// visibility rules have to hold in SQL, not only in the service's re-check.
final class HistoryIPCStoreIntegrationTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private static let repoA = "/work/app"
    private static let repoB = "/work/web"

    func test_search_project_scope_enforced_in_sql_even_when_other_repo_is_busier() throws {
        let fixture = try Fixture(testCase: self)
        let mine = try addSession(fixture, "mine", repo: Self.repoA, updatedDaysAgo: 30, text: "the cache key is wrong")
        for index in 0..<60 {
            try addSession(fixture, "busy-\(index)", repo: Self.repoB, updatedDaysAgo: Double(index) / 10,
                           text: "cache cache cache everywhere \(index)")
        }

        let response = try XCTUnwrap(
            try respond(fixture, to: .search(HistorySearchIPCOptions(query: "cache", limit: 10))).search)
        XCTAssertEqual(response.results.map(\.sessionId), ["mine"])
        XCTAssertEqual(response.scope, "project")
        XCTAssertEqual(response.project, Self.repoA)
        XCTAssertEqual(response.indexedSessions, 1, "the count covers the project only")
        XCTAssertEqual(response.results.first?.match?.role, "user")
        XCTAssertEqual(response.results.first?.match?.snippet, "the cache key is wrong")
        _ = mine
    }

    func test_filter_only_search_reports_no_match() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "a", repo: Self.repoA, branch: "main", text: "hello")

        for query in ["branch:main", "agent:claude", "after:2000-01-01"] {
            let response = try XCTUnwrap(
                try respond(fixture, to: .search(HistorySearchIPCOptions(query: query))).search, query)
            XCTAssertEqual(response.results.map(\.sessionId), ["a"], query)
            XCTAssertNil(response.results.first?.match, "\(query): a filter compares no field")
            let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            XCTAssertFalse(json.contains("\"match\""), "\(query): \(json)")
        }

        // A term that hits only the title still names the title.
        let titled = try XCTUnwrap(
            try respond(fixture, to: .search(HistorySearchIPCOptions(query: "session branch:main"))).search)
        XCTAssertEqual(titled.results.first?.match, .metadata(field: "title", value: "Session a"))
    }

    func test_artifact_and_metadata_hits_name_the_field_that_matched() throws {
        let fixture = try Fixture(testCase: self)
        let ran = try addSession(fixture, "ran", repo: Self.repoA, updatedDaysAgo: 1, text: "hello")
        try fixture.addArtifact(session: ran, kind: .command, value: "swift test --filter Cache", daysAgo: 1)
        let changed = try addSession(fixture, "changed", repo: Self.repoA, updatedDaysAgo: 2, text: "hello")
        try fixture.addArtifact(session: changed, kind: .path, value: "Sources/App/QuotaStore.swift", daysAgo: 2)
        try addSession(fixture, "branched", repo: Self.repoA, branch: "feature-oauth-login", text: "hello")

        let command = try XCTUnwrap(
            try respond(fixture, to: .search(HistorySearchIPCOptions(query: "swift test"))).search)
        XCTAssertEqual(command.results.map(\.sessionId), ["ran"])
        let commandMatch = try XCTUnwrap(command.results.first?.match)
        XCTAssertEqual(commandMatch, .metadata(field: "command", value: "swift test --filter Cache"))
        XCTAssertEqual(HistoryIPCFormatting.matchReason(commandMatch), "Ran: swift test --filter Cache")

        let path = try XCTUnwrap(
            try respond(fixture, to: .search(HistorySearchIPCOptions(query: "QuotaStore"))).search)
        XCTAssertEqual(path.results.map(\.sessionId), ["changed"])
        XCTAssertEqual(path.results.first?.match, .metadata(field: "path", value: "Sources/App/QuotaStore.swift"))

        let branch = try XCTUnwrap(
            try respond(fixture, to: .search(HistorySearchIPCOptions(query: "oauth"))).search)
        XCTAssertEqual(branch.results.map(\.sessionId), ["branched"])
        XCTAssertEqual(branch.results.first?.match, .metadata(field: "branch", value: "feature-oauth-login"))
    }

    func test_merged_result_mapping_covers_every_match_kind() {
        let session = AgentHistorySessionSummary(
            id: 1, sourceID: 1, sourceRoot: "/fixtures/claude", agent: .claude,
            nativeID: "s", title: "Fix the cache", titleKind: .custom,
            createdAtMs: 0, updatedAtMs: 1_000, turnCount: 2
        )
        let at = Date(timeIntervalSince1970: 1_793_534_400)
        let atText = HistoryIPCDates.iso8601(milliseconds: 1_793_534_400_000)
        let snippet = HistorySnippet(text: "the cache key", highlights: [], truncatedStart: false, truncatedEnd: false)
        let empty = HistorySnippet(text: "", highlights: [], truncatedStart: false, truncatedEnd: false)

        func mapped(_ match: HistoryMergedResult.Match, terms: Bool = true) -> HistoryIPCMatch? {
            HistoryIPCSearchHit(
                merged: HistoryMergedResult(session: session, score: 1, isWordLevel: true, match: match),
                queryHasTerms: terms
            ).match
        }

        XCTAssertEqual(mapped(.content(role: .user, at: at, snippet: snippet, note: nil)),
                       .content(role: "user", at: atText, snippet: "the cache key"))
        XCTAssertEqual(mapped(.content(role: .agent, at: at, snippet: snippet, note: nil)),
                       .content(role: "agent", at: atText, snippet: "the cache key"))
        XCTAssertNil(mapped(.content(role: .user, at: at, snippet: nil, note: nil)), "no quote, no bare `You: `")
        XCTAssertNil(mapped(.content(role: .agent, at: at, snippet: empty, note: nil)))
        for kind in AgentHistoryArtifactKind.allCases {
            XCTAssertEqual(
                mapped(.content(role: .artifact(kind), at: at, snippet: nil, note: .artifact(kind, value: "v"))),
                .metadata(field: kind.rawValue, value: "v"))
        }
        XCTAssertNil(mapped(.content(role: .artifact(.command), at: at, snippet: nil, note: nil)))
        XCTAssertEqual(mapped(.metadata(note: .field(.branch, value: "main"))), .metadata(field: "branch", value: "main"))
        XCTAssertEqual(mapped(.metadata(note: .field(.repo, value: "app"))), .metadata(field: "repo", value: "app"))
        XCTAssertEqual(mapped(.metadata(note: .field(.folder, value: "src"))), .metadata(field: "folder", value: "src"))
        XCTAssertEqual(mapped(.metadata(note: .artifact(.pr, value: "#12"))), .metadata(field: "pr", value: "#12"))
        XCTAssertEqual(mapped(.metadata(note: nil)), .metadata(field: "title", value: "Fix the cache"))
        XCTAssertNil(mapped(.metadata(note: nil), terms: false), "filter-only: recency, nothing compared")
    }

    func test_show_cannot_read_session_from_another_repo() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "theirs", repo: Self.repoB, text: "private notes")
        try addSession(fixture, "mine", repo: Self.repoA, text: "hello")

        XCTAssertThrowsError(try respond(fixture, to: .show(HistoryShowIPCOptions(sessionID: "theirs")))) {
            XCTAssertEqual($0 as? HistoryIPCError, .notFound("theirs"))
        }
        let shown = try XCTUnwrap(try respond(fixture, to: .show(HistoryShowIPCOptions(sessionID: "mine"))).show)
        XCTAssertEqual(shown.turns.map(\.text), ["hello"])
        XCTAssertEqual(shown.totalTurns, 1)
        XCTAssertEqual(shown.omittedTurns, 0)
    }

    func test_tombstoned_excluded_child_and_disabled_source_sessions_are_invisible() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "visible", repo: Self.repoA, text: "needle visible")
        try addSession(fixture, "removed", repo: Self.repoA, text: "needle removed")
        try addSession(fixture, "excluded", cwd: Self.repoA + "/secret", repo: Self.repoA, text: "needle excluded")
        try addSession(fixture, "child", repo: Self.repoA, parent: "visible", text: "needle child")
        try fixture.addSource(.codex, enabled: false)
        try addSession(fixture, "disabled", agent: .codex, repo: Self.repoA, text: "needle disabled")
        try fixture.store().addTombstone(AgentHistorySessionKey(agent: .claude, nativeID: "removed"), removedAtMs: 1)
        let exclusions = AgentHistoryExclusionMatcher(folders: [Self.repoA + "/secret"])
        fixture.exclusions.set(exclusions)

        for allProjects in [false, true] {
            let response = try XCTUnwrap(try respond(
                fixture,
                to: .search(HistorySearchIPCOptions(query: "needle", allProjects: allProjects)),
                exclusions: exclusions
            ).search)
            XCTAssertEqual(response.results.map(\.sessionId), ["visible"], "allProjects=\(allProjects)")
            XCTAssertEqual(response.indexedSessions, 1, "allProjects=\(allProjects)")

            for hidden in ["removed", "excluded", "child", "disabled"] {
                XCTAssertThrowsError(try respond(
                    fixture,
                    to: .show(HistoryShowIPCOptions(sessionID: hidden, allProjects: allProjects)),
                    exclusions: exclusions
                )) {
                    XCTAssertEqual($0 as? HistoryIPCError, .notFound(hidden), "\(hidden) allProjects=\(allProjects)")
                }
            }
        }
    }

    func test_all_projects_sees_both_repos() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "a", repo: Self.repoA, updatedDaysAgo: 2, text: "deploy script")
        try addSession(fixture, "b", repo: Self.repoB, updatedDaysAgo: 1, text: "deploy pipeline")

        let response = try XCTUnwrap(try respond(
            fixture, to: .search(HistorySearchIPCOptions(query: "deploy", allProjects: true))).search)
        XCTAssertEqual(Set(response.results.map(\.sessionId)), ["a", "b"])
        XCTAssertEqual(response.scope, "all")
        XCTAssertNil(response.project)
        XCTAssertEqual(response.indexedSessions, 2)

        let shown = try XCTUnwrap(try respond(
            fixture, to: .show(HistoryShowIPCOptions(sessionID: "b", allProjects: true))).show)
        XCTAssertEqual(shown.cwd, Self.repoB)
        XCTAssertEqual(shown.scope, "all")
    }

    func test_newer_schema_is_history_unavailable() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "mine", repo: Self.repoA, text: "hello")
        let metadataIndex = try fixture.metadataIndex()
        fixture.index.closeWriter()
        fixture.index.storage.readers.closeAll()
        let bump = try AgentHistoryDatabase(
            url: fixture.index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try bump.setUserVersion(AgentHistorySchema.currentVersion + 1)
        bump.close()

        // An engine handed out before the bump: its reads now refuse.
        let newer = AgentHistoryStorage(paths: fixture.index.paths)
        addTeardownBlock { newer.readers.closeAll() }
        let engine = HistorySearchEngine(
            readers: newer.readers,
            metadataIndex: metadataIndex,
            tokenizer: { .trigram },
            exclusions: { AgentHistoryExclusionMatcher(folders: []) },
            enabledAgents: { Set(AgentHistoryAgent.allCases) }
        )
        let dataSource = AgentHistoryIPCDataSource(status: { Self.readyStatus }, engine: { engine })
        XCTAssertThrowsError(try service(fixture).respond(
            to: .search(HistorySearchIPCOptions(query: "hello")), caller: caller(dataSource))) {
            XCTAssertEqual($0 as? HistoryIPCError, .unavailable(HistoryIPCMessages.readFailed))
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_unavailable")
        }

        // The controller's status reports the failure; nothing is read at all.
        var failed = Self.readyStatus
        failed.state = .failed(.newerSchema(found: AgentHistorySchema.currentVersion + 1))
        let failedSource = AgentHistoryIPCDataSource(status: { [failed] in failed }, engine: { nil })
        XCTAssertThrowsError(try service(fixture).respond(
            to: .show(HistoryShowIPCOptions(sessionID: "mine")), caller: caller(failedSource))) {
            XCTAssertEqual($0 as? HistoryIPCError, .unavailable(HistoryIPCMessages.unavailable(.newerSchema(found: 0))))
        }
    }

    func test_data_source_availability_follows_status_and_engine() throws {
        let fixture = try Fixture(testCase: self)
        let engine = try fixture.engine()
        var status = Self.readyStatus

        XCTAssertEqual(AgentHistoryIPCDataSource(status: { [status] in status }, engine: { engine }).availability(),
                       .ready(complete: true))
        status.isBackfillComplete = false
        XCTAssertEqual(AgentHistoryIPCDataSource(status: { [status] in status }, engine: { engine }).availability(),
                       .ready(complete: false))
        XCTAssertEqual(AgentHistoryIPCDataSource(status: { [status] in status }, engine: { nil }).availability(),
                       .unavailable(HistoryIPCMessages.starting))
        status.hasConsented = false
        XCTAssertEqual(AgentHistoryIPCDataSource(status: { [status] in status }, engine: { engine }).availability(), .disabled)
        XCTAssertEqual(AgentHistoryIPCDataSource(status: { .off }, engine: { engine }).availability(), .disabled)
    }

    // MARK: - Fixtures

    private static var readyStatus: AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = Set(AgentHistoryAgent.allCases)
        status.state = .watching
        status.isBackfillComplete = true
        return status
    }

    @discardableResult
    private func addSession(
        _ fixture: Fixture,
        _ nativeID: String,
        agent: AgentHistoryAgent = .claude,
        title: String? = nil,
        cwd: String? = nil,
        repo: String,
        branch: String? = nil,
        updatedDaysAgo: Double = 1,
        parent: String? = nil,
        text: String
    ) throws -> Int64 {
        let id = try fixture.addSession(
            nativeID, agent: agent, title: title ?? "Session \(nativeID)", cwd: cwd ?? repo, repo: repo,
            mainRepo: repo, branch: branch, updatedDaysAgo: updatedDaysAgo, parent: parent)
        try fixture.addMessage(session: id, daysAgo: updatedDaysAgo, text: text)
        return id
    }

    private func service(_ fixture: Fixture) -> HistoryIPCService {
        var service = HistoryIPCService()
        service.homeDirectory = "/Users/tester"
        service.identity = { _ in nil }
        let now = fixture.now
        service.now = { now }
        return service
    }

    private func caller(
        _ dataSource: any HistoryIPCDataSource,
        exclusions: AgentHistoryExclusionMatcher = AgentHistoryExclusionMatcher(folders: [])
    ) -> HistoryIPCCaller {
        HistoryIPCCaller(
            paneCWD: Self.repoA,
            paneRepoRoot: Self.repoA,
            isRemotePane: false,
            allowAgentsAllProjects: true,
            liveKeys: [],
            exclusions: exclusions,
            dataSource: dataSource
        )
    }

    private func respond(
        _ fixture: Fixture,
        to command: HistoryIPCCommand,
        exclusions: AgentHistoryExclusionMatcher = AgentHistoryExclusionMatcher(folders: [])
    ) throws -> HistoryIPCResult {
        let engine = try fixture.engine()
        let dataSource = AgentHistoryIPCDataSource(status: { Self.readyStatus }, engine: { engine })
        return try service(fixture).respond(to: command, caller: caller(dataSource, exclusions: exclusions))
    }
}
