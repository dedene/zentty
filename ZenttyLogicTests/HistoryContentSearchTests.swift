import Foundation
import XCTest
@testable import Zentty

final class HistoryContentSearchTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private func search(
        _ engine: HistorySearchEngine,
        _ raw: String,
        fixture: Fixture,
        scope: AgentHistoryScope = .all,
        excluding: Set<Int64> = []
    ) throws -> HistoryContentResponse {
        try engine.searchContent(
            Fixture.query(raw), context: fixture.context(scope), excludingSessionIDs: excluding,
            cancellation: HistorySearchCancellation())
    }

    private func nativeIDs(_ response: HistoryContentResponse) -> [String] {
        response.results.map(\.session.nativeID)
    }

    // MARK: - Ordered scan

    func test_returns_newest_hits_first() throws {
        let fixture = try Fixture(testCase: self)
        for (name, days) in [("old", 30.0), ("middle", 10.0), ("new", 2.0)] {
            let session = try fixture.addSession(name, updatedDaysAgo: days)
            try fixture.addMessage(session: session, daysAgo: days, text: "please deploy the service")
        }

        let all = try search(fixture.engine(), "deploy", fixture: fixture)
        XCTAssertEqual(all.mode, .fts)
        XCTAssertEqual(nativeIDs(all), ["new", "middle", "old"])
        XCTAssertFalse(all.truncated)

        var tuning = HistorySearchEngine.Tuning()
        tuning.messageLimit = 2
        let limited = try search(fixture.engine(tuning: tuning), "deploy", fixture: fixture)
        XCTAssertEqual(nativeIDs(limited), ["new", "middle"], "the scan walks newest rows first")
        XCTAssertTrue(limited.truncated)
    }

    func test_filters_inside_ordered_scan_quiet_repo_not_crowded_out() throws {
        let fixture = try Fixture(testCase: self)
        let busy = try fixture.addSession("busy", cwd: "/repos/busy", repo: "/repos/busy", mainRepo: "/repos/busy",
                                          updatedDaysAgo: 1)
        try fixture.addMessages(
            session: busy, startMs: Fixture.ms(daysAgo: 2), stepMs: 1_000,
            texts: (0..<2_500).map { "migration step \($0)" })
        let quiet = try fixture.addSession("quiet", cwd: "/repos/quiet", repo: "/repos/quiet", mainRepo: "/repos/quiet",
                                           updatedDaysAgo: 20)
        try fixture.addMessages(
            session: quiet, startMs: Fixture.ms(daysAgo: 21), stepMs: 1_000,
            texts: (0..<5).map { "quiet migration \($0)" })
        let engine = try fixture.engine()

        let unfiltered = try search(engine, "migration", fixture: fixture)
        XCTAssertTrue(unfiltered.truncated)
        XCTAssertEqual(nativeIDs(unfiltered), ["busy"], "the 2,000 newest hits all belong to the busy repo")

        let scoped = try search(engine, "migration", fixture: fixture, scope: Fixture.projectScope("/repos/quiet"))
        XCTAssertEqual(nativeIDs(scoped), ["quiet"])
        XCTAssertFalse(scoped.truncated)

        let byRepo = try search(engine, "repo:quiet migration", fixture: fixture)
        XCTAssertEqual(nativeIDs(byRepo), ["quiet"])
        XCTAssertFalse(byRepo.truncated)

        let byPath = try search(engine, "repo:/repos/quiet migration", fixture: fixture)
        XCTAssertEqual(nativeIDs(byPath), ["quiet"])
    }

    func test_agent_filter_and_disabled_source_hidden() throws {
        let fixture = try Fixture(testCase: self)
        let claudeSource = try fixture.addSource(.claude)
        let claude = try fixture.addSession("claude-1", agent: .claude)
        try fixture.addMessage(session: claude, daysAgo: 1, text: "refactor the parser")
        let codex = try fixture.addSession("codex-1", agent: .codex)
        try fixture.addMessage(session: codex, daysAgo: 2, text: "refactor the lexer")
        let engine = try fixture.engine()

        XCTAssertEqual(Set(nativeIDs(try search(engine, "refactor", fixture: fixture))), ["claude-1", "codex-1"])
        XCTAssertEqual(nativeIDs(try search(engine, "agent:codex refactor", fixture: fixture)), ["codex-1"])

        try fixture.store().setSourceEnabled(id: claudeSource, false)
        XCTAssertEqual(nativeIDs(try search(engine, "refactor", fixture: fixture)), ["codex-1"])
    }

    func test_before_after_on_message_time() throws {
        let fixture = try Fixture(testCase: self)
        let calendar = Fixture.utc
        func ms(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let early = try fixture.addSession("early", updatedDaysAgo: 5)
        try fixture.addMessage(session: early, atMs: ms(2026, 10, 10), text: "rotate the signing key")
        let late = try fixture.addSession("late", updatedDaysAgo: 5)
        try fixture.addMessage(session: late, atMs: ms(2026, 10, 20), text: "rotate the signing key")
        let mixed = try fixture.addSession("mixed", updatedDaysAgo: 5)
        try fixture.addMessage(session: mixed, atMs: ms(2026, 10, 5), text: "rotate the signing key")
        try fixture.addMessage(session: mixed, atMs: ms(2026, 10, 25), text: "rotate the signing key again")
        let engine = try fixture.engine()

        let after = try search(engine, "after:2026-10-15 rotate", fixture: fixture)
        XCTAssertEqual(Set(nativeIDs(after)), ["late", "mixed"])
        XCTAssertEqual(after.results.first { $0.session.nativeID == "mixed" }?.best.atMs, ms(2026, 10, 25))

        let before = try search(engine, "before:2026-10-15 rotate", fixture: fixture)
        XCTAssertEqual(Set(nativeIDs(before)), ["early", "mixed"])
        XCTAssertEqual(before.results.first { $0.session.nativeID == "mixed" }?.best.atMs, ms(2026, 10, 5))

        let between = try search(engine, "after:2026-10-15 before:2026-10-21 rotate", fixture: fixture)
        XCTAssertEqual(nativeIDs(between), ["late"])
    }

    func test_short_term_instr_filter_requires_word_or_prefix() throws {
        let fixture = try Fixture(testCase: self)
        let word = try fixture.addSession("word")
        try fixture.addMessage(session: word, daysAgo: 1, text: "deploy the ui now")
        let midWord = try fixture.addSession("mid-word")
        try fixture.addMessage(session: midWord, daysAgo: 1, text: "deploy the test suite")
        let missing = try fixture.addSession("missing")
        try fixture.addMessage(session: missing, daysAgo: 1, text: "deploy the backend")

        let response = try search(fixture.engine(), "deploy ui", fixture: fixture)
        XCTAssertEqual(nativeIDs(response), ["word"])
    }

    // MARK: - Artifacts and enrichments

    func test_artifact_hits_produce_changed_and_ran_notes() throws {
        let fixture = try Fixture(testCase: self)
        let changed = try fixture.addSession("changed")
        try fixture.addMessage(session: changed, daysAgo: 1, text: "tidy the window code")
        try fixture.addArtifact(session: changed, kind: .path, value: "Sources/App/RootViewController.swift", daysAgo: 1)
        let ran = try fixture.addSession("ran")
        try fixture.addMessage(session: ran, daysAgo: 1, text: "build it")
        try fixture.addArtifact(session: ran, kind: .command, value: "swift build --configuration release", daysAgo: 1)
        let engine = try fixture.engine()

        let path = try search(engine, "rootviewcontroller", fixture: fixture)
        XCTAssertEqual(nativeIDs(path), ["changed"])
        XCTAssertEqual(path.results.first?.note, .artifact(.path, value: "Sources/App/RootViewController.swift"))
        XCTAssertEqual(path.results.first?.best.role, .artifact(.path))
        XCTAssertNil(path.results.first?.snippet)
        XCTAssertEqual(path.results.first?.best.quality ?? 0, 0.9, accuracy: 1e-9, "artifact discount")

        let command = try search(engine, "configuration", fixture: fixture)
        XCTAssertEqual(nativeIDs(command), ["ran"])
        XCTAssertEqual(command.results.first?.note, .artifact(.command, value: "swift build --configuration release"))
    }

    func test_dedupe_against_metadata_ids_yields_enrichment() throws {
        let fixture = try Fixture(testCase: self)
        let shown = try fixture.addSession("shown", title: "Websocket reconnect")
        try fixture.addMessage(session: shown, daysAgo: 1, text: "the websocket drops after sleep")
        let other = try fixture.addSession("other")
        try fixture.addMessage(session: other, daysAgo: 2, text: "websocket handshake fails")

        let response = try search(fixture.engine(), "websocket", fixture: fixture, excluding: [shown])
        XCTAssertEqual(nativeIDs(response), ["other"])
        let enrichment = try XCTUnwrap(response.enrichments[shown])
        XCTAssertEqual(enrichment.session.nativeID, "shown")
        XCTAssertEqual(enrichment.snippet?.text, "the websocket drops after sleep")
        XCTAssertEqual(enrichment.titleHighlights, [NSRange(location: 0, length: 9)])
    }

    func test_child_and_zero_turn_sessions_excluded() throws {
        let fixture = try Fixture(testCase: self)
        let visible = try fixture.addSession("visible")
        try fixture.addMessage(session: visible, daysAgo: 1, text: "flaky snapshot test")
        let child = try fixture.addSession("child", parent: "visible")
        try fixture.addMessage(session: child, daysAgo: 1, text: "flaky snapshot test in the child")
        let agentOnly = try fixture.addSession("agent-only")
        try fixture.addMessage(session: agentOnly, role: .agent, daysAgo: 1, text: "flaky snapshot test reply")

        XCTAssertEqual(nativeIDs(try search(fixture.engine(), "snapshot", fixture: fixture)), ["visible"])
    }

    // MARK: - Tokenizers

    func test_unicode61_fallback_prefix_recall() throws {
        let fixture = try Fixture(testCase: self, tokenizer: .unicode61)
        let session = try fixture.addSession("prefix")
        try fixture.addMessage(session: session, daysAgo: 1, text: "the deployment pipeline is red")

        let response = try search(fixture.engine(), "deploy pipe", fixture: fixture)
        XCTAssertEqual(response.mode, .fts)
        XCTAssertEqual(nativeIDs(response), ["prefix"])
        XCTAssertEqual(response.results.first?.isWordLevel, true)
    }

    func test_scan_fallback_searches_newest_window_only() throws {
        let fixture = try Fixture(testCase: self, tokenizer: .none)
        let old = try fixture.addSession("old", updatedDaysAgo: 10)
        try fixture.addMessages(session: old, startMs: Fixture.ms(daysAgo: 10), stepMs: 1_000,
                                texts: ["needle in the old haystack", "filler", "filler"])
        let new = try fixture.addSession("new", updatedDaysAgo: 1)
        try fixture.addMessages(session: new, startMs: Fixture.ms(daysAgo: 1), stepMs: 1_000,
                                texts: ["filler", "filler", "filler", "filler", "needle in the new haystack"])

        var tuning = HistorySearchEngine.Tuning()
        tuning.scanWindow = 5
        let windowed = try search(fixture.engine(tuning: tuning), "needle", fixture: fixture)
        XCTAssertEqual(windowed.mode, .scanFallback)
        XCTAssertEqual(nativeIDs(windowed), ["new"])
        XCTAssertTrue(windowed.truncated)

        let everything = try search(fixture.engine(), "needle", fixture: fixture)
        XCTAssertEqual(nativeIDs(everything), ["new", "old"])
        XCTAssertFalse(everything.truncated)
    }

    func test_metadata_only_query_runs_no_content_search() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("short")
        try fixture.addMessage(session: session, daysAgo: 1, text: "go ui")

        let response = try search(fixture.engine(), "go ui", fixture: fixture)
        XCTAssertEqual(response.mode, .metadataOnly)
        XCTAssertTrue(response.results.isEmpty)
        XCTAssertFalse(Fixture.query("go ui").hasContentTerms(tokenizer: .trigram))
        XCTAssertTrue(Fixture.query("deploy").hasContentTerms(tokenizer: .trigram))
    }

    // MARK: - Cancellation and availability

    func test_cancellation_mid_query_throws_cancelled_and_resets_progress_handler() throws {
        let fixture = try Fixture(testCase: self, readerCount: 1)
        let session = try fixture.addSession("busy")
        try fixture.addMessages(session: session, startMs: Fixture.ms(daysAgo: 3), stepMs: 1_000,
                                texts: (0..<600).map { "cache invalidation \($0)" })

        let cancellation = HistorySearchCancellation(generation: 7)
        let gradedRows = Fixture.Box(0)
        var tuning = HistorySearchEngine.Tuning()
        tuning.cancellationCheckRows = 1_000_000   // leave it to SQLite's progress handler
        tuning.progressHandlerInstructions = 50
        tuning.willGradeRow = {
            gradedRows.set(gradedRows.value + 1)
            cancellation.cancel()
        }
        let cancelling = try fixture.engine(tuning: tuning)

        XCTAssertThrowsError(try cancelling.searchContent(
            Fixture.query("cache"), context: fixture.context(), excludingSessionIDs: [], cancellation: cancellation)
        ) { error in
            XCTAssertEqual(error as? HistorySearchError, .cancelled)
        }
        // The handler aborted the statement mid-scan; the check after the scan would only have
        // thrown once all 600 rows were graded.
        XCTAssertGreaterThan(gradedRows.value, 0)
        XCTAssertLessThan(gradedRows.value, 10, "the progress handler must interrupt the running statement")

        // The only reader is reused: a handler left installed would abort this search too.
        let next = try fixture.engine().searchContent(
            Fixture.query("cache"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation(generation: 8))
        XCTAssertEqual(nativeIDs(next), ["busy"])
        XCTAssertEqual(next.generation, 8)
        XCTAssertEqual(fixture.index.storage.readers.openConnectionCountForTesting, 1)
    }

    func test_cancelled_before_start_throws_cancelled() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("any")
        try fixture.addMessage(session: session, daysAgo: 1, text: "cancel me")
        let cancellation = HistorySearchCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(try fixture.engine().searchContent(
            Fixture.query("cancel"), context: fixture.context(), excludingSessionIDs: [], cancellation: cancellation)
        ) { error in
            XCTAssertEqual(error as? HistorySearchError, .cancelled)
        }
    }

    func test_async_search_completes_on_main() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("async")
        try fixture.addMessage(session: session, daysAgo: 1, text: "background search")
        let engine = try fixture.engine()

        let done = expectation(description: "completion")
        engine.searchContentAsync(
            Fixture.query("background"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation()
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual((try? result.get())?.results.map(\.session.nativeID), ["async"])
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func test_newer_schema_returns_index_unavailable() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("any")
        try fixture.addMessage(session: session, daysAgo: 1, text: "schema check")
        let engine = try fixture.engine()
        try fixture.writer.setUserVersion(AgentHistorySchema.currentVersion + 1)

        XCTAssertThrowsError(try search(engine, "schema", fixture: fixture)) { error in
            XCTAssertEqual(error as? HistorySearchError, .indexUnavailable("newerSchema"))
        }
    }

    // MARK: - Scope, exclusions, long text

    func test_merged_search_enforces_repository_scope() throws {
        let fixture = try Fixture(testCase: self)
        let inScope = try fixture.addSession("in-scope", title: "Telemetry exporter", cwd: "/repos/app",
                                             repo: "/repos/app", mainRepo: "/repos/app")
        try fixture.addMessage(session: inScope, daysAgo: 1, text: "wire the telemetry exporter")
        let titleOutside = try fixture.addSession("title-outside", title: "Telemetry dashboard", cwd: "/repos/web",
                                                  repo: "/repos/web", mainRepo: "/repos/web")
        try fixture.addMessage(session: titleOutside, daysAgo: 1, text: "charts")
        let contentOutside = try fixture.addSession("content-outside", cwd: "/repos/web",
                                                    repo: "/repos/web", mainRepo: "/repos/web")
        try fixture.addMessage(session: contentOutside, daysAgo: 1, text: "telemetry sampling rate")
        let engine = try fixture.engine()

        let scoped = try engine.searchMerged(
            Fixture.query("telemetry"), context: fixture.context(Fixture.projectScope("/repos/app")), limit: 10,
            cancellation: HistorySearchCancellation())
        XCTAssertEqual(scoped.map(\.session.nativeID), ["in-scope"])

        let all = try engine.searchMerged(
            Fixture.query("telemetry"), context: fixture.context(), limit: 10, cancellation: HistorySearchCancellation())
        XCTAssertEqual(Set(all.map(\.session.nativeID)), ["in-scope", "title-outside", "content-outside"])
    }

    func test_long_message_beyond_64kb_still_counts_as_mid_word() throws {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("long")
        let filler = String(repeating: "lorem ipsum ", count: 6_000)   // 72,000 characters
        try fixture.addMessage(session: session, daysAgo: 1, text: filler + "zebracorn appears late")

        let response = try search(fixture.engine(), "zebracorn", fixture: fixture)
        let result = try XCTUnwrap(response.results.first)
        XCTAssertEqual(result.session.nativeID, "long")
        XCTAssertEqual(result.best.quality, HistoryMatchClass.midWord.credit, accuracy: 1e-9)
        XCTAssertFalse(result.isWordLevel)
    }

    func test_long_row_fallback_needs_a_term_hidden_by_the_cut() throws {
        let fixture = try Fixture(testCase: self)
        // Over the prefix, but only an uncredited short mid-word occurrence of `log`.
        let catalog = try fixture.addSession("catalog")
        try fixture.addMessage(session: catalog, daysAgo: 1,
                               text: "write the catalog entry " + String(repeating: "catalog entry ", count: 5_500))
        // Not cut: 25,000 CJK characters are 75,000 bytes but fewer characters than the prefix.
        let cjk = try fixture.addSession("cjk")
        try fixture.addMessage(session: cjk, daysAgo: 1,
                               text: String(repeating: "漢", count: 25_000) + " commit deadbeefcafe1234")
        // Cut, `zebracorn` beyond it, but `xy` is a fifth short term SQL never filters on.
        let unfiltered = try fixture.addSession("unfiltered")
        try fixture.addMessage(session: unfiltered, daysAgo: 1,
                               text: String(repeating: "ab cd ef gh ", count: 6_000) + "zebracorn")
        let engine = try fixture.engine()

        XCTAssertEqual(nativeIDs(try search(engine, "log", fixture: fixture)), [], "present but uncredited")
        XCTAssertEqual(nativeIDs(try search(engine, "beef", fixture: fixture)), [], "hex guard, row not cut")
        XCTAssertEqual(nativeIDs(try search(engine, "zebracorn ab cd ef gh xy", fixture: fixture)), [])
        let control = try XCTUnwrap(try search(engine, "zebracorn ab cd ef gh", fixture: fixture).results.first)
        XCTAssertEqual(control.session.nativeID, "unfiltered")
        XCTAssertEqual(control.best.quality, HistoryMatchClass.midWord.credit, accuracy: 1e-9)
    }

    func test_excluded_folder_hidden_in_content_tier() throws {
        let fixture = try Fixture(testCase: self)
        let secret = try fixture.addSession("secret", cwd: "/work/secret/app")
        try fixture.addMessage(session: secret, daysAgo: 1, text: "rotate the token")
        let open = try fixture.addSession("open", cwd: "/work/open")
        try fixture.addMessage(session: open, daysAgo: 2, text: "rotate the token")
        let engine = try fixture.engine()
        XCTAssertEqual(Set(nativeIDs(try search(engine, "token", fixture: fixture))), ["secret", "open"])

        // Excluded after indexing: hidden before any purge removes the rows.
        fixture.exclusions.set(AgentHistoryExclusionMatcher(folders: ["/work/secret"]))
        let response = try search(engine, "token", fixture: fixture, excluding: [secret])
        XCTAssertEqual(nativeIDs(response), ["open"])
        XCTAssertTrue(response.enrichments.isEmpty)
    }

    // MARK: - Ingest contract

    func test_ingest_to_query_normalization_contract() throws {
        let fixture = try Fixture(testCase: self)
        let sourceID = try fixture.addSource(.claude)
        let texts: [String: String] = [
            "case": "Refactor the PARSER module",
            "diacritics": "Café crème résumé",
            "nfd": "Le\u{0301}gende de l'e\u{0301}clair",
            "quotes": "She said \u{201C}ship it\u{201D} twice",
            "fullwidth": "ＦＵＬＬＷＩＤＴＨ ｓｅａｒｃｈ",
            "katakana": "ガイドを読む",
            "dakuten": "がっこうに行く",
        ]
        for (nativeID, text) in texts {
            var builder = AgentHistoryBatchBuilder(
                session: AgentHistorySessionDraft(nativeID: nativeID), firstSeq: 0,
                context: AgentHistoryFixtures.context())
            XCTAssertTrue(builder.addMessage(role: .user, atMs: Fixture.ms(daysAgo: 1), rawText: text))
            let (messages, artifacts) = builder.drafts()
            try fixture.store().apply(
                AgentHistoryFixtures.batch(sourceID: sourceID, unitKey: nativeID, sessions: [builder.session],
                                           messages: messages, artifacts: artifacts),
                sourceID: sourceID, unitKey: nativeID)
        }
        let engine = try fixture.engine()

        let expectations: [(query: String, nativeID: String)] = [
            ("parser", "case"),
            ("CAFE", "diacritics"),
            ("resume", "diacritics"),
            ("légende", "nfd"),
            ("e\u{0301}clair", "nfd"),
            ("\"ship it\"", "quotes"),
            ("fullwidth", "fullwidth"),
            ("ｶﾞｲﾄﾞ", "katakana"),
            ("ガイド", "katakana"),
            ("がっこう", "dakuten"),
        ]
        for (raw, nativeID) in expectations {
            XCTAssertEqual(nativeIDs(try search(engine, raw, fixture: fixture)), [nativeID], "query \(raw)")
        }
        XCTAssertEqual(nativeIDs(try search(engine, "かっこう", fixture: fixture)), [], "dakuten must not fold")
    }
}
