import Foundation
import XCTest
@testable import Zentty

final class HistorySessionQueriesTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    /// user, agent, user, agent … at one-minute steps, ten days ago.
    @discardableResult
    private func addConversation(_ fixture: Fixture, session: Int64, _ texts: [String]) throws -> [Int64] {
        var ids: [Int64] = []
        for (index, text) in texts.enumerated() {
            ids.append(try fixture.addMessage(
                session: session, role: index.isMultiple(of: 2) ? .user : .agent,
                atMs: Fixture.ms(daysAgo: 10) + Int64(index) * 60_000, text: text))
        }
        return ids
    }

    func test_matching_turns_highlights_and_orders_by_seq() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("turns")
        let ids = try addConversation(fixture, session: session, [
            "why is the Cache stale?",
            "the cache key ignores the locale",
            "unrelated question",
            "caches everywhere; fixed the cache key",
        ])

        let turns = try fixture.engine().matchingTurns(sessionID: session, query: Fixture.query("cache"))
        XCTAssertEqual(turns.map(\.messageID), [ids[0], ids[1], ids[3]])
        XCTAssertEqual(turns.map(\.seq), [0, 1, 3])
        XCTAssertEqual(turns.map(\.role), [.user, .agent, .agent])
        XCTAssertEqual(turns[0].highlights, [NSRange(location: 11, length: 5)])
        XCTAssertEqual(turns[1].highlights, [NSRange(location: 4, length: 5)])
        XCTAssertEqual(turns[2].highlights, [NSRange(location: 0, length: 5), NSRange(location: 29, length: 5)])

        let capped = try fixture.engine().matchingTurns(sessionID: session, query: Fixture.query("cache"), limit: 2)
        XCTAssertEqual(capped.map(\.messageID), [ids[0], ids[1]])
    }

    func test_preview_first_prompt_and_latest_reply_without_terms() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("preview", title: "Fix login")
        let ids = try addConversation(fixture, session: session, [
            "the login form rejects valid passwords",
            "looking into it",
            "any luck?",
            "fixed: the hash compared bytes",
        ])
        let engine = try fixture.engine()

        let preview = try engine.preview(sessionID: session, query: Fixture.query(""))
        XCTAssertEqual(preview.session.nativeID, "preview")
        XCTAssertFalse(preview.turnsAreMatches)
        XCTAssertEqual(preview.turns.map(\.messageID), [ids[0], ids[3]])
        XCTAssertEqual(preview.turns.map(\.role), [.user, .agent])
        XCTAssertTrue(preview.turns.allSatisfy(\.highlights.isEmpty))

        let titleOnly = try engine.preview(sessionID: session, query: Fixture.query("fix"))
        XCTAssertTrue(titleOnly.turnsAreMatches, "\"fix\" matches \"fixed\" as a prefix")

        let noTurnMatches = try engine.preview(sessionID: session, query: Fixture.query("zebracorn"))
        XCTAssertFalse(noTurnMatches.turnsAreMatches)
        XCTAssertEqual(noTurnMatches.turns.map(\.messageID), [ids[0], ids[3]])
    }

    func test_preview_matching_turns_with_terms() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("preview")
        let ids = try addConversation(fixture, session: session, [
            "start",
            "the retry budget is exhausted",
            "raise the retry budget",
            "done",
        ])

        let preview = try fixture.engine().preview(sessionID: session, query: Fixture.query("retry budget"))
        XCTAssertTrue(preview.turnsAreMatches)
        XCTAssertEqual(preview.turns.map(\.messageID), [ids[1], ids[2]])
        XCTAssertEqual(preview.turns[0].highlights, [NSRange(location: 4, length: 5), NSRange(location: 10, length: 6)])

        XCTAssertThrowsError(try fixture.engine().preview(sessionID: 999_999, query: Fixture.query("retry"))) {
            XCTAssertEqual($0 as? HistorySearchError, .sessionNotFound)
        }
    }

    func test_transcript_caps_at_2000_latest_and_marks_first_match() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("long")
        var texts = (0..<2_100).map { "turn \($0)" }
        texts[50] = "an early heisenbug note"      // beyond the cap: not loaded
        texts[400] = "the heisenbug shows up again"
        texts[900] = "heisenbug fixed"
        try fixture.addMessages(session: session, startMs: Fixture.ms(daysAgo: 5), stepMs: 1_000, texts: texts)
        let engine = try fixture.engine()

        let transcript = try engine.transcript(sessionID: session, query: Fixture.query("heisenbug"))
        XCTAssertEqual(transcript.turns.count, HistorySearchEngine.transcriptLimit)
        XCTAssertTrue(transcript.isTruncated)
        XCTAssertEqual(transcript.turns.first?.seq, 100)
        XCTAssertEqual(transcript.turns.last?.seq, 2_099)
        XCTAssertEqual(transcript.turns.map(\.seq), Array(100..<2_100), "oldest first")
        let firstMatch = try XCTUnwrap(transcript.firstMatchMessageID)
        XCTAssertEqual(transcript.turns.first { $0.messageID == firstMatch }?.seq, 400)
        XCTAssertEqual(transcript.turns.first { $0.seq == 400 }?.highlights, [NSRange(location: 4, length: 9)])
        XCTAssertEqual(transcript.turns.first { $0.seq == 401 }?.highlights, [])

        let short = try fixture.addSession("short")
        try addConversation(fixture, session: short, ["one", "two"])
        let plain = try engine.transcript(sessionID: short, query: Fixture.query(""))
        XCTAssertFalse(plain.isTruncated)
        XCTAssertNil(plain.firstMatchMessageID)
        XCTAssertEqual(plain.turns.map(\.text), ["one", "two"])
    }

    func test_last_turns_newest_last_with_total() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("tail")
        try addConversation(fixture, session: session, ["a", "b", "c", "d", "e"])
        let engine = try fixture.engine()

        let tail = try engine.lastTurns(sessionID: session, limit: 3)
        XCTAssertEqual(tail.turns.map(\.text), ["c", "d", "e"])
        XCTAssertEqual(tail.total, 5)

        let all = try engine.lastTurns(sessionID: session, limit: 10)
        XCTAssertEqual(all.turns.map(\.text), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(all.total, 5)
    }

    /// A deleted session's row id goes to the next insert. A per-session read by that id must
    /// not pair the old session's summary (still in the metadata snapshot) with the new one's
    /// messages.
    func test_per_session_reads_refuse_a_row_id_reused_by_another_session() throws {
        let fixture = try Fixture(testCase: self)
        let mine = try fixture.addSession("mine", cwd: "/work/app")
        try addConversation(fixture, session: mine, ["my prompt", "my reply"])
        let staleEngine = try fixture.engine()
        try fixture.store().deleteSession(id: mine)
        let theirs = try fixture.addSession("theirs", cwd: "/work/web")
        try addConversation(fixture, session: theirs, ["their prompt", "their reply"])
        XCTAssertEqual(theirs, mine, "precondition: the row id was reused")

        let query = Fixture.query("prompt")
        func assertNotFound<T>(_ name: String, _ read: () throws -> T) {
            XCTAssertThrowsError(try read(), name) {
                XCTAssertEqual($0 as? HistorySearchError, .sessionNotFound, name)
            }
        }
        assertNotFound("preview") { try staleEngine.preview(sessionID: mine, query: query) }
        assertNotFound("transcript") { try staleEngine.transcript(sessionID: mine, query: query) }
        assertNotFound("last turns") { try staleEngine.lastTurns(sessionID: mine, limit: 5) }
        assertNotFound("matching turns") { try staleEngine.matchingTurns(sessionID: mine, query: query) }

        // A fresh snapshot knows the row as "theirs"; the palette row still expects "mine".
        let engine = try fixture.engine()
        let mineKey = AgentHistorySessionKey(agent: .claude, nativeID: "mine")
        let theirsKey = AgentHistorySessionKey(agent: .claude, nativeID: "theirs")
        assertNotFound("preview, expecting mine") { try engine.preview(sessionID: mine, query: query, expecting: mineKey) }
        assertNotFound("transcript, expecting mine") {
            try engine.transcript(sessionID: mine, query: query, expecting: mineKey)
        }
        XCTAssertEqual(try engine.preview(sessionID: theirs, query: query, expecting: theirsKey).session.nativeID, "theirs")
        XCTAssertEqual(try engine.transcript(sessionID: theirs, query: query, expecting: theirsKey).turns.map(\.text),
                       ["their prompt", "their reply"])
    }

    func test_sessions_by_native_id_respect_scope() throws {
        let fixture = try Fixture(testCase: self)
        let claude = try fixture.addSession("shared-id", agent: .claude, cwd: "/repos/app", repo: "/repos/app",
                                            mainRepo: "/repos/app", updatedDaysAgo: 1)
        try fixture.addMessage(session: claude, daysAgo: 1, text: "hello")
        let codex = try fixture.addSession("shared-id", agent: .codex, cwd: "/repos/web", repo: "/repos/web",
                                           mainRepo: "/repos/web", updatedDaysAgo: 3)
        try fixture.addMessage(session: codex, daysAgo: 3, text: "hello")
        let child = try fixture.addSession("child-id", agent: .claude, parent: "shared-id")
        try fixture.addMessage(session: child, daysAgo: 1, text: "hello")
        let engine = try fixture.engine()

        XCTAssertEqual(try engine.sessions(nativeID: "shared-id", agent: nil, scope: .all).map(\.id), [claude, codex])
        XCTAssertEqual(try engine.sessions(nativeID: "shared-id", agent: .codex, scope: .all).map(\.id), [codex])
        XCTAssertEqual(
            try engine.sessions(nativeID: "shared-id", agent: nil, scope: Fixture.projectScope("/repos/web")).map(\.id),
            [codex])
        XCTAssertEqual(try engine.sessions(nativeID: "child-id", agent: nil, scope: .all), [])

        fixture.exclusions.set(AgentHistoryExclusionMatcher(folders: ["/repos/app"]))
        XCTAssertEqual(try engine.sessions(nativeID: "shared-id", agent: nil, scope: .all).map(\.id), [codex])
    }

    func test_visible_session_count_by_scope() throws {
        let fixture = try Fixture(testCase: self)
        for (name, cwd) in [("a1", "/repos/app"), ("a2", "/repos/app/sub"), ("w1", "/repos/web")] {
            let session = try fixture.addSession(name, cwd: cwd)
            try fixture.addMessage(session: session, daysAgo: 1, text: "hi")
        }
        let hidden = try fixture.addSession("no-turns", cwd: "/repos/app")
        try fixture.addMessage(session: hidden, role: .agent, daysAgo: 1, text: "only a reply")
        let engine = try fixture.engine()

        XCTAssertEqual(try engine.visibleSessionCount(scope: .all), 3)
        XCTAssertEqual(try engine.visibleSessionCount(scope: Fixture.projectScope("/repos/app")), 2)
        XCTAssertEqual(try engine.visibleSessionCount(scope: Fixture.projectScope("/repos/app", allowsCWDPrefix: false)), 1)

        fixture.exclusions.set(AgentHistoryExclusionMatcher(folders: ["/repos/app/sub"]))
        XCTAssertEqual(try engine.visibleSessionCount(scope: .all), 2)
        XCTAssertEqual(try engine.visibleSessionCount(scope: Fixture.projectScope("/repos/app")), 1)
    }

    /// Every per-session read goes through the same admission as search: a session the user
    /// cannot see in results never yields its text, even when called by id directly.
    func test_per_session_reads_refuse_hidden_disabled_and_excluded_sessions() throws {
        let fixture = try Fixture(testCase: self)
        let visible = try fixture.addSession("visible", agent: .claude, cwd: "/repos/app")
        try fixture.addMessage(session: visible, daysAgo: 1, text: "rotate the signing key")
        let excluded = try fixture.addSession("excluded", agent: .claude, cwd: "/repos/secret")
        try fixture.addMessage(session: excluded, daysAgo: 1, text: "rotate the signing key")
        let child = try fixture.addSession("child", agent: .claude, parent: "visible")
        try fixture.addMessage(session: child, daysAgo: 1, text: "rotate the signing key")
        let zeroTurns = try fixture.addSession("zero-turns", agent: .claude)
        try fixture.addMessage(session: zeroTurns, role: .agent, daysAgo: 1, text: "rotate the signing key")
        let codexSource = try fixture.addSource(.codex)
        let disabled = try fixture.addSession("disabled-source", agent: .codex)
        try fixture.addMessage(session: disabled, daysAgo: 1, text: "rotate the signing key")
        try fixture.store().setSourceEnabled(id: codexSource, false)
        // The exclusion lands after ingestion: the rows stay until a purge runs.
        fixture.exclusions.set(AgentHistoryExclusionMatcher(folders: ["/repos/secret"]))
        let query = Fixture.query("signing")
        let snapshotEngine = try fixture.engine()
        let sqlEngine = try fixture.engine(
            metadataIndex: HistoryMetadataIndex(snapshot: { .empty }, exclusions: { .init(folders: []) }))

        // Production never has a disabled source's session in the snapshot (the indexer deletes
        // a source's sessions in the transaction that disables it), but the fixture's snapshot
        // does; the SQL path is where `src.enabled` is the guard.
        for (engine, hidden) in [(snapshotEngine, [excluded, child, zeroTurns]),
                                 (sqlEngine, [excluded, child, zeroTurns, disabled])] {
            XCTAssertEqual(try engine.matchingTurns(sessionID: visible, query: query).count, 1)
            for session in hidden {
                XCTAssertThrowsError(try engine.matchingTurns(sessionID: session, query: query)) {
                    XCTAssertEqual($0 as? HistorySearchError, .sessionNotFound, "session \(session)")
                }
                XCTAssertThrowsError(try engine.preview(sessionID: session, query: query))
                XCTAssertThrowsError(try engine.transcript(sessionID: session, query: query))
                XCTAssertThrowsError(try engine.lastTurns(sessionID: session, limit: 5))
            }
        }
    }

    func test_agent_turned_off_is_hidden_before_its_purge_runs() throws {
        let fixture = try Fixture(testCase: self)
        let claude = try fixture.addSession("claude-1", agent: .claude)
        try fixture.addMessage(session: claude, daysAgo: 1, text: "rotate the signing key")
        let codex = try fixture.addSession("codex-1", agent: .codex)
        try fixture.addMessage(session: codex, daysAgo: 2, text: "rotate the signing key")
        let query = Fixture.query("signing")
        // One engine whose snapshot still holds the codex session, one that must fall back to SQL.
        let snapshotEngine = try fixture.engine()
        let sqlEngine = try fixture.engine(
            metadataIndex: HistoryMetadataIndex(snapshot: { .empty }, exclusions: { .init(folders: []) }))

        // Codex is off in the persisted state; its `sources.enabled` row is still 1.
        fixture.enabledAgents.set([.claude])
        for engine in [snapshotEngine, sqlEngine] {
            let content = try engine.searchContent(
                query, context: fixture.context(), excludingSessionIDs: [], cancellation: HistorySearchCancellation())
            XCTAssertEqual(content.results.map(\.session.nativeID), ["claude-1"])
            let codexOnly = try engine.searchContent(
                Fixture.query("agent:codex signing"), context: fixture.context(), excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            XCTAssertTrue(codexOnly.results.isEmpty)
            XCTAssertThrowsError(try engine.preview(sessionID: codex, query: query))
            XCTAssertThrowsError(try engine.transcript(sessionID: codex, query: query))
            XCTAssertThrowsError(try engine.lastTurns(sessionID: codex, limit: 5))
            XCTAssertThrowsError(try engine.matchingTurns(sessionID: codex, query: query)) {
                XCTAssertEqual($0 as? HistorySearchError, .sessionNotFound)
            }
            XCTAssertEqual(try engine.sessions(nativeID: "codex-1", agent: nil, scope: .all), [])
            XCTAssertEqual(try engine.visibleSessionCount(scope: .all), 1)
            XCTAssertNoThrow(try engine.preview(sessionID: claude, query: query))
            XCTAssertEqual(try engine.matchingTurns(sessionID: claude, query: query).count, 1)
        }

        fixture.enabledAgents.set([])
        for engine in [snapshotEngine, sqlEngine] {
            XCTAssertThrowsError(try engine.matchingTurns(sessionID: claude, query: query)) {
                XCTAssertEqual($0 as? HistorySearchError, .sessionNotFound)
            }
        }
        XCTAssertTrue(try snapshotEngine.searchContent(
            query, context: fixture.context(), excludingSessionIDs: [], cancellation: HistorySearchCancellation()
        ).results.isEmpty)
        XCTAssertEqual(try sqlEngine.visibleSessionCount(scope: .all), 0)
    }

    /// The metadata tier reads the persisted agent selection on every call, so an agent turned
    /// off disappears from it while the published snapshot still holds its sessions (no purge
    /// yet, or a standby instance whose owner has not purged).
    func test_agent_turned_off_is_hidden_from_the_metadata_tier_with_an_unchanged_snapshot() throws {
        let fixture = try Fixture(testCase: self)
        let claude = try fixture.addSession(
            "claude-1", agent: .claude, title: "rotate signing key", cwd: "/work/app", repo: "/work/app",
            updatedDaysAgo: 1)
        try fixture.addMessage(session: claude, daysAgo: 1, text: "rotate the signing key")
        let codex = try fixture.addSession(
            "codex-1", agent: .codex, title: "rotate signing key", cwd: "/work/app", repo: "/work/app",
            updatedDaysAgo: 2)
        try fixture.addMessage(session: codex, daysAgo: 2, text: "rotate the signing key")
        let engine = try fixture.engine()
        let index = engine.metadataIndex
        let query = Fixture.query("signing")
        let project = Fixture.projectScope("/work/app")
        let codexKey = try XCTUnwrap(index.summary(forSessionID: codex)).key
        XCTAssertEqual(index.sessionCount(scope: .all), 2, "both agents visible while enabled")

        // Codex is turned off; the snapshot (and its derived cache) is unchanged.
        fixture.enabledAgents.set([.claude])
        for scope in [AgentHistoryScope.all, project] {
            XCTAssertEqual(
                index.search(query, context: fixture.context(scope)).results.map(\.session.id), [claude])
            XCTAssertEqual(
                index.search(Fixture.query(""), context: fixture.context(scope)).results.map(\.session.id), [claude])
            XCTAssertEqual(index.recent(limit: 10, scope: scope).map(\.id), [claude])
            XCTAssertEqual(index.sessionCount(scope: scope), 1)
        }
        XCTAssertTrue(index.search(Fixture.query("agent:codex signing"), context: fixture.context()).results.isEmpty)
        XCTAssertNil(index.summary(forSessionID: codex))
        XCTAssertNotNil(index.summary(forSessionID: claude))
        XCTAssertEqual(index.sessions(for: [codexKey]), [])
        let merged = try engine.searchMerged(
            query, context: fixture.context(), limit: 10, cancellation: HistorySearchCancellation())
        XCTAssertEqual(merged.map(\.session.id), [claude])

        // Turned back on: the same snapshot shows it again (the cache is keyed on the selection).
        fixture.enabledAgents.set(Set(AgentHistoryAgent.allCases))
        XCTAssertEqual(index.recent(limit: 10, scope: .all).map(\.id), [claude, codex])
        XCTAssertNotNil(index.summary(forSessionID: codex))

        fixture.enabledAgents.set([])
        XCTAssertEqual(index.sessionCount(scope: .all), 0)
        XCTAssertTrue(index.search(query, context: fixture.context()).results.isEmpty)
    }
}
