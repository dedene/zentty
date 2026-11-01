import Foundation
import XCTest
@testable import Zentty

final class HistoryIPCServiceTests: XCTestCase {
    private static let home = "/Users/tester"
    private static let repo = "/work/app"
    private static let otherRepo = "/work/web"

    // MARK: - Availability and scope

    func test_nil_or_disabled_data_source_is_history_disabled() {
        var caller = Self.caller(dataSource: nil)
        XCTAssertThrowsError(try service().respond(to: Self.search("cache"), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .disabled)
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_disabled")
        }

        let fake = FakeDataSource(availability: .disabled)
        caller.dataSource = fake
        XCTAssertThrowsError(try service().respond(to: Self.show("abc"), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .disabled)
        }
        XCTAssertEqual(fake.calls, [], "nothing is read while History is off")
    }

    func test_disabled_wins_over_scope_denied() {
        let fake = FakeDataSource(availability: .disabled)
        let caller = Self.caller(dataSource: fake, allowAll: false)
        XCTAssertThrowsError(try service().respond(to: Self.search("cache", all: true), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .disabled)
        }
    }

    func test_unavailable_index_is_history_unavailable() {
        let fake = FakeDataSource(availability: .unavailable("The index is damaged."))
        XCTAssertThrowsError(try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .unavailable("The index is damaged."))
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_unavailable")
        }
        XCTAssertEqual(fake.calls, [])
    }

    func test_read_failure_after_turn_off_is_history_disabled_and_other_failures_unavailable() {
        let fake = FakeDataSource()
        fake.searchError = HistorySearchError.indexUnavailable("off")
        XCTAssertThrowsError(try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .disabled)
        }
        fake.searchError = HistorySearchError.indexUnavailable("corrupt")
        XCTAssertThrowsError(try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .unavailable(HistoryIPCMessages.readFailed))
        }
    }

    func test_all_projects_denied_when_setting_off() {
        let fake = FakeDataSource()
        let caller = Self.caller(dataSource: fake, allowAll: false)
        XCTAssertThrowsError(try service().respond(to: Self.search("cache", all: true), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeDenied)
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_scope_denied")
        }
        XCTAssertThrowsError(try service().respond(to: Self.show("abc", all: true), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeDenied)
        }
        XCTAssertEqual(fake.calls, [], "the data source is never queried")
    }

    func test_all_projects_allowed_passes_nil_scope_and_reports_scope_all() throws {
        let fake = FakeDataSource()
        fake.hits = [Self.hit(Self.summary(id: 1, repo: Self.otherRepo))]
        let caller = Self.caller(dataSource: fake, allowAll: true)

        let response = try XCTUnwrap(try service().respond(to: Self.search("cache", all: true), caller: caller).search)
        XCTAssertEqual(response.scope, "all")
        XCTAssertNil(response.project)
        XCTAssertEqual(fake.searchContexts.map(\.scope), [.all])
        XCTAssertEqual(fake.searchContexts.first?.currentRepositoryKey, Self.repo, "the pane's repo still ranks first")
        XCTAssertEqual(fake.countScopes, [.all])
        XCTAssertEqual(response.results.map(\.sessionId), [Self.nativeID(1)])
    }

    func test_remote_or_folderless_pane_has_unknown_scope_unless_all() throws {
        let fake = FakeDataSource()
        var caller = Self.caller(dataSource: fake)
        caller.isRemotePane = true
        XCTAssertThrowsError(try service().respond(to: Self.search("cache"), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeUnknown(HistoryIPCMessages.remotePane))
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_scope_unknown")
        }
        caller.isRemotePane = false
        caller.paneCWD = nil
        caller.paneRepoRoot = nil
        XCTAssertThrowsError(try service().respond(to: Self.show("abc"), caller: caller)) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeUnknown(HistoryIPCMessages.noDirectory))
        }
        XCTAssertEqual(fake.calls, [])

        caller.isRemotePane = true
        caller.allowAgentsAllProjects = true
        let response = try XCTUnwrap(try service().respond(to: Self.search("cache", all: true), caller: caller).search)
        XCTAssertEqual(response.scope, "all")
        XCTAssertNil(fake.searchContexts.first?.currentRepositoryKey)
    }

    func test_project_scope_passed_to_data_source_and_reported() throws {
        let fake = FakeDataSource(availability: .ready(complete: false))
        let response = try XCTUnwrap(
            try service().respond(to: Self.search("cache", agent: "codex", limit: 7), caller: Self.caller(dataSource: fake)).search)

        let expected = AgentHistoryScope.project(
            AgentHistoryProjectScope(key: Self.repo, displayName: "app", allowsCWDPrefix: true))
        XCTAssertEqual(fake.searchContexts.map(\.scope), [expected])
        XCTAssertEqual(fake.searchContexts.first?.currentRepositoryKey, Self.repo)
        XCTAssertEqual(fake.searchLimits, [7])
        XCTAssertEqual(fake.searchQueries.first?.filters.agents, [.codex], "--agent is merged into the query")
        XCTAssertEqual(response.scope, "project")
        XCTAssertEqual(response.project, Self.repo)
        XCTAssertFalse(response.complete)
        XCTAssertTrue(response.contentIsUntrusted)
    }

    // MARK: - Search re-checks

    func test_out_of_scope_hits_from_data_source_are_dropped() throws {
        let fake = FakeDataSource()
        fake.hits = [
            Self.hit(Self.summary(id: 1, repo: Self.repo)),
            Self.hit(Self.summary(id: 2, repo: Self.otherRepo)),
            Self.hit(Self.summary(id: 3, cwd: Self.repo + "/sub")),
            Self.hit(Self.summary(id: 4, cwd: Self.repo + "-other")),
        ]
        let response = try XCTUnwrap(try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake)).search)
        XCTAssertEqual(response.results.map(\.sessionId), [Self.nativeID(1), Self.nativeID(3)])
    }

    func test_excluded_cwd_hits_are_dropped_at_query_time() throws {
        let fake = FakeDataSource()
        fake.hits = [
            Self.hit(Self.summary(id: 1, cwd: Self.repo + "/secret/x", repo: Self.repo)),
            Self.hit(Self.summary(id: 2, cwd: Self.repo, repo: Self.repo)),
        ]
        var caller = Self.caller(dataSource: fake)
        caller.exclusions = AgentHistoryExclusionMatcher(folders: [Self.repo + "/secret"])
        let response = try XCTUnwrap(try service().respond(to: Self.search("cache"), caller: caller).search)
        XCTAssertEqual(response.results.map(\.sessionId), [Self.nativeID(2)])
    }

    func test_search_hit_maps_fields_dates_title_cap_and_resume_command() throws {
        let fake = FakeDataSource()
        let longTitle = String(repeating: "t", count: 400)
        let session = Self.summary(id: 1, cwd: Self.repo, repo: Self.repo, branch: "main", title: longTitle,
                                   updatedAtMs: 1_793_534_400_000)
        fake.hits = [HistoryIPCSearchHit(
            session: session,
            match: .content(role: "user", at: "2026-11-01T12:00:00Z", snippet: "…the cache…"))]
        let hit = try XCTUnwrap(
            try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake)).search?.results.first)

        XCTAssertEqual(hit.agent, "claude")
        XCTAssertEqual(hit.sessionId, Self.nativeID(1))
        XCTAssertEqual(hit.title.count, HistoryIPCService.maxTitleCharacters)
        XCTAssertTrue(hit.title.hasSuffix("…"))
        XCTAssertEqual(hit.cwd, Self.repo)
        XCTAssertEqual(hit.branch, "main")
        XCTAssertEqual(hit.updatedAt, "2026-11-01T12:00:00Z")
        XCTAssertEqual(hit.match, .content(role: "user", at: "2026-11-01T12:00:00Z", snippet: "…the cache…"))
        XCTAssertEqual(hit.resumeCommand, "claude --resume \(Self.nativeID(1))")
    }

    func test_live_flag_comes_from_caller_snapshot() throws {
        let fake = FakeDataSource()
        let live = Self.summary(id: 1, repo: Self.repo)
        let idle = Self.summary(id: 2, repo: Self.repo)
        fake.hits = [Self.hit(live), Self.hit(idle)]
        fake.sessionsByID = [live.nativeID: [live]]
        fake.turnPage = HistoryIPCTurnPage(turns: [], total: 0)
        var caller = Self.caller(dataSource: fake)
        caller.liveKeys = [live.key]

        let hits = try XCTUnwrap(try service().respond(to: Self.search("cache"), caller: caller).search?.results)
        XCTAssertEqual(hits.map(\.live), [true, false])
        let shown = try XCTUnwrap(try service().respond(to: Self.show(live.nativeID), caller: caller).show)
        XCTAssertTrue(shown.live)
    }

    func test_search_cancels_after_four_second_deadline() {
        let fake = FakeDataSource()
        let fired = Box<(@Sendable () -> Void)?>(nil)
        let intervals = Box<[TimeInterval]>([])
        let cancelled = Box(0)
        var service = service()
        service.scheduleDeadline = { interval, handler in
            intervals.value.append(interval)
            fired.value = handler
            return { cancelled.value += 1 }
        }
        fake.onSearch = { cancellation in
            XCTAssertFalse(cancellation.isCancelled)
            fired.value?()      // the deadline passes mid-query
            if cancellation.isCancelled {
                throw HistorySearchError.cancelled
            }
        }

        XCTAssertThrowsError(try service.respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .timedOut)
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "history_timeout")
            XCTAssertEqual(($0 as? HistoryIPCError)?.errorDescription, HistoryIPC.timeoutMessage)
        }
        XCTAssertEqual(intervals.value, [4])
        XCTAssertEqual(cancelled.value, 1, "the deadline timer is always cancelled")
    }

    func test_indexed_sessions_counts_scope_only() throws {
        let fake = FakeDataSource()
        fake.counts = [.all: 120]
        fake.defaultCount = 9
        let response = try XCTUnwrap(try service().respond(to: Self.search("cache"), caller: Self.caller(dataSource: fake)).search)
        XCTAssertEqual(response.indexedSessions, 9)
        guard case .project(let project)? = fake.countScopes.first else {
            return XCTFail("expected a project-scoped count, got \(fake.countScopes)")
        }
        XCTAssertEqual(project.key, Self.repo)
    }

    // MARK: - Show

    func test_show_out_of_scope_session_is_not_found_with_neutral_message() {
        let fake = FakeDataSource()
        let elsewhere = Self.summary(id: 1, repo: Self.otherRepo)
        fake.sessionsByID = [elsewhere.nativeID: [elsewhere]]
        XCTAssertThrowsError(try service().respond(to: Self.show(elsewhere.nativeID), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .notFound(elsewhere.nativeID))
            XCTAssertEqual(($0 as? HistoryIPCError)?.ipcCode, "not_found")
            XCTAssertEqual(
                ($0 as? HistoryIPCError)?.errorDescription,
                "No session \(elsewhere.nativeID) in this project's Agent History.")
        }
        XCTAssertEqual(fake.turnRequests, [], "no turns are read for a session the caller can't see")
    }

    func test_show_unknown_session_is_not_found() {
        let fake = FakeDataSource()
        XCTAssertThrowsError(try service().respond(to: Self.show("missing"), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .notFound("missing"))
        }

        // The index refuses the session it picked (gone, or no longer the same session).
        let session = Self.summary(id: 1, repo: Self.repo)
        fake.sessionsByID = [session.nativeID: [session]]
        fake.turnError = HistorySearchError.sessionNotFound
        XCTAssertThrowsError(try service().respond(to: Self.show(session.nativeID), caller: Self.caller(dataSource: fake))) {
            XCTAssertEqual($0 as? HistoryIPCError, .notFound(session.nativeID))
        }
    }

    func test_show_picks_most_recently_updated_duplicate() throws {
        let fake = FakeDataSource()
        let id = Self.nativeID(1)
        let older = Self.summary(id: 10, nativeID: id, repo: Self.repo, updatedAtMs: 1_000)
        let newer = Self.summary(id: 11, nativeID: id, repo: Self.repo, updatedAtMs: 5_000)
        let tieLow = Self.summary(id: 20, nativeID: id, repo: Self.repo, updatedAtMs: 9_000)
        let tieHigh = Self.summary(id: 21, nativeID: id, repo: Self.repo, updatedAtMs: 9_000)
        let excludedNewest = Self.summary(id: 30, nativeID: id, cwd: Self.repo + "/secret", repo: Self.repo,
                                          updatedAtMs: 99_000)
        fake.turnPage = HistoryIPCTurnPage(turns: [], total: 0)
        var caller = Self.caller(dataSource: fake)
        caller.exclusions = AgentHistoryExclusionMatcher(folders: [Self.repo + "/secret"])

        fake.sessionsByID = [id: [older, newer]]
        _ = try service().respond(to: Self.show(id), caller: caller)
        fake.sessionsByID = [id: [tieHigh, tieLow, excludedNewest]]
        _ = try service().respond(to: Self.show(id, agent: "claude"), caller: caller)

        XCTAssertEqual(fake.turnRequests.map(\.sessionRowID), [11, 20])
        XCTAssertEqual(fake.sessionAgents, [nil, .claude])
    }

    func test_show_returns_requested_turns_newest_last_with_4kb_cap() throws {
        let fake = FakeDataSource()
        let session = Self.summary(id: 1, repo: Self.repo, branch: "main", model: "opus", effort: "high")
        fake.sessionsByID = [session.nativeID: [session]]
        let long = String(repeating: "é", count: 3_000)      // 6,000 bytes
        fake.turnPage = HistoryIPCTurnPage(
            turns: [
                HistoryIPCTurnRecord(role: .user, atMs: 1_793_534_400_000, text: "first"),
                HistoryIPCTurnRecord(role: .agent, atMs: 1_793_534_460_000, text: long),
                HistoryIPCTurnRecord(role: .user, atMs: 1_793_534_520_000, text: "last"),
            ],
            total: 12
        )

        let shown = try XCTUnwrap(
            try service().respond(to: Self.show(session.nativeID, turns: 3), caller: Self.caller(dataSource: fake)).show)
        XCTAssertEqual(fake.turnRequests.first?.limit, 3)
        XCTAssertEqual(shown.turns.map(\.role), ["user", "agent", "user"])
        XCTAssertEqual(shown.turns.map(\.at), ["2026-11-01T12:00:00Z", "2026-11-01T12:01:00Z", "2026-11-01T12:02:00Z"])
        XCTAssertEqual(shown.turns.first?.text, "first")
        XCTAssertEqual(shown.turns.last?.text, "last")
        XCTAssertEqual(shown.turns[1].text.utf8.count, HistoryIPC.maxTurnBytes)
        XCTAssertTrue(shown.turns[1].truncated)
        XCTAssertFalse(shown.turns[0].truncated)
        XCTAssertEqual(shown.totalTurns, 12)
        XCTAssertEqual(shown.omittedTurns, 9)
        XCTAssertEqual(shown.scope, "project")
        XCTAssertEqual(shown.project, Self.repo)
        XCTAssertEqual(shown.agent, "claude")
        XCTAssertEqual(shown.branch, "main")
        XCTAssertEqual(shown.model, "opus")
        XCTAssertEqual(shown.effort, "high")
        XCTAssertNotNil(shown.resumeCommand)
        XCTAssertTrue(shown.contentIsUntrusted)
    }

    // MARK: - Fixtures

    private func service() -> HistoryIPCService {
        var service = HistoryIPCService()
        service.homeDirectory = Self.home
        service.identity = { _ in nil }
        service.now = { Date(timeIntervalSince1970: 1_793_534_400) }
        // Never fires on its own: only the deadline test triggers it.
        service.scheduleDeadline = { _, _ in {} }
        return service
    }

    private static func caller(
        dataSource: (any HistoryIPCDataSource)?,
        allowAll: Bool = false
    ) -> HistoryIPCCaller {
        HistoryIPCCaller(
            paneCWD: repo + "/Sources",
            paneRepoRoot: repo,
            isRemotePane: false,
            allowAgentsAllProjects: allowAll,
            liveKeys: [],
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            dataSource: dataSource
        )
    }

    private static func search(_ query: String, all: Bool = false, agent: String? = nil, limit: Int = 10) -> HistoryIPCCommand {
        .search(HistorySearchIPCOptions(query: query, allProjects: all, agent: agent, limit: limit))
    }

    private static func show(_ id: String, all: Bool = false, agent: String? = nil, turns: Int = 20) -> HistoryIPCCommand {
        .show(HistoryShowIPCOptions(sessionID: id, allProjects: all, agent: agent, turns: turns))
    }

    private static func nativeID(_ id: Int64) -> String {
        String(format: "3f2a9c1e-6d1b-4c7e-9a2f-%012d", id)
    }

    private static func summary(
        id: Int64,
        nativeID: String? = nil,
        cwd: String? = nil,
        repo: String? = nil,
        branch: String? = nil,
        title: String = "A session",
        model: String? = nil,
        effort: String? = nil,
        updatedAtMs: Int64 = 1_793_534_400_000
    ) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "", agent: .claude, nativeID: nativeID ?? Self.nativeID(id),
            title: title, titleKind: .custom, cwd: cwd, repoRoot: repo, mainRepoRoot: repo, branch: branch,
            model: model, effort: effort, createdAtMs: updatedAtMs - 60_000, updatedAtMs: updatedAtMs, turnCount: 2)
    }

    private static func hit(_ session: AgentHistorySessionSummary) -> HistoryIPCSearchHit {
        HistoryIPCSearchHit(session: session, match: .metadata(field: "title", value: session.title))
    }
}

