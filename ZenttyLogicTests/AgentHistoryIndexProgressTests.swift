import XCTest
@testable import Zentty

/// The initial index stays visible after the setup card has gone: a count and time left in the
/// footer, and details one click away.
@MainActor
final class AgentHistoryIndexProgressTests: XCTestCase {
    private var control: FakeAgentHistoryControl!
    private var scheduler: ManualAgentHistoryScheduler!
    private var closeRequests: [Bool] = []

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        scheduler = ManualAgentHistoryScheduler()
        closeRequests = []
    }

    private func progress(_ indexed: Int, of total: Int, secondsLeft: TimeInterval? = nil) -> AgentHistoryBackfillProgress {
        AgentHistoryBackfillProgress(
            indexedSessions: indexed, totalSessions: total, estimatedSecondsRemaining: secondsLeft
        )
    }

    private func status(_ state: AgentHistoryIndexerState) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = [.claude, .codex]
        status.state = state
        status.indexedSessions = 312
        status.tokenizer = .trigram
        status.revision = 1
        status.sources = [
            AgentHistorySourceHealth(agent: .claude, root: "/tmp/.claude", isDefaultRoot: true, discovered: 1_000, indexed: 300),
            AgentHistorySourceHealth(agent: .codex, root: "/tmp/.codex", isDefaultRoot: true, discovered: 284, indexed: 12),
            AgentHistorySourceHealth(agent: .grok, root: "/tmp/.grok", isDefaultRoot: true, isEnabled: false, discovered: 9),
        ]
        return status
    }

    private func makeModel() -> AgentHistoryViewModel {
        if control.status.state == .off {
            control.status = status(.backfilling(progress(312, of: 1_284)))
        }
        let pasteboard = AgentHistoryTestPasteboard.make()
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        let services = AgentHistoryPaletteServices(
            control: control,
            search: FakeAgentHistorySearch(),
            launch: FakeAgentHistoryLaunch(),
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { _, completion in completion([]) },
            raiseClaudeRetention: { $1(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: pasteboard,
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let model = AgentHistoryViewModel(
            context: AgentHistoryOpenContext(
                entryPoint: .shortcutOrMenu, currentProject: nil, initialScope: .all, hostWindowID: WindowID("window")
            ),
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: scheduler,
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        model.onRequestClose = { [weak self] in self?.closeRequests.append($0) }
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    func test_footer_shows_count_time_left_and_a_way_to_the_details() throws {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284, secondsLeft: 720))))

        XCTAssertEqual(model.footer.health.text, "Indexing 312 of 1,284 sessions · about 10 min left")
        let details = try XCTUnwrap(model.footer.indexProgress)
        XCTAssertEqual(details.fraction, 312.0 / 1_284.0, accuracy: 0.0001)
        XCTAssertEqual(details.rows.map(\.agent), [.claude, .codex], "turned-off agents aren't listed")
        XCTAssertEqual(details.rows.first?.indexed, 300)
        XCTAssertEqual(details.rows.first?.total, 1_000)
    }

    func test_paused_footer_keeps_the_count_and_the_details() {
        let model = makeModel()
        model.start()
        control.publish(status(.paused(.lowPower, progress(2, of: 5_921))))

        XCTAssertEqual(model.footer.health.text, "Indexing paused while Low Power Mode is on · 2 of 5,921")
        XCTAssertTrue(model.footer.health.isWarning)
        XCTAssertNotNil(model.footer.indexProgress)
    }

    func test_details_open_from_the_footer_and_escape_goes_back_before_closing() {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284))))

        model.toggleIndexProgress()
        XCTAssertTrue(model.isShowingIndexProgress)

        model.escape()
        XCTAssertFalse(model.isShowingIndexProgress)
        XCTAssertTrue(closeRequests.isEmpty, "the first Esc only leaves the details")

        model.escape()
        XCTAssertEqual(closeRequests, [true])
    }

    func test_typing_returns_to_results() {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284))))
        model.toggleIndexProgress()

        model.updateQuery("cache")

        XCTAssertFalse(model.isShowingIndexProgress)
    }

    func test_return_goes_back_instead_of_resuming_the_hidden_row() {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284))))
        model.toggleIndexProgress()

        model.performSelected(.primary)

        XCTAssertFalse(model.isShowingIndexProgress)
    }

    func test_details_close_when_the_backfill_finishes() {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284))))
        model.toggleIndexProgress()

        control.publish(status(.watching))

        XCTAssertFalse(model.isShowingIndexProgress)
        XCTAssertNil(model.footer.indexProgress)
    }

    func test_toggle_does_nothing_without_an_index_in_progress() {
        control.status = status(.watching)
        let model = makeModel()
        model.start()

        model.toggleIndexProgress()

        XCTAssertFalse(model.isShowingIndexProgress)
    }

    func test_nothing_to_show_before_sessions_are_found() {
        XCTAssertNil(AgentHistoryIndexProgress(status: status(.backfilling(progress(0, of: 0)))))
        XCTAssertNil(AgentHistoryIndexProgress(status: status(.paused(.lowPower, nil))))
        XCTAssertNil(AgentHistoryIndexProgress(status: status(.paused(.diskFull, progress(9, of: 9)))))
    }

    func test_turning_history_off_closes_the_details() {
        let model = makeModel()
        model.start()
        control.publish(status(.backfilling(progress(312, of: 1_284))))
        model.toggleIndexProgress()

        var off = status(.off)
        off.isEnabled = false
        control.publish(off)

        XCTAssertFalse(model.isShowingIndexProgress)
    }
}
