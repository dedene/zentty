import Foundation
import XCTest
@testable import Zentty

/// Access narrowed while a `zentty history` request is in flight: an agent turned off, a folder
/// excluded or a session removed after the metadata tier ran (search) or after the session was
/// read (show). The reply must follow the rules as they stand when it leaves, not as they stood
/// when the request started.
final class HistoryIPCAccessNarrowingTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private static let repo = "/work/app"
    private static let secret = "/work/app/secret"

    private enum Narrowing: CaseIterable {
        case agentTurnedOff
        case folderExcluded
        case sessionRemoved
    }

    // MARK: - Search

    func test_search_drops_metadata_hits_narrowed_while_content_search_runs() throws {
        for narrowing in Narrowing.allCases {
            let fixture = try Fixture(testCase: self)
            try addSession(fixture, "kept", repo: Self.repo, text: "the needle is in this message")
            let narrowed = try addNarrowedSession(fixture, narrowing)
            let narrow = try narrowingAction(fixture, narrowing, session: narrowed)

            // The metadata tier has already listed `narrowed` (its title matches) when the
            // content tier grades its first row.
            let once = Fixture.Box(false)
            var tuning = HistorySearchEngine.Tuning()
            tuning.willGradeRow = {
                guard !once.value else { return }
                once.set(true)
                narrow()
            }
            let engine = try fixture.engine(tuning: tuning)

            let response = try XCTUnwrap(try service(fixture).respond(
                to: .search(HistorySearchIPCOptions(query: "needle")),
                caller: caller(dataSource(engine))
            ).search)
            XCTAssertTrue(once.value, "\(narrowing): precondition, the content tier graded a row")
            XCTAssertEqual(response.results.map(\.sessionId), ["kept"], "\(narrowing)")
        }
    }

    // MARK: - Show

    func test_show_refuses_a_session_narrowed_after_its_turns_were_read() throws {
        for narrowing in Narrowing.allCases {
            let fixture = try Fixture(testCase: self)
            let narrowed = try addNarrowedSession(fixture, narrowing)
            let engine = try fixture.engine()
            let racing = RacingIPCDataSource(base: dataSource(engine))
            racing.afterShow = try narrowingAction(fixture, narrowing, session: narrowed)

            XCTAssertThrowsError(try service(fixture).respond(
                to: .show(HistoryShowIPCOptions(sessionID: "narrowed")), caller: caller(racing))
            ) {
                XCTAssertEqual($0 as? HistoryIPCError, .notFound("narrowed"), "\(narrowing)")
            }
            XCTAssertNil(racing.afterShow, "\(narrowing): precondition, the session was read first")
        }
    }

    func test_show_still_returns_a_session_nobody_narrowed() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "kept", repo: Self.repo, text: "hello")
        let engine = try fixture.engine()

        let shown = try XCTUnwrap(try service(fixture).respond(
            to: .show(HistoryShowIPCOptions(sessionID: "kept")), caller: caller(dataSource(engine))).show)
        XCTAssertEqual(shown.sessionId, "kept")
        XCTAssertEqual(shown.turns.map(\.text), ["hello"])
    }

    // MARK: - All projects and History off

    func test_all_projects_is_refused_when_the_setting_goes_off_mid_request() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "kept", repo: Self.repo, text: "the needle is in this message")
        let allowsAll = Fixture.Box(true)
        var tuning = HistorySearchEngine.Tuning()
        tuning.willGradeRow = { allowsAll.set(false) }
        let engine = try fixture.engine(tuning: tuning)

        XCTAssertThrowsError(try service(fixture).respond(
            to: .search(HistorySearchIPCOptions(query: "needle", allProjects: true)),
            caller: caller(dataSource(engine, allowsAll: allowsAll)))
        ) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeDenied)
        }

        allowsAll.set(true)
        let racing = RacingIPCDataSource(base: dataSource(try fixture.engine(), allowsAll: allowsAll))
        racing.afterShow = { allowsAll.set(false) }
        XCTAssertThrowsError(try service(fixture).respond(
            to: .show(HistoryShowIPCOptions(sessionID: "kept", allProjects: true)), caller: caller(racing))
        ) {
            XCTAssertEqual($0 as? HistoryIPCError, .scopeDenied)
        }
    }

    func test_history_turned_off_mid_request_answers_disabled() throws {
        let fixture = try Fixture(testCase: self)
        try addSession(fixture, "kept", repo: Self.repo, text: "hello")
        let status = Fixture.Box(Self.readyStatus)
        let racing = RacingIPCDataSource(base: dataSource(try fixture.engine(), status: status))
        // A filter-only query never reaches the reader pool, so nothing else would notice.
        racing.afterSearch = { status.set(.off) }

        XCTAssertThrowsError(try service(fixture).respond(
            to: .search(HistorySearchIPCOptions(query: "agent:claude")), caller: caller(racing))
        ) {
            XCTAssertEqual($0 as? HistoryIPCError, .disabled)
        }
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

    /// A session only the metadata tier finds for "needle" (its title), in the folder, agent
    /// and key the narrowing hides.
    private func addNarrowedSession(_ fixture: Fixture, _ narrowing: Narrowing) throws -> Int64 {
        try addSession(
            fixture, "narrowed",
            agent: narrowing == .agentTurnedOff ? .codex : .claude,
            title: "Needle plan",
            cwd: narrowing == .folderExcluded ? Self.secret : Self.repo,
            text: "hello")
    }

    private func narrowingAction(
        _ fixture: Fixture,
        _ narrowing: Narrowing,
        session: Int64
    ) throws -> @Sendable () -> Void {
        switch narrowing {
        case .agentTurnedOff:
            let agents = fixture.enabledAgents
            return { agents.set(Set(AgentHistoryAgent.allCases).subtracting([.codex])) }
        case .folderExcluded:
            let exclusions = fixture.exclusions
            return { exclusions.set(AgentHistoryExclusionMatcher(folders: [Self.secret])) }
        case .sessionRemoved:
            return {
                do {
                    try fixture.store().addTombstone(
                        AgentHistorySessionKey(agent: .claude, nativeID: "narrowed"), removedAtMs: 1)
                } catch {
                    XCTFail("removing the session failed: \(error)")
                }
            }
        }
    }

    @discardableResult
    private func addSession(
        _ fixture: Fixture,
        _ nativeID: String,
        agent: AgentHistoryAgent = .claude,
        title: String? = nil,
        cwd: String? = nil,
        repo: String = HistoryIPCAccessNarrowingTests.repo,
        text: String
    ) throws -> Int64 {
        let id = try fixture.addSession(
            nativeID, agent: agent, title: title ?? "Session \(nativeID)", cwd: cwd ?? repo, repo: repo,
            mainRepo: repo, updatedDaysAgo: 1)
        try fixture.addMessage(session: id, daysAgo: 1, text: text)
        return id
    }

    private func dataSource(
        _ engine: HistorySearchEngine,
        status: Fixture.Box<AgentHistoryStatus> = Fixture.Box(HistoryIPCAccessNarrowingTests.readyStatus),
        allowsAll: Fixture.Box<Bool> = Fixture.Box(true)
    ) -> AgentHistoryIPCDataSource {
        AgentHistoryIPCDataSource(
            status: { status.value }, engine: { engine }, allowsAllProjects: { allowsAll.value })
    }

    private func service(_ fixture: Fixture) -> HistoryIPCService {
        var service = HistoryIPCService()
        service.homeDirectory = "/Users/tester"
        service.identity = { _ in nil }
        let now = fixture.now
        service.now = { now }
        service.scheduleDeadline = { _, _ in {} }
        return service
    }

    /// The request started before anything was narrowed: its exclusions snapshot is empty.
    private func caller(_ dataSource: any HistoryIPCDataSource) -> HistoryIPCCaller {
        HistoryIPCCaller(
            paneCWD: Self.repo,
            paneRepoRoot: Self.repo,
            isRemotePane: false,
            allowAgentsAllProjects: true,
            liveKeys: [],
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            dataSource: dataSource
        )
    }
}

