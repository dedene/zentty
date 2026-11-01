import Foundation
import XCTest
@testable import Zentty

/// The content tier resolves a project scope, `repo:` and `branch:` into admitted session ids
/// once per query and gates the FTS walk on them (`HistoryContentQuery.SessionGate`). These
/// tests pin that the gate is only a faster route to the same rows as the per-row filters.
final class HistoryContentSessionGateTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture
    private typealias Query = HistoryContentQuery
    private typealias Route = HistorySearchEngine.ContentRoute

    /// Sessions across repos, worktrees, repo-less folders, branches (with Unicode case and
    /// normalization variants), agents and the invisible kinds (child, zero turns).
    private func populate(_ fixture: Fixture) throws {
        let specs: [(id: String, agent: AgentHistoryAgent, cwd: String?, repo: String?, main: String?, branch: String?)] = [
            ("app-main", .claude, "/repos/app", "/repos/app", "/repos/app", "main"),
            ("app-tree", .codex, "/repos/app-worktrees/feat-x", "/repos/app-worktrees/feat-x", "/repos/app", "feat/x"),
            ("app-sub", .claude, "/repos/app/Sources", "/repos/app", "/repos/app", "FEATURE/Écran"),
            ("cafe-nfd", .grok, "/repos/Cafe\u{0301}", "/repos/Cafe\u{0301}", "/repos/Cafe\u{0301}", "fe\u{0301}ature/menu"),
            ("cafe-upper", .opencode, "/other/CAFÉ", "/other/CAFÉ", "/other/CAFÉ", "main"),
            ("lib", .codex, "/repos/lib", "/repos/lib", "/repos/lib", nil),
            ("loose", .claude, "/repos/app/notes", nil, nil, "main"),
            ("loose-elsewhere", .grok, "/scratch/app", nil, nil, nil),
        ]
        for (index, spec) in specs.enumerated() {
            let session = try fixture.addSession(
                spec.id, agent: spec.agent, cwd: spec.cwd, repo: spec.repo, mainRepo: spec.main,
                branch: spec.branch, updatedDaysAgo: Double(index + 1))
            for turn in 0..<3 {
                try fixture.addMessage(
                    session: session, role: turn.isMultiple(of: 2) ? .user : .agent,
                    daysAgo: Double(index + 1) + Double(turn) / 100, text: "deploy the cache turn \(turn)")
            }
            try fixture.addArtifact(session: session, kind: .path, value: "src/deploy/\(spec.id).swift",
                                    daysAgo: Double(index + 1))
        }
        let child = try fixture.addSession("child", cwd: "/repos/app", repo: "/repos/app", mainRepo: "/repos/app",
                                           parent: "app-main")
        try fixture.addMessage(session: child, daysAgo: 1, text: "deploy the cache in a child")
        try fixture.addSession("empty", cwd: "/repos/app", repo: "/repos/app", mainRepo: "/repos/app")
    }

    /// Every session-level filter shape the content tier can see.
    private static var filterMatrix: [(name: String, filters: Query.Filters)] {
        [
            ("project", Query.Filters(scope: Fixture.projectScope("/repos/app"))),
            ("project without prefix", Query.Filters(scope: Fixture.projectScope("/repos/app", allowsCWDPrefix: false))),
            ("repo name", Query.Filters(repoNames: ["app"])),
            ("repo name, other case", Query.Filters(repoNames: ["APP"])),
            ("repo name, NFC vs NFD", Query.Filters(repoNames: ["CAFÉ"])),
            ("repo name, worktree basename", Query.Filters(repoNames: ["feat-x"])),
            ("repo path", Query.Filters(repoNames: ["/repos/lib"])),
            ("repo names", Query.Filters(repoNames: ["lib", "missing"])),
            ("branch", Query.Filters(branches: ["feat"])),
            ("branch, Unicode case", Query.Filters(branches: ["écran"])),
            ("branch, NFD vs NFC", Query.Filters(branches: ["FÉATURE"])),
            ("agents", Query.Filters(agents: [.claude, .grok], repoNames: ["app", "café"])),
            ("all", Query.Filters(agents: [.claude, .codex], repoNames: ["app"], branches: ["feat", "main"],
                                  scope: Fixture.projectScope("/repos/app"))),
            ("nothing", Query.Filters(repoNames: ["nowhere"])),
        ]
    }

    func test_admitted_sessions_equal_the_per_row_session_filters() throws {
        let fixture = try Fixture(testCase: self)
        try populate(fixture)
        let db = try fixture.writer

        for (name, filters) in Self.filterMatrix {
            XCTAssertTrue(filters.restrictsSessions, name)
            let admitted = Query.admittedSessions(filters: filters)
            let gated = Set(try db.query(admitted.sql, admitted.bindings) { $0.int64(0) })

            var bindings: [AgentHistoryValue] = []
            let conditions = Query.filterConditions(filters, row: "m", bindings: &bindings)
            let perRow = Set(try db.query(
                "SELECT s.id FROM sessions s WHERE " + conditions.joined(separator: " AND "), bindings) { $0.int64(0) })
            XCTAssertEqual(gated, perRow, name)
        }
    }

    func test_gated_statements_return_the_per_row_rows_in_order() throws {
        for tokenizer in [AgentHistoryTokenizer.trigram, .unicode61] {
            let fixture = try Fixture(testCase: self, tokenizer: tokenizer)
            try populate(fixture)
            let db = try fixture.writer
            let match = tokenizer == .trigram ? "\"deploy\"" : "\"deploy\"*"

            for (name, base) in Self.filterMatrix {
                let admitted = Query.admittedSessions(filters: base)
                let ids = try db.query(admitted.sql, admitted.bindings) { $0.int64(0) }
                for limit in [2, 100] {
                    for statement in [Query.messages, Query.artifacts] {
                        func rows(_ gate: Query.SessionGate) throws -> [Int64] {
                            var filters = base
                            filters.gate = gate
                            let built = statement(match, filters, limit)
                            return try db.query(built.sql, built.bindings) { $0.int64(0) }
                        }
                        let label = "\(tokenizer.rawValue) \(name) limit \(limit)"
                        let perRow = try rows(.perRow)
                        XCTAssertEqual(try rows(.sessions(ids)), perRow, "sessions gate, \(label)")
                        XCTAssertEqual(try rows(.contentRowIDs(ids)), perRow, "row id gate, \(label)")
                    }
                }
            }
        }
    }

    func test_substring_scan_finds_the_trigram_walk_rows() throws {
        let fixture = try Fixture(testCase: self, tokenizer: .trigram)
        try populate(fixture)
        let texts = [
            "Refactor the PARSER module", "Café crème résumé", "Le\u{0301}gende de l'e\u{0301}clair",
            "She said \u{201C}ship it\u{201D} twice", "ＦＵＬＬＷＩＤＴＨ ｓｅａｒｃｈ", "漢字の検索テスト",
            "deploy the cache key", "a \"quoted\" deploy",
        ]
        let session = try fixture.addSession("texts", cwd: "/repos/app", repo: "/repos/app", mainRepo: "/repos/app")
        for (index, text) in texts.enumerated() {
            try fixture.addMessage(session: session, daysAgo: 0.5 - Double(index) / 100, text: text)
        }
        let db = try fixture.writer

        for raw in ["deploy", "deploy cache", "parser", "CAFE", "légende", "\"ship it\"", "fullwidth", "検索テ",
                    "\"quoted\" deploy", "turn 1", "after:2026-10-30 deploy", "deploy ca"] {
            let query = Fixture.query(raw)
            let plan = HistoryMatchPlan.make(query: query, tokenizer: .trigram)
            let match = try XCTUnwrap(plan.matchExpression, raw)
            for (name, base) in Self.filterMatrix {
                var filters = Query.Filters(
                    query: query, plan: plan, scope: base.scope, enabledAgents: Set(AgentHistoryAgent.allCases))
                filters.agents = base.agents.isEmpty ? filters.agents : base.agents
                filters.repoNames = base.repoNames
                filters.branches = base.branches
                let admitted = Query.admittedSessions(filters: filters)
                filters.gate = .sessions(try db.query(admitted.sql, admitted.bindings) { $0.int64(0) })
                for limit in [1, 100] {
                    let walk = Query.messages(match: match, filters: filters, limit: limit)
                    let walked = try db.query(walk.sql, walk.bindings) { $0.int64(0) }
                    let scan = Query.substringScan(terms: plan.ftsTerms, filters: filters)
                    let scanned = try db.query(scan.sql, scan.bindings) { $0.int64(0) }.sorted(by: >).prefix(limit)
                    XCTAssertEqual(Array(scanned), walked, "\(raw), \(name), limit \(limit)")
                }
            }
        }
    }

    /// The tunings that force each route of a restricted trigram search, with the route each
    /// must take, so the route-equivalence tests cannot pass by all taking the same path.
    private static func routeTunings() -> [(tuning: HistorySearchEngine.Tuning, route: Route)] {
        var rowIDs = HistorySearchEngine.Tuning()
        rowIDs.rowIDGateTurnLimit = .max
        rowIDs.substringScanMessageLimit = 0
        var sessions = HistorySearchEngine.Tuning()
        sessions.rowIDGateTurnLimit = 0
        sessions.substringScanMessageLimit = 0
        var substrings = HistorySearchEngine.Tuning()
        substrings.substringScanMessageLimit = .max
        return [
            (rowIDs, Route(gate: .contentRowIDs, messages: .ftsWalk)),
            (sessions, Route(gate: .sessions, messages: .ftsWalk)),
            (substrings, Route(gate: .contentRowIDs, messages: .substringScan)),
        ]
    }

    /// Runs `raw` once per route tuning and asserts each took its route; returns the responses
    /// in `routeTunings()` order.
    private func searchEveryRoute(
        _ raw: String,
        scope: AgentHistoryScope,
        fixture: Fixture,
        admitsSessions: Bool = true,
        adjust: (inout HistorySearchEngine.Tuning) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [HistoryContentResponse] {
        try Self.routeTunings().map { tuning, expected in
            var tuning = tuning
            adjust(&tuning)
            let routes = Fixture.Box<[Route]>([])
            tuning.didChooseRoute = { route in routes.set(routes.value + [route]) }
            let response = try fixture.engine(tuning: tuning).searchContent(
                Fixture.query(raw), context: fixture.context(scope), excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            XCTAssertEqual(routes.value, admitsSessions ? [expected] : [], "route of \(raw)", file: file, line: line)
            return response
        }
    }

    func test_every_route_gives_the_same_search_results() throws {
        let fixture = try Fixture(testCase: self)
        try populate(fixture)

        let cases: [(raw: String, scope: AgentHistoryScope, expected: Set<String>)] = [
            ("deploy", Fixture.projectScope("/repos/app"), ["app-main", "app-tree", "app-sub", "loose"]),
            ("repo:app deploy", .all, ["app-main", "app-tree", "app-sub"]),
            ("repo:café deploy", .all, ["cafe-nfd", "cafe-upper"]),
            ("branch:écran deploy", .all, ["app-sub"]),
            ("agent:codex repo:app deploy", .all, ["app-tree"]),
            ("repo:nowhere deploy", .all, []),
        ]
        for (raw, scope, expected) in cases {
            let results = try searchEveryRoute(raw, scope: scope, fixture: fixture, admitsSessions: !expected.isEmpty)
            XCTAssertEqual(Set(results[0].results.map(\.session.nativeID)), expected, raw)
            XCTAssertEqual(results[0], results[1].withElapsed(results[0].elapsed), "session gate, \(raw)")
            XCTAssertEqual(results[0], results[2].withElapsed(results[0].elapsed), "substring scan, \(raw)")
        }
    }

    func test_unrestricted_and_non_trigram_searches_take_the_per_row_walk_or_the_scan() throws {
        let trigram = try Fixture(testCase: self)
        try populate(trigram)
        var substrings = HistorySearchEngine.Tuning()
        substrings.substringScanMessageLimit = .max
        func route(_ fixture: Fixture, _ raw: String, scope: AgentHistoryScope = .all) throws -> [Route] {
            var tuning = substrings
            let routes = Fixture.Box<[Route]>([])
            tuning.didChooseRoute = { route in routes.set(routes.value + [route]) }
            _ = try fixture.engine(tuning: tuning).searchContent(
                Fixture.query(raw), context: fixture.context(scope), excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            return routes.value
        }

        XCTAssertEqual(try route(trigram, "deploy"), [Route(gate: .perRow, messages: .ftsWalk)])
        XCTAssertEqual(try route(trigram, "agent:claude deploy"), [Route(gate: .perRow, messages: .ftsWalk)])
        XCTAssertEqual(try route(trigram, "repo:nowhere deploy"), [], "nothing admitted, nothing walked")

        let unicode = try Fixture(testCase: self, tokenizer: .unicode61)
        try populate(unicode)
        XCTAssertEqual(try route(unicode, "repo:app deploy"), [Route(gate: .contentRowIDs, messages: .ftsWalk)],
                       "the substring scan is a trigram MATCH stand-in only")

        let none = try Fixture(testCase: self, tokenizer: .none)
        try populate(none)
        XCTAssertEqual(try route(none, "repo:app deploy"), [Route(gate: .contentRowIDs, messages: .scanFallback)])
    }

    /// The substring scan reads every message of the admitted sessions, so its gate counts
    /// messages: a project of one prompt and a long autonomous run is not "small" because it
    /// has few turns.
    func test_substring_scan_gate_counts_messages_not_turns() throws {
        let fixture = try Fixture(testCase: self)
        let run = try fixture.addSession("run", cwd: "/repos/run", repo: "/repos/run", mainRepo: "/repos/run",
                                         updatedDaysAgo: 1)
        try fixture.addMessage(session: run, daysAgo: 2, text: "start the deploy run")
        try fixture.addMessages(session: run, role: .agent, startMs: Fixture.ms(daysAgo: 1.5), stepMs: 1_000,
                                texts: (0..<40).map { "deploy step \($0)" })
        let other = try fixture.addSession("other", cwd: "/repos/other", repo: "/repos/other",
                                           mainRepo: "/repos/other", updatedDaysAgo: 1)
        try fixture.addMessage(session: other, daysAgo: 1, text: "deploy elsewhere")
        let db = try fixture.writer
        XCTAssertEqual(try db.scalarInt64("SELECT turn_count FROM sessions WHERE id = ?", [.integer(run)]), 1)

        func search(messageLimit: Int) throws -> (response: HistoryContentResponse, routes: [Route]) {
            var tuning = HistorySearchEngine.Tuning()
            tuning.substringScanMessageLimit = messageLimit
            let routes = Fixture.Box<[Route]>([])
            tuning.didChooseRoute = { route in routes.set(routes.value + [route]) }
            let response = try fixture.engine(tuning: tuning).searchContent(
                Fixture.query("repo:run deploy"), context: fixture.context(), excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            return (response, routes.value)
        }

        let over = try search(messageLimit: 40)
        XCTAssertEqual(over.routes, [Route(gate: .contentRowIDs, messages: .ftsWalk)],
                       "41 messages exceed a 40-message scan although the session has one turn")
        let atLimit = try search(messageLimit: 41)
        XCTAssertEqual(atLimit.routes, [Route(gate: .contentRowIDs, messages: .substringScan)])
        let unlimited = try search(messageLimit: .max)
        XCTAssertEqual(unlimited.routes, [Route(gate: .contentRowIDs, messages: .substringScan)])
        let off = try search(messageLimit: 0)
        XCTAssertEqual(off.routes, [Route(gate: .contentRowIDs, messages: .ftsWalk)])

        XCTAssertEqual(over.response.results.map(\.session.nativeID), ["run"])
        XCTAssertEqual(over.response.results.first?.totalHits, 41)
        XCTAssertEqual(over.response, atLimit.response.withElapsed(over.response.elapsed))
    }

    func test_admitted_message_count_stops_at_the_cap() throws {
        let fixture = try Fixture(testCase: self)
        let first = try fixture.addSession("first")
        try fixture.addMessages(session: first, startMs: Fixture.ms(daysAgo: 2), texts: (0..<7).map { "a \($0)" })
        let second = try fixture.addSession("second")
        try fixture.addMessages(session: second, startMs: Fixture.ms(daysAgo: 1), texts: (0..<5).map { "b \($0)" })
        let third = try fixture.addSession("third")
        try fixture.addMessage(session: third, daysAgo: 1, text: "c")
        let db = try fixture.writer
        func count(_ ids: [Int64], cap: Int64) throws -> Int64? {
            let statement = Query.admittedMessageCount(sessionIDs: ids, cap: cap)
            return try db.scalarInt64(statement.sql, statement.bindings)
        }
        XCTAssertEqual(try count([first, second], cap: -1), 12)
        XCTAssertEqual(try count([first, second], cap: 100), 12)
        XCTAssertEqual(try count([first, second], cap: 8), 8)
        XCTAssertEqual(try count([second], cap: 6), 5)
        XCTAssertEqual(try count([], cap: 6), 0)
    }

    func test_scan_fallback_applies_the_session_gate() throws {
        let fixture = try Fixture(testCase: self, tokenizer: .none)
        try populate(fixture)
        let engine = try fixture.engine()
        for (raw, scope, expected) in [
            ("deploy", Fixture.projectScope("/repos/app"), Set(["app-main", "app-tree", "app-sub", "loose"])),
            ("repo:café deploy", AgentHistoryScope.all, Set(["cafe-nfd", "cafe-upper"])),
            ("branch:main deploy", .all, Set(["app-main", "cafe-upper", "loose"])),
        ] {
            let response = try engine.searchContent(
                Fixture.query(raw), context: fixture.context(scope), excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            XCTAssertEqual(response.mode, .scanFallback, raw)
            XCTAssertEqual(Set(response.results.map(\.session.nativeID)), expected, raw)
        }
    }

    func test_after_bound_keeps_rows_at_the_boundary_whose_ids_spilled() throws {
        let fixture = try Fixture(testCase: self)
        var components = DateComponents(year: 2026, month: 10, day: 20)
        components.timeZone = TimeZone(identifier: "UTC")
        let boundaryMs = Int64(Fixture.utc.date(from: components)!.timeIntervalSince1970 * 1000)
        // More rows than ids in one millisecond: the last ones spill into the next millisecond's
        // ids, which stay above the walk's lower bound.
        let edge = try fixture.addSession("edge", updatedDaysAgo: 1)
        try fixture.addMessages(session: edge, startMs: boundaryMs, stepMs: 0,
                                texts: (0..<1_005).map { "rotate signing key \($0)" })
        let before = try fixture.addSession("before", updatedDaysAgo: 30)
        try fixture.addMessage(session: before, atMs: boundaryMs - 1, text: "rotate signing key")

        var tuning = HistorySearchEngine.Tuning()
        tuning.messageLimit = 2_000
        let response = try fixture.engine(tuning: tuning).searchContent(
            Fixture.query("after:2026-10-20 rotate"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation())
        XCTAssertEqual(response.results.map(\.session.nativeID), ["edge"])
        XCTAssertEqual(response.results.first?.totalHits, 1_005)
    }
}

private extension HistoryContentResponse {
    func withElapsed(_ elapsed: TimeInterval) -> HistoryContentResponse {
        HistoryContentResponse(
            query: query, generation: generation, results: results, enrichments: enrichments, mode: mode,
            truncated: truncated, elapsed: elapsed)
    }
}