/// Thread-safe holder; the tests mutate it from deadline and data-source closures.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Records every call. Used from the test thread only.
private final class FakeDataSource: HistoryIPCDataSource, @unchecked Sendable {
    struct TurnRequest: Equatable {
        let sessionRowID: Int64
        let limit: Int
    }

    var availabilityValue: HistoryIPCAvailability
    var hits: [HistoryIPCSearchHit] = []
    var searchError: Error?
    var onSearch: ((HistorySearchCancellation) throws -> Void)?
    var counts: [AgentHistoryScope: Int] = [:]
    var defaultCount = 0
    var sessionsByID: [String: [AgentHistorySessionSummary]] = [:]
    var turnPage = HistoryIPCTurnPage(turns: [], total: 0)
    var turnError: Error?

    private(set) var calls: [String] = []
    private(set) var searchContexts: [HistorySearchContext] = []
    private(set) var searchQueries: [HistoryQuery] = []
    private(set) var searchLimits: [Int] = []
    private(set) var countScopes: [AgentHistoryScope] = []
    private(set) var sessionAgents: [AgentHistoryAgent?] = []
    private(set) var turnRequests: [TurnRequest] = []

    init(availability: HistoryIPCAvailability = .ready(complete: true)) {
        availabilityValue = availability
    }

    func availability() -> HistoryIPCAvailability {
        availabilityValue
    }

    func visibleSessionCount(scope: AgentHistoryScope) throws -> Int {
        calls.append("count")
        countScopes.append(scope)
        return counts[scope] ?? defaultCount
    }

    func search(
        query: HistoryQuery,
        context: HistorySearchContext,
        limit: Int,
        cancellation: HistorySearchCancellation
    ) throws -> [HistoryIPCSearchHit] {
        calls.append("search")
        searchQueries.append(query)
        searchContexts.append(context)
        searchLimits.append(limit)
        try onSearch?(cancellation)
        if let searchError {
            throw searchError
        }
        return hits
    }

    func show(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        limit: Int,
        choose: ([AgentHistorySessionSummary]) -> AgentHistorySessionSummary?
    ) throws -> HistoryIPCShowPage? {
        calls.append("sessions")
        sessionAgents.append(agent)
        guard let session = choose(sessionsByID[nativeID] ?? []) else { return nil }
        calls.append("turns")
        turnRequests.append(TurnRequest(sessionRowID: session.id, limit: limit))
        if let turnError {
            throw turnError
        }
        return HistoryIPCShowPage(session: session, page: turnPage)
    }
}
