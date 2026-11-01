import XCTest
@testable import Zentty

/// The palette opened before `state.json` was read (the launch read waits a few seconds), or
/// while consent gets recorded elsewhere. It must never ask a returning user for consent, and
/// it must never offer agent choices that `enable` would ignore because consent is already saved.
@MainActor
final class AgentHistoryPaletteStateLoadTests: XCTestCase {
    private let root = "/tmp/agent-history-state-load-tests"
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var savedExclusions: [[String]] = []

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        control.detectedSources = [
            AgentHistoryDetectedSource(agent: .claude, rootPath: "\(root)/.claude", isFound: true,
                                       sessionCount: 12, checkedPaths: ["\(root)/.claude"], problem: nil),
            AgentHistoryDetectedSource(agent: .codex, rootPath: "\(root)/.codex", isFound: true,
                                       sessionCount: 3, checkedPaths: ["\(root)/.codex"], problem: nil),
        ]
        search = FakeAgentHistorySearch()
        savedExclusions = []
    }

    // MARK: - Fixtures

    private func makeModel() -> AgentHistoryViewModel {
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: FakeAgentHistoryLaunch(),
            excludedFolders: { [] },
            setExcludedFolders: { [unowned self] in self.savedExclusions.append($0) },
            claudeRetention: { [root] in
                ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "\(root)/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "\(root)/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )
            },
            raiseClaudeRetention: { .alreadySufficient(currentDays: 365) },
            pasteboard: AgentHistoryTestPasteboard.make(),
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
            scheduler: ManualAgentHistoryScheduler(),
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// What the launch read publishes for a returning user: consented, indexing.
    private func loadedConsented(revision: UInt64) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = [.claude]
        status.state = .watching
        status.indexedSessions = 12
        status.revision = revision
        return status
    }

    private func loadedUnconsented(revision: UInt64) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.revision = revision
        return status
    }

    // MARK: - Before state.json is read

    func test_palette_opened_before_the_saved_state_loads_waits_and_never_asks_a_returning_user() {
        control.status = .off
        let model = makeModel()
        model.start()

        XCTAssertEqual(model.body, .loading, "the placeholder status says nothing about consent")
        XCTAssertNil(model.consent)
        XCTAssertEqual(control.refreshCount, 1, "the palette asks for the saved state now")

        control.publish(loadedConsented(revision: 1))

        XCTAssertEqual(model.body, .results)
        XCTAssertNil(model.consent)
        XCTAssertEqual(search.recentScopes, [.all], "the returning user's recent sessions are listed")
        model.confirmConsent()
        XCTAssertTrue(control.enabledAgents.isEmpty)
    }

    func test_palette_opened_before_the_saved_state_loads_shows_the_card_once_it_says_not_consented() {
        control.status = .off
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.body, .loading)

        control.publish(loadedUnconsented(revision: 1))

        XCTAssertEqual(model.body, .consent)
        XCTAssertEqual(model.consent?.enabledAgents, [.claude, .codex])
    }

    // MARK: - Consent recorded elsewhere

    func test_consent_recorded_while_the_probe_runs_shows_results_not_the_card() {
        control.holdsDetection = true
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.body, .loading)

        control.publish(loadedConsented(revision: 1))
        XCTAssertEqual(model.body, .results)

        control.releaseDetections()
        XCTAssertEqual(model.body, .results, "the late probe doesn't bring the card back")
        XCTAssertNil(model.consent)
    }

    func test_consent_recorded_while_the_card_shows_replaces_it_with_results() {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.body, .consent)
        model.setConsentSource(.codex, enabled: false)

        control.publish(loadedConsented(revision: 1))

        XCTAssertEqual(model.body, .results, "the card's choices would be ignored now")
        XCTAssertNil(model.consent)
        model.confirmConsent()
        XCTAssertTrue(control.enabledAgents.isEmpty)
    }

    /// The submitted-set contract: `enable` keeps saved choices once consent exists, so the
    /// card never submits edited choices over saved consent. It shows the results instead.
    func test_confirm_after_consent_was_saved_elsewhere_submits_nothing() {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.body, .consent)
        model.setConsentSource(.codex, enabled: false)
        model.addExcludedFolders([URL(fileURLWithPath: "\(root)/private")])

        // Saved before its observers hear about it.
        control.status = loadedConsented(revision: 1)
        model.confirmConsent()

        XCTAssertTrue(control.enabledAgents.isEmpty, "no choices are sent that enable would drop")
        XCTAssertTrue(savedExclusions.isEmpty, "nothing from the stale card is saved")
        XCTAssertEqual(model.body, .results)
        XCTAssertNil(model.consent)
    }

    func test_confirm_on_a_loaded_unconsented_status_submits_the_checked_agents() {
        let model = makeModel()
        model.start()
        model.setConsentSource(.codex, enabled: false)

        model.confirmConsent()

        XCTAssertEqual(control.enabledAgents, [[.claude]])
    }
}
