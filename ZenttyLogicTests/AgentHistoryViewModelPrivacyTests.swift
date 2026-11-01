import XCTest
@testable import Zentty

/// Turning Agent History off, deleting the index, turning an agent off or excluding a folder
/// while the palette is open must not leave sessions on screen that are no longer allowed.
@MainActor
final class AgentHistoryViewModelPrivacyTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var launch: FakeAgentHistoryLaunch!
    private var scheduler: ManualAgentHistoryScheduler!
    private var closeRequests: [Bool] = []

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = [.claude, .codex]
        status.state = .watching
        status.indexedSessions = 3
        status.tokenizer = .trigram
        status.revision = 1
        control.status = status
        search = FakeAgentHistorySearch()
        launch = FakeAgentHistoryLaunch()
        scheduler = ManualAgentHistoryScheduler()
        closeRequests = []
    }

    // MARK: - Fixtures

    private func summary(_ id: Int64, agent: AgentHistoryAgent = .codex) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: agent,
            nativeID: "native-\(id)", title: "Session \(id)", titleKind: .generated,
            cwd: "/tmp/agent-history-tests/zentty", createdAtMs: nowMs - 100_000,
            updatedAtMs: nowMs - id * 1000, turnCount: 4
        )
    }

    private func metadata(_ session: AgentHistorySessionSummary) -> HistoryMetadataResult {
        HistoryMetadataResult(
            session: session, score: 1, isWordLevel: true,
            titleHighlights: [NSRange(location: 0, length: 3)], note: nil
        )
    }

    private func content(_ session: AgentHistorySessionSummary) -> HistoryContentResult {
        HistoryContentResult(
            session: session,
            best: HistoryContentHit(
                sessionID: session.id, rowID: session.id * 10, role: .agent, atMs: nowMs - 5000,
                gradedQuality: 1, isWordLevel: true
            ),
            bestQualityHits: 1, totalHits: 1, score: 1, isWordLevel: true,
            snippet: HistorySnippet(
                text: "the crash is fixed", highlights: [NSRange(location: 4, length: 5)],
                truncatedStart: false, truncatedEnd: false
            ),
            note: nil, titleHighlights: []
        )
    }

    private func contentResponse(_ results: [HistoryContentResult]) -> HistoryContentResponse {
        HistoryContentResponse(
            query: HistoryQueryParser.parse("crash"), generation: 0, results: results,
            enrichments: [:], mode: .fts, truncated: false, elapsed: 0
        )
    }

    private func makeModel() -> AgentHistoryViewModel {
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { completion in
                completion(ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                ))
            },
            raiseClaudeRetention: { $0(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: AgentHistoryTestPasteboard.make(),
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { [nowMs, scheduler] in
                Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000 + (scheduler?.now ?? 0))
            }
        )
        let context = AgentHistoryOpenContext(
            entryPoint: .shortcutOrMenu,
            currentProject: nil,
            initialScope: .all,
            hostWindowID: WindowID("window")
        )
        let model = AgentHistoryViewModel(
            context: context,
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: scheduler
        )
        model.onRequestClose = { [weak self] restoreFocus in
            self?.closeRequests.append(restoreFocus)
        }
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private let transcript = HistoryTranscript(turns: [], firstMatchMessageID: nil, isTruncated: false)

    /// A typed search for "crash": Claude session 1 by title, Codex session 3 by title and Claude
    /// session 2 in conversations; session 1 previewed with its transcript open.
    private func openTypedSearch(metadata: @escaping () -> [HistoryMetadataResult]) -> AgentHistoryViewModel {
        search.metadataResults = { _ in metadata() }
        let model = makeModel()
        model.start()
        model.updateQuery("crash")
        scheduler.advance(by: 0.12)
        search.pendingContent.last?.completion(.success(contentResponse([content(summary(2, agent: .claude))])))
        search.pendingPreviews.last?.completion(
            .success(HistoryPreview(session: summary(1, agent: .claude), turns: [], turnsAreMatches: true))
        )
        model.toggleTranscript()
        search.pendingTranscripts.last?.completion(.success(transcript))

        XCTAssertEqual(model.rows.map(\.sessionID), [1, 3, 2])
        XCTAssertEqual(model.selectedKey, summary(1, agent: .claude).key)
        XCTAssertEqual(model.detail, .transcript)
        XCTAssertEqual(model.transcript, .loaded(transcript))
        guard case .loaded = model.preview else {
            XCTFail("preview should be loaded before access changes")
            return model
        }
        return model
    }

    private func assertNothingShown(_ model: AgentHistoryViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.sections.isEmpty, "no rows stay on screen", file: file, line: line)
        XCTAssertNil(model.selectedKey, file: file, line: line)
        XCTAssertEqual(model.preview, .idle, file: file, line: line)
        XCTAssertEqual(model.transcript, .idle, file: file, line: line)
        XCTAssertEqual(model.detail, .none, file: file, line: line)
        XCTAssertNil(model.folderSheet, file: file, line: line)
        XCTAssertNotEqual(model.body, .results, "the results body is gone at once", file: file, line: line)
    }

    // MARK: - Turned off or index deleted

    func test_turning_history_off_clears_an_open_typed_search_and_closes() {
        let model = openTypedSearch { [self.metadata(self.summary(1, agent: .claude)), self.metadata(self.summary(3))] }

        var status = control.status
        status.isEnabled = false
        status.state = .off
        status.revision = 2
        control.publish(status)

        assertNothingShown(model)
        XCTAssertEqual(closeRequests, [false], "the palette closes without pulling focus from Settings")
        XCTAssertEqual(control.observerCount, 0, "nothing more is heard after access is gone")
    }

    func test_deleting_the_index_drops_late_results_preview_and_transcript() {
        let model = openTypedSearch { [self.metadata(self.summary(1, agent: .claude)), self.metadata(self.summary(3))] }
        // A new keystroke and selection put a content search, a preview and a transcript in flight.
        model.updateQuery("crash fix")
        scheduler.advance(by: 0.12)
        model.toggleTranscript()
        XCTAssertEqual(model.detail, .transcript)
        let contentLoad = search.pendingContent.last
        let preview = search.pendingPreviews.last
        let transcriptLoad = search.pendingTranscripts.last

        var status = control.status
        status.isEnabled = false
        status.hasConsented = false
        status.enabledAgents = []
        status.state = .off
        status.indexExists = false
        status.revision = 2
        control.publish(status)

        XCTAssertEqual(contentLoad?.token.isCancelled, true)
        XCTAssertEqual(preview?.token.isCancelled, true)
        XCTAssertEqual(transcriptLoad?.token.isCancelled, true)
        contentLoad?.completion(.success(contentResponse([content(summary(2, agent: .claude))])))
        preview?.completion(.success(HistoryPreview(session: summary(1, agent: .claude), turns: [], turnsAreMatches: true)))
        transcriptLoad?.completion(.success(transcript))
        scheduler.advance(by: 5)

        assertNothingShown(model)
        XCTAssertEqual(closeRequests, [false])
    }

    // MARK: - Agent turned off or folder excluded

    func test_turning_an_agent_off_reruns_the_typed_query_and_closes_its_transcript() {
        var visible: [HistoryMetadataResult] = [metadata(summary(1, agent: .claude)), metadata(summary(3))]
        let model = openTypedSearch { visible }
        let queries = search.metadataQueries.count

        // The engine hides Claude at once (its purge may come later).
        visible = [metadata(summary(3))]
        var status = control.status
        status.enabledAgents = [.codex]
        status.revision = 2
        control.publish(status)

        XCTAssertEqual(search.metadataQueries.count, queries + 1, "the typed query runs again")
        XCTAssertEqual(model.rows.map(\.sessionID), [3], "Claude's title and conversation rows are gone")
        XCTAssertEqual(model.selectedKey, summary(3).key)
        XCTAssertEqual(model.detail, .none, "the hidden session's transcript closes")
        XCTAssertEqual(model.transcript, .idle)
        XCTAssertNotEqual(model.preview, .loaded(HistoryPreview(session: summary(1, agent: .claude), turns: [], turnsAreMatches: true)))
        XCTAssertEqual(model.body, .results)
        XCTAssertTrue(closeRequests.isEmpty, "the palette stays open for the agents still on")
    }

    func test_excluding_a_folder_reruns_the_typed_query() {
        var visible: [HistoryMetadataResult] = [metadata(summary(1, agent: .claude)), metadata(summary(3))]
        let model = openTypedSearch { visible }
        let queries = search.metadataQueries.count

        visible = [metadata(summary(3))]
        var status = control.status
        status.excludedFolders = ["/tmp/agent-history-tests/zentty/secret"]
        status.revision = 2
        control.publish(status)

        XCTAssertEqual(search.metadataQueries.count, queries + 1, "the typed query runs again")
        XCTAssertEqual(model.rows.map(\.sessionID), [3], "stale conversation rows are dropped, not kept")
        XCTAssertEqual(model.detail, .none)
        XCTAssertEqual(model.transcript, .idle)
        XCTAssertTrue(closeRequests.isEmpty)

        // The re-run content search finds nothing in the excluded folder.
        scheduler.advance(by: 0.12)
        search.pendingContent.last?.completion(.success(contentResponse([])))
        XCTAssertEqual(model.rows.map(\.sessionID), [3])
    }

    func test_an_unrelated_status_change_keeps_a_typed_search_as_is() {
        let model = openTypedSearch { [self.metadata(self.summary(1, agent: .claude)), self.metadata(self.summary(3))] }
        let queries = search.metadataQueries.count

        var status = control.status
        status.indexedSessions = 4
        status.revision = 2
        control.publish(status)

        XCTAssertEqual(search.metadataQueries.count, queries)
        XCTAssertEqual(model.rows.map(\.sessionID), [1, 3, 2])
        XCTAssertEqual(model.transcript, .loaded(transcript))
        XCTAssertTrue(closeRequests.isEmpty)
    }
}