/// Runs `afterSearch` or `afterShow` once, right after the base data source answered.
private final class RacingIPCDataSource: HistoryIPCDataSource, @unchecked Sendable {
    let base: AgentHistoryIPCDataSource
    var afterSearch: (() -> Void)?
    var afterShow: (() -> Void)?

    init(base: AgentHistoryIPCDataSource) {
        self.base = base
    }

    func availability() -> HistoryIPCAvailability { base.availability() }

    func allowsAllProjects() -> Bool { base.allowsAllProjects() }

    func visibleSessionIDs(among sessions: [AgentHistorySessionSummary]) throws -> Set<Int64> {
        try base.visibleSessionIDs(among: sessions)
    }

    func visibleSessionCount(scope: AgentHistoryScope) throws -> Int {
        try base.visibleSessionCount(scope: scope)
    }

    func search(
        query: HistoryQuery,
        context: HistorySearchContext,
        limit: Int,
        cancellation: HistorySearchCancellation
    ) throws -> [HistoryIPCSearchHit] {
        let hits = try base.search(query: query, context: context, limit: limit, cancellation: cancellation)
        let race = afterSearch
        afterSearch = nil
        race?()
        return hits
    }

    func show(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        limit: Int,
        choose: ([AgentHistorySessionSummary]) -> AgentHistorySessionSummary?
    ) throws -> HistoryIPCShowPage? {
        let page = try base.show(nativeID: nativeID, agent: agent, scope: scope, limit: limit, choose: choose)
        let race = afterShow
        afterShow = nil
        race?()
        return page
    }
}
