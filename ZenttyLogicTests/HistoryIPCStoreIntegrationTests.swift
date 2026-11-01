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
        cwd: String? = nil,
        repo: String,
        updatedDaysAgo: Double = 1,
        parent: String? = nil,
        text: String
    ) throws -> Int64 {
        let id = try fixture.addSession(
            nativeID, agent: agent, title: "Session \(nativeID)", cwd: cwd ?? repo, repo: repo, mainRepo: repo,
            updatedDaysAgo: updatedDaysAgo, parent: parent)
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
