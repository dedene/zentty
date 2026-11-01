import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryTranscriptViewTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var scheduler: ManualAgentHistoryScheduler!

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 1
        status.tokenizer = .trigram
        status.revision = 1
        control.status = status
        search = FakeAgentHistorySearch()
        scheduler = ManualAgentHistoryScheduler()
    }

    // MARK: - Fixtures

    private func summary(_ id: Int64) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: .claude,
            nativeID: "native-\(id)", title: "Session \(id)", titleKind: .generated,
            cwd: "/tmp/agent-history-tests/zentty", createdAtMs: nowMs - 100_000,
            updatedAtMs: nowMs - id * 1000, turnCount: 4
        )
    }

    private func turns(_ count: Int, highlightedAt matchIndex: Int? = nil) -> [HistoryTurnMatch] {
        (0..<count).map { index in
            HistoryTurnMatch(
                messageID: Int64(index + 1),
                seq: index,
                role: index.isMultiple(of: 2) ? .user : .agent,
                at: Date(timeIntervalSince1970: TimeInterval(nowMs / 1000 - Int64(count - index))),
                text: "turn \(index)",
                highlights: index == matchIndex ? [NSRange(location: 0, length: 4)] : []
            )
        }
    }

    private func makeModel() -> AgentHistoryViewModel {
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: FakeAgentHistoryLaunch(),
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
            now: { [nowMs] in Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }
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
            scheduler: scheduler,
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// Opens the transcript for the first recent session and completes its load.
    private func openTranscript(_ transcript: HistoryTranscript) -> AgentHistoryViewModel {
        search.recent = [summary(1)]
        let model = makeModel()
        model.start()
        scheduler.advance(by: 1)
        model.toggleTranscript()
        search.pendingTranscripts.last?.completion(.success(transcript))
        return model
    }

    // MARK: - Tests

    func test_transcript_shows_truncation_note_over_2000() throws {
        let limit = HistorySearchEngine.transcriptLimit
        let truncated = HistoryTranscript(turns: turns(limit), firstMatchMessageID: nil, isTruncated: true)
        let model = openTranscript(truncated)

        let presentation = try XCTUnwrap(model.transcriptPresentation)
        XCTAssertEqual(presentation.turns.count, limit)
        XCTAssertEqual(presentation.truncationNote, "Showing the latest 2,000 turns. Earlier turns aren't shown.")

        let complete = HistoryTranscript(turns: turns(12), firstMatchMessageID: nil, isTruncated: false)
        let shortModel = openTranscript(complete)
        XCTAssertNil(try XCTUnwrap(shortModel.transcriptPresentation).truncationNote)
    }

    func test_transcript_scrolls_to_first_match_else_top() throws {
        let matched = HistoryTranscript(turns: turns(6, highlightedAt: 3), firstMatchMessageID: 4, isTruncated: false)
        let model = openTranscript(matched)
        XCTAssertEqual(try XCTUnwrap(model.transcriptPresentation).scrollTargetID, 4)

        let unmatched = HistoryTranscript(turns: turns(6), firstMatchMessageID: nil, isTruncated: false)
        XCTAssertNil(try XCTUnwrap(openTranscript(unmatched).transcriptPresentation).scrollTargetID)

        let stale = HistoryTranscript(turns: turns(3), firstMatchMessageID: 99, isTruncated: false)
        XCTAssertNil(
            try XCTUnwrap(openTranscript(stale).transcriptPresentation).scrollTargetID,
            "a match outside the loaded turns never becomes a scroll target"
        )
    }

    func test_transcript_presentation_only_while_transcript_is_shown_and_loaded() {
        search.recent = [summary(1)]
        let model = makeModel()
        model.start()
        scheduler.advance(by: 1)
        XCTAssertNil(model.transcriptPresentation, "hidden")

        model.toggleTranscript()
        XCTAssertNil(model.transcriptPresentation, "loading")

        let transcript = HistoryTranscript(turns: turns(2), firstMatchMessageID: nil, isTruncated: false)
        search.pendingTranscripts.last?.completion(.success(transcript))
        XCTAssertEqual(model.transcriptPresentation?.turns, transcript.turns)

        model.toggleTranscript()
        XCTAssertNil(model.transcriptPresentation, "closed")
    }
}
