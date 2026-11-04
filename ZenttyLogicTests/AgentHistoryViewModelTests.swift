import Combine
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryViewModelTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var launch: FakeAgentHistoryLaunch!
    private var scheduler: ManualAgentHistoryScheduler!
    private var fileExists: @Sendable (String) -> Bool = { _ in true }
    private var cancellables: Set<AnyCancellable> = []

    private let project = AgentHistoryProjectScope(key: "/tmp/agent-history-tests/zentty", displayName: "zentty", allowsCWDPrefix: true)

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 1284
        status.tokenizer = .trigram
        status.revision = 1
        control.status = status
        search = FakeAgentHistorySearch()
        launch = FakeAgentHistoryLaunch()
        scheduler = ManualAgentHistoryScheduler()
        fileExists = { _ in true }
        cancellables = []
    }

    // MARK: - Fixtures

    private func summary(
        _ id: Int64,
        title: String? = nil,
        agent: AgentHistoryAgent = .codex,
        cwd: String? = "/tmp/agent-history-tests/zentty"
    ) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: agent,
            nativeID: "native-\(id)", title: title ?? "Session \(id)", titleKind: .generated,
            cwd: cwd, createdAtMs: nowMs - 100_000, updatedAtMs: nowMs - id * 1000, turnCount: 4
        )
    }

    private func metadata(_ id: Int64) -> HistoryMetadataResult {
        HistoryMetadataResult(
            session: summary(id), score: 1, isWordLevel: true,
            titleHighlights: [NSRange(location: 0, length: 3)], note: nil
        )
    }

    private func content(_ id: Int64, hits: Int = 1) -> HistoryContentResult {
        HistoryContentResult(
            session: summary(id),
            best: HistoryContentHit(
                sessionID: id, rowID: id * 10, role: .agent, atMs: nowMs - 5000,
                gradedQuality: 1, isWordLevel: true
            ),
            bestQualityHits: 1, totalHits: hits, score: 1, isWordLevel: true,
            snippet: HistorySnippet(
                text: "the crash is fixed", highlights: [NSRange(location: 4, length: 5)],
                truncatedStart: false, truncatedEnd: false
            ),
            note: nil, titleHighlights: []
        )
    }

    private func response(
        _ results: [HistoryContentResult],
        enrichments: [Int64: HistoryContentResult] = [:]
    ) -> HistoryContentResponse {
        HistoryContentResponse(
            query: HistoryQueryParser.parse("crash"), generation: 0, results: results,
            enrichments: enrichments, mode: .fts, truncated: false, elapsed: 0
        )
    }

    private func liveLocation(
        _ key: AgentHistorySessionKey,
        name: String = "Fix sidebar",
        cwd: String? = "/tmp/agent-history-tests/zentty",
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> LiveAgentSessionLocation {
        LiveAgentSessionLocation(
            key: key, windowID: WindowID("window"), worklaneID: WorklaneID("worklane"), paneID: PaneID("pane-\(key.nativeID)"),
            tool: .codex, rawSessionID: key.nativeID, pid: 42, paneDisplayName: name,
            worklaneDisplayName: "zentty", windowTitle: "Zentty", workingDirectory: cwd,
            updatedAt: updatedAt, matchSource: .status
        )
    }

    private func snapshot(_ locations: [LiveAgentSessionLocation]) -> LiveAgentSessionSnapshot {
        LiveAgentSessionSnapshot(locationsByKey: Dictionary(uniqueKeysWithValues: locations.map { ($0.key, [$0]) }))
    }

    private func makeModel(
        entryPoint: AgentHistoryEntryPoint = .shortcutOrMenu,
        currentProject: AgentHistoryProjectScope? = nil,
        initialScope: AgentHistoryScope = .all
    ) -> AgentHistoryViewModel {
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { _, completion in
                completion([ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )])
            },
            raiseClaudeRetention: { $1(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: AgentHistoryTestPasteboard.make(),
            revealInFinder: { _ in },
            fileExists: { [fileExists] in fileExists($0) },
            // Follows the scheduler's clock, so throttles see time pass as the test advances it.
            now: { [nowMs, scheduler] in
                Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000 + (scheduler?.now ?? 0))
            }
        )
        let context = AgentHistoryOpenContext(
            entryPoint: entryPoint,
            currentProject: currentProject,
            initialScope: initialScope,
            hostWindowID: WindowID("window")
        )
        let model = AgentHistoryViewModel(
            context: context,
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: scheduler,
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"), calendar: Self.utcCalendar)
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func titles(_ model: AgentHistoryViewModel, _ kind: AgentHistorySectionKind) -> [String] {
        model.sections.first { $0.kind == kind }?.rows.map(\.title.text) ?? []
    }

    private func section(_ model: AgentHistoryViewModel, _ kind: AgentHistorySectionKind) -> AgentHistorySection? {
        model.sections.first { $0.kind == kind }
    }

    // MARK: - Empty query

    func test_empty_query_shows_running_now_then_recent_with_notes() {
        let liveSummary = summary(1, title: "Live session")
        search.summariesByKey[liveSummary.key] = liveSummary
        search.recent = [liveSummary, summary(2), summary(3)]
        search.sessionCount = 1284
        launch.snapshot = snapshot([liveLocation(liveSummary.key)])

        let model = makeModel()
        model.start()

        XCTAssertEqual(model.body, .results)
        XCTAssertEqual(model.sections.map(\.kind), [.runningNow, .recent])
        XCTAssertEqual(titles(model, .runningNow), ["Live session"])
        XCTAssertEqual(section(model, .runningNow)?.note, "↩ jumps to the pane")
        XCTAssertNotNil(section(model, .runningNow)?.rows.first?.live)
        XCTAssertEqual(titles(model, .recent), ["Session 2", "Session 3"], "live sessions are not repeated under Recent")
        XCTAssertEqual(section(model, .recent)?.note, "1,284 sessions")
        XCTAssertEqual(model.selectedKey, liveSummary.key)
        XCTAssertEqual(model.liveKeys, [liveSummary.key])
        XCTAssertEqual(model.contentPhase, .idle)
        XCTAssertNil(model.emptyResults)
    }

    func test_live_only_running_now_row_without_index_row() {
        let key = AgentHistorySessionKey(agent: .claude, nativeID: "not-indexed-yet")
        launch.snapshot = snapshot([liveLocation(key, name: "Refactor tabs")])

        let model = makeModel()
        model.start()

        let row = section(model, .runningNow)?.rows.first
        XCTAssertEqual(row?.key, key)
        XCTAssertNil(row?.summary)
        XCTAssertEqual(row?.title.text, "Refactor tabs")
        XCTAssertEqual(model.preview, .failed(.notIndexed), "a live-only row has nothing to preview")
        scheduler.advance(by: 1)
        XCTAssertTrue(search.pendingPreviews.isEmpty)
    }

    // MARK: - Typing

    func test_typing_runs_metadata_synchronously_and_defers_content_120ms() {
        search.metadataResults = { _ in [self.metadata(1)] }
        let model = makeModel()
        model.start()

        model.updateQuery("crash")

        XCTAssertEqual(search.metadataQueries.last?.raw, "crash")
        XCTAssertEqual(model.sections.map(\.kind), [.sessions])
        XCTAssertEqual(titles(model, .sessions), ["Session 1"])
        XCTAssertEqual(model.contentPhase, .pending)
        XCTAssertTrue(search.pendingContent.isEmpty)

        scheduler.advance(by: 0.11)
        XCTAssertTrue(search.pendingContent.isEmpty, "content waits for the 120 ms debounce")
        scheduler.advance(by: 0.01)
        XCTAssertEqual(search.pendingContent.count, 1)
        XCTAssertEqual(search.pendingContent.first?.excluding, [1], "metadata sessions are excluded from content")

        search.pendingContent[0].completion(.success(response([content(5, hits: 3)], enrichments: [1: content(1, hits: 4)])))
        XCTAssertEqual(model.contentPhase, .complete)
        XCTAssertEqual(model.sections.map(\.kind), [.sessions, .inConversations])
        XCTAssertEqual(titles(model, .inConversations), ["Session 5"])
        XCTAssertEqual(section(model, .inConversations)?.rows.first?.hitCount, 3)
        XCTAssertEqual(section(model, .sessions)?.rows.first?.hitCount, 4, "enrichment adds the match count")
        XCTAssertEqual(model.selectedKey, summary(1).key)
    }

    func test_new_keystroke_cancels_pending_and_in_flight_content_search() {
        let model = makeModel()
        model.start()

        model.updateQuery("crash")
        scheduler.advance(by: 0.12)
        XCTAssertEqual(search.pendingContent.count, 1)

        model.updateQuery("crashes")
        XCTAssertTrue(search.pendingContent[0].token.isCancelled, "the in-flight search is cancelled")
        model.updateQuery("crashed")
        scheduler.advance(by: 0.12)
        XCTAssertEqual(search.pendingContent.count, 2, "the superseded debounce never fired")
        XCTAssertEqual(search.pendingContent[1].query.raw, "crashed")
    }

    func test_late_response_from_older_generation_is_ignored() {
        let model = makeModel()
        model.start()

        model.updateQuery("alpha")
        scheduler.advance(by: 0.12)
        model.updateQuery("bravo")
        scheduler.advance(by: 0.12)

        search.pendingContent[0].completion(.success(response([content(7)])))
        XCTAssertEqual(model.contentPhase, .pending)
        XCTAssertTrue(titles(model, .inConversations).isEmpty)

        search.pendingContent[1].completion(.success(response([content(8)])))
        XCTAssertEqual(model.contentPhase, .complete)
        XCTAssertEqual(titles(model, .inConversations), ["Session 8"])
    }

    func test_previous_content_rows_stay_visible_until_new_response_arrives() {
        search.metadataResults = { query in query.raw == "crash fix" ? [self.metadata(5)] : [] }
        let model = makeModel()
        model.start()

        model.updateQuery("crash")
        scheduler.advance(by: 0.12)
        search.pendingContent[0].completion(.success(response([content(5), content(6)])))
        XCTAssertEqual(titles(model, .inConversations), ["Session 5", "Session 6"])

        model.updateQuery("crash fix")
        let stale = section(model, .inConversations)?.rows ?? []
        XCTAssertEqual(stale.map(\.title.text), ["Session 6"], "a session now under Sessions drops out")
        XCTAssertEqual(stale.map(\.isStale), [true])
        XCTAssertEqual(model.contentPhase, .pending)

        scheduler.advance(by: 0.12)
        search.pendingContent[1].completion(.success(response([content(9)])))
        XCTAssertEqual(titles(model, .inConversations), ["Session 9"])
        XCTAssertEqual(section(model, .inConversations)?.rows.map(\.isStale), [false])
    }

    func test_short_terms_only_skip_content_tier_and_show_footer_hint() {
        let model = makeModel()
        model.start()
        model.updateQuery("crash")
        scheduler.advance(by: 0.12)
        search.pendingContent[0].completion(.success(response([content(5)])))

        model.updateQuery("cr")

        XCTAssertEqual(model.contentPhase, .shortTermsOnly)
        XCTAssertTrue(titles(model, .inConversations).isEmpty, "short terms clear the content rows")
        XCTAssertEqual(model.footer.hint, "Type 3+ characters to search conversations")
        scheduler.advance(by: 1)
        XCTAssertEqual(search.pendingContent.count, 1, "no content search for short terms")

        model.updateQuery("crash")
        XCTAssertNil(model.footer.hint)
    }

    func test_no_results_waits_for_content_completion_and_mentions_tab_when_scoped() {
        let model = makeModel(currentProject: project, initialScope: .project(project))
        model.start()

        model.updateQuery("zzzz")
        XCTAssertEqual(model.emptyResults, .searching)
        XCTAssertEqual(model.emptyResults?.title, "Searching conversations…")

        scheduler.advance(by: 0.12)
        search.pendingContent[0].completion(.success(response([])))
        XCTAssertEqual(model.emptyResults, .noMatches(query: "zzzz", suggestsAllProjects: true))
        XCTAssertEqual(model.emptyResults?.title, "No sessions match “zzzz”.")
        XCTAssertEqual(model.emptyResults?.scopeHint, "Press ⇥ to search all projects")

        model.toggleScope()
        scheduler.advance(by: 0.12)
        search.pendingContent[1].completion(.success(response([])))
        XCTAssertEqual(model.emptyResults, .noMatches(query: "zzzz", suggestsAllProjects: false))
        XCTAssertNil(model.emptyResults?.scopeHint)

        model.updateQuery("zz")
        XCTAssertEqual(model.emptyResults, .noMatches(query: "zz", suggestsAllProjects: false), "short terms never wait")
    }

    func test_filter_operators_produce_pills() {
        let model = makeModel()
        model.start()

        model.updateQuery("crash agent:codex branch: before:nope")

        XCTAssertEqual(model.pills.map(\.label), ["Agent: codex", "Branch:"])
        XCTAssertEqual(search.metadataQueries.last?.filters.agents, [.codex])

        model.updateQuery("")
        XCTAssertTrue(model.pills.isEmpty)
    }

    // MARK: - Scope

    func test_tab_toggles_scope_and_reruns_both_tiers() {
        let model = makeModel(currentProject: project)
        model.start()
        XCTAssertEqual(model.scope, .all)
        XCTAssertTrue(model.canToggleScope)

        model.updateQuery("crash")
        scheduler.advance(by: 0.12)
        let metadataCalls = search.metadataQueries.count

        model.toggleScope()
        XCTAssertEqual(model.scope, .project(project))
        XCTAssertEqual(search.metadataQueries.count, metadataCalls + 1, "metadata reruns")
        XCTAssertTrue(search.pendingContent[0].token.isCancelled)
        scheduler.advance(by: 0.12)
        XCTAssertEqual(search.pendingContent.count, 2, "content reruns")

        model.toggleScope()
        XCTAssertEqual(model.scope, .all)

        model.updateQuery("")
        model.toggleScope()
        XCTAssertEqual(search.recentScopes.last, .project(project), "the empty-query view follows the scope")
    }

    func test_scope_toggle_disabled_without_current_project() {
        let model = makeModel(currentProject: nil)
        model.start()

        XCTAssertFalse(model.canToggleScope)
        model.toggleScope()
        XCTAssertEqual(model.scope, .all)
    }

    func test_worklane_entry_opens_project_scoped() {
        let model = makeModel(
            entryPoint: .worklaneContextMenu(WorklaneID("worklane-2")),
            currentProject: nil,
            initialScope: .project(project)
        )
        model.start()

        XCTAssertEqual(model.scope, .project(project))
        XCTAssertEqual(search.recentScopes.last, .project(project))
        XCTAssertTrue(model.canToggleScope, "the worklane's project is one ⇥ away")
        model.toggleScope()
        XCTAssertEqual(model.scope, .all)
        model.toggleScope()
        XCTAssertEqual(model.scope, .project(project))
    }

    // MARK: - Detail

    func test_query_edit_closes_transcript() {
        search.recent = [summary(1)]
        let model = makeModel()
        model.start()

        model.toggleTranscript()
        XCTAssertEqual(model.detail, .transcript)

        model.updateQuery("crash")
        XCTAssertEqual(model.detail, .none)
        XCTAssertEqual(model.transcript, .idle)
    }

    func test_selection_change_loads_preview_and_cancels_previous() {
        search.recent = [summary(1), summary(2), summary(3)]
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.preview, .loading)

        scheduler.advance(by: 0.06)
        XCTAssertEqual(search.pendingPreviews.map(\.sessionID), [1])

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedKey, summary(2).key)
        XCTAssertTrue(search.pendingPreviews[0].token.isCancelled)
        model.moveSelection(by: 1)
        scheduler.advance(by: 0.06)
        XCTAssertEqual(search.pendingPreviews.map(\.sessionID), [1, 3], "selection changes coalesce over 60 ms")
        XCTAssertEqual(search.pendingPreviews.map(\.key), [summary(1).key, summary(3).key],
                       "each load names the row's session, in case its row id is reused")

        let loaded = HistoryPreview(session: summary(3), turns: [], turnsAreMatches: false)
        search.pendingPreviews[1].completion(.success(loaded))
        XCTAssertEqual(model.preview, .loaded(loaded))

        model.moveSelection(by: 5)
        XCTAssertEqual(model.selectedKey, summary(3).key, "selection clamps at the end")
        model.moveSelection(by: -1)
        scheduler.advance(by: 0.06)
        search.pendingPreviews[2].completion(.failure(HistorySearchError.sessionNotFound))
        XCTAssertEqual(model.preview, .failed(.sessionNotFound))
    }

    func test_transcript_loads_lazily_and_follows_selection() {
        search.recent = [summary(1), summary(2)]
        let model = makeModel()
        model.start()
        scheduler.advance(by: 1)
        XCTAssertTrue(search.pendingTranscripts.isEmpty, "nothing loads before the transcript is shown")

        model.toggleTranscript()
        XCTAssertEqual(model.detail, .transcript)
        XCTAssertEqual(model.transcript, .loading)
        XCTAssertEqual(search.pendingTranscripts.map(\.sessionID), [1])

        model.moveSelection(by: 1)
        XCTAssertTrue(search.pendingTranscripts[0].token.isCancelled)
        scheduler.advance(by: 0.06)
        XCTAssertEqual(search.pendingTranscripts.map(\.sessionID), [1, 2])
        XCTAssertEqual(search.pendingTranscripts.map(\.key), [summary(1).key, summary(2).key])
        let transcript = HistoryTranscript(turns: [], firstMatchMessageID: nil, isTruncated: false)
        search.pendingTranscripts[1].completion(.success(transcript))
        XCTAssertEqual(model.transcript, .loaded(transcript))

        model.toggleTranscript()
        XCTAssertEqual(model.detail, .none)
        model.moveSelection(by: -1)
        scheduler.advance(by: 1)
        XCTAssertEqual(search.pendingTranscripts.count, 2, "a hidden transcript does not follow selection")
    }

    // MARK: - Updates

    func test_status_revision_refreshes_empty_query_but_not_typed_results() {
        search.recent = [summary(1)]
        let model = makeModel()
        model.start()
        let recentCalls = search.recentScopes.count

        search.recent = [summary(1), summary(2)]
        var status = control.status
        for revision: UInt64 in 2...4 {
            status.revision = revision
            status.indexedSessions = 1281 + Int(revision)
            control.publish(status)
        }
        XCTAssertEqual(model.footer.health.text, "1,285 sessions", "the footer follows every status")
        scheduler.advance(by: 0.99)
        XCTAssertEqual(search.recentScopes.count, recentCalls, "no refresh within a second of the last one")
        XCTAssertEqual(titles(model, .recent), ["Session 1"])
        scheduler.advance(by: 0.01)
        XCTAssertEqual(search.recentScopes.count, recentCalls + 1, "revisions inside the window collapse into one refresh")
        XCTAssertEqual(titles(model, .recent), ["Session 1", "Session 2"])
        scheduler.advance(by: 5)
        XCTAssertEqual(search.recentScopes.count, recentCalls + 1)

        // The last refresh was over a second ago: the next revision refreshes on the next tick.
        search.recent = [summary(1), summary(2), summary(3)]
        status.revision = 5
        control.publish(status)
        XCTAssertEqual(search.recentScopes.count, recentCalls + 1, "never synchronously inside the status callback")
        scheduler.advance(by: 0)
        XCTAssertEqual(search.recentScopes.count, recentCalls + 2)
        XCTAssertEqual(titles(model, .recent), ["Session 1", "Session 2", "Session 3"])

        model.updateQuery("crash")
        let metadataCalls = search.metadataQueries.count
        status.revision = 6
        control.publish(status)
        scheduler.advance(by: 1)
        XCTAssertEqual(search.metadataQueries.count, metadataCalls, "typed results never re-run")
        XCTAssertEqual(search.pendingContent.count, 1)

        status.state = .failed(.corrupt)
        status.revision = 7
        control.publish(status)
        XCTAssertEqual(model.body, .indexUnavailable(.corrupt))
    }

    func test_live_change_updates_live_badges() {
        let first = summary(1)
        let second = summary(2)
        search.recent = [first, second]
        search.summariesByKey = [first.key: first, second.key: second]
        search.metadataResults = { _ in [self.metadata(2)] }
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.sections.map(\.kind), [.recent])

        launch.publishLive(snapshot([liveLocation(first.key)]))
        XCTAssertEqual(model.liveKeys, [first.key])
        XCTAssertEqual(titles(model, .runningNow), ["Session 1"])
        XCTAssertEqual(titles(model, .recent), ["Session 2"])

        model.updateQuery("session")
        XCTAssertNil(section(model, .sessions)?.rows.first?.live)
        launch.publishLive(snapshot([liveLocation(second.key)]))
        XCTAssertEqual(model.liveKeys, [second.key])
        XCTAssertNotNil(section(model, .sessions)?.rows.first?.live, "typed rows pick up the live badge in place")
    }

    func test_folder_gone_checks_publish_missing_folders() {
        fileExists = { $0 != "/tmp/agent-history-tests/gone" }
        let gone = summary(1, cwd: "/tmp/agent-history-tests/gone")
        search.recent = [gone, summary(2)]
        let model = makeModel()
        let published = expectation(description: "folder-gone keys published")
        model.$folderGoneKeys
            .filter { !$0.isEmpty }
            .first()
            .sink { keys in
                XCTAssertEqual(keys, [gone.key])
                published.fulfill()
            }
            .store(in: &cancellables)

        model.start()
        wait(for: [published], timeout: 5)
    }

    func test_not_consented_shows_loading_then_consent_or_no_agents() {
        var status = control.status
        status.isStateLoaded = true
        status.hasConsented = false
        status.state = .off
        control.status = status
        control.detectedSources = [
            AgentHistoryDetectedSource(agent: .claude, rootPath: nil, isFound: false, sessionCount: nil,
                                       checkedPaths: ["/tmp/agent-history-tests/.claude"], problem: nil),
        ]
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.body, .noAgents(checkedPaths: ["/tmp/agent-history-tests/.claude"]))

        control.detectedSources = [
            AgentHistoryDetectedSource(agent: .codex, rootPath: "/tmp/agent-history-tests/.codex", isFound: true,
                                       sessionCount: nil, checkedPaths: [], problem: nil),
        ]
        let second = makeModel()
        second.start()
        XCTAssertEqual(second.body, .consent)
        XCTAssertEqual(second.consent?.enabledAgents, [.codex])
    }
}
