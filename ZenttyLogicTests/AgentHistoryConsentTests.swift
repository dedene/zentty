import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryConsentTests: XCTestCase {
    private let root = "/tmp/agent-history-consent-tests"
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var launch: FakeAgentHistoryLaunch!
    private var scheduler: ManualAgentHistoryScheduler!
    private var excludedFolders: [String] = []
    private var savedExclusions: [[String]] = []
    private var saveExclusionsError: Error?
    private var retention: ClaudeRetentionStatus!
    private var raiseResult: Result<ClaudeRetentionWriteOutcome, Error> = .success(.written(backupURL: nil))
    private var raiseCount = 0
    private var closeRequests: [Bool] = []
    private var folderPickerRequests = 0

    private let formatting = AgentHistoryFormatting(locale: Locale(identifier: "en_US"))

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        control.status = AgentHistoryStatus.off
        search = FakeAgentHistorySearch()
        launch = FakeAgentHistoryLaunch()
        scheduler = ManualAgentHistoryScheduler()
        excludedFolders = []
        savedExclusions = []
        saveExclusionsError = nil
        retention = retentionStatus(days: 365, source: .userSettings)
        raiseResult = .success(.written(backupURL: nil))
        raiseCount = 0
        closeRequests = []
        folderPickerRequests = 0
    }

    // MARK: - Fixtures

    nonisolated private func retentionStatus(
        days: Int,
        source: ClaudeRetentionStatus.Source,
        error: ClaudeRetentionSettingsError? = nil
    ) -> ClaudeRetentionStatus {
        ClaudeRetentionStatus(
            configDirectory: URL(fileURLWithPath: "\(root)/.claude"),
            settingsFileURL: URL(fileURLWithPath: "\(root)/.claude/settings.json"),
            effectiveDays: days, source: source, readError: error
        )
    }

    private func found(_ agent: AgentHistoryAgent, _ path: String, count: Int?) -> AgentHistoryDetectedSource {
        AgentHistoryDetectedSource(agent: agent, rootPath: "\(root)/\(path)", isFound: true,
                                   sessionCount: count, checkedPaths: ["\(root)/\(path)"], problem: nil)
    }

    private func missing(_ agent: AgentHistoryAgent, checked: [String]) -> AgentHistoryDetectedSource {
        AgentHistoryDetectedSource(agent: agent, rootPath: nil, isFound: false, sessionCount: nil,
                                   checkedPaths: checked, problem: nil)
    }

    private var typicalSources: [AgentHistoryDetectedSource] {
        [
            found(.claude, ".claude", count: 1200),
            found(.codex, ".codex", count: 84),
            missing(.grok, checked: ["\(root)/.grok"]),
            found(.opencode, ".local/share/opencode", count: nil),
        ]
    }

    private func health(_ agent: AgentHistoryAgent, _ path: String, discovered: Int, indexed: Int) -> AgentHistorySourceHealth {
        AgentHistorySourceHealth(
            agent: agent, root: "\(root)/\(path)", isDefaultRoot: true, discovered: discovered, indexed: indexed
        )
    }

    private func makeModel() -> AgentHistoryViewModel {
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [unowned self] in self.excludedFolders },
            setExcludedFolders: { [unowned self] folders in
                if let error = self.saveExclusionsError { throw error }
                self.savedExclusions.append(folders)
                self.excludedFolders = folders
            },
            claudeRetention: { [unowned self] in self.retention },
            raiseClaudeRetention: { [unowned self] in
                self.raiseCount += 1
                return try self.raiseResult.get()
            },
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
            scheduler: scheduler,
            formatting: formatting
        )
        model.onRequestClose = { [unowned self] restoreFocus in self.closeRequests.append(restoreFocus) }
        model.onRequestFolderPicker = { [unowned self] in self.folderPickerRequests += 1 }
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func startedConsent(_ sources: [AgentHistoryDetectedSource]? = nil) -> AgentHistoryViewModel {
        control.detectedSources = sources ?? typicalSources
        let model = makeModel()
        model.start()
        return model
    }

    // MARK: - Detection

    func test_not_consented_detects_sources_and_shows_consent() throws {
        let model = startedConsent()

        XCTAssertEqual(model.body, .consent)
        let consent = try XCTUnwrap(model.consent)
        XCTAssertEqual(consent.rows.map(\.agent), [.claude, .codex, .grok, .opencode])
        XCTAssertEqual(consent.rows.map(\.isFound), [true, true, false, true])
        XCTAssertEqual(consent.rows.map(\.isEnabled), [true, true, false, true], "found sources start checked")
        XCTAssertEqual(consent.enabledAgents, [.claude, .codex, .opencode])
        XCTAssertFalse(consent.isIndexing)
        XCTAssertTrue(consent.canConfirm)
        XCTAssertTrue(control.enabledAgents.isEmpty, "showing the card persists nothing")
    }

    func test_no_sources_found_shows_no_agents_with_checked_paths() {
        let model = startedConsent([
            missing(.claude, checked: ["\(root)/.claude"]),
            missing(.codex, checked: ["\(root)/.codex"]),
        ])

        XCTAssertEqual(model.body, .noAgents(checkedPaths: ["\(root)/.claude", "\(root)/.codex"]))
        XCTAssertNil(model.consent)
        XCTAssertTrue(AgentHistoryNoAgentsView.title.hasPrefix("No conversations from Claude Code"))
    }

    func test_consent_model_totals_found_sessions_and_database_sources_show_found_without_count() {
        let consent = AgentHistoryConsentModel.make(detected: typicalSources, excluded: [], retention: nil)

        XCTAssertEqual(consent.totalFound, 1284)
        XCTAssertEqual(consent.selectedSessionCount, 1284)
        XCTAssertEqual(consent.uncountedAgents, [.opencode])
        let counts = consent.rows.map { consent.countText(for: $0, formatting: formatting) }
        XCTAssertEqual(counts, ["1,200 sessions", "84 sessions", "Not found", "Found"])
        XCTAssertEqual(consent.confirmTitle(formatting: formatting), "Index 1,284 Sessions")
        XCTAssertTrue(consent.bodyText(formatting: formatting).hasPrefix(
            "Zentty found 1,284 conversations on this Mac, plus the ones in \(AgentHistoryAgent.opencode.displayName)."
        ))

        var unchecked = consent
        unchecked.setEnabled(.claude, false)
        XCTAssertEqual(unchecked.totalFound, 1284, "the body counts every found source")
        XCTAssertEqual(unchecked.confirmTitle(formatting: formatting), "Index 84 Sessions")
        unchecked.setEnabled(.grok, true)
        XCTAssertFalse(unchecked.rows[2].isEnabled, "a missing agent can't be checked")

        let databaseOnly = AgentHistoryConsentModel.make(
            detected: [found(.opencode, "opencode", count: nil)], excluded: [], retention: nil
        )
        XCTAssertEqual(databaseOnly.totalFound, 0)
        XCTAssertEqual(databaseOnly.confirmTitle(formatting: formatting), "Index Sessions")
        XCTAssertTrue(databaseOnly.canConfirm)
        XCTAssertTrue(databaseOnly.bodyText(formatting: formatting).hasPrefix("Zentty found agent conversations on this Mac."))
    }

    // MARK: - Claude retention

    func test_retention_nudge_only_when_eligible() {
        retention = retentionStatus(days: 30, source: .defaultValue)
        let eligible = startedConsent()
        XCTAssertEqual(eligible.consent?.showsRetentionNudge, true)
        XCTAssertEqual(
            eligible.consent?.retentionNudgeText,
            "Claude Code deletes conversations after 30 days, so they'll drop out of Agent History too."
        )

        for status in [
            retentionStatus(days: 365, source: .userSettings),
            retentionStatus(days: 30, source: .managedSettings),
            retentionStatus(days: 0, source: .userSettings),
            retentionStatus(days: 30, source: .defaultValue, error: .invalidJSON(path: "\(root)/.claude/settings.json")),
        ] {
            retention = status
            let model = startedConsent()
            XCTAssertEqual(model.consent?.showsRetentionNudge, false, "\(status)")
            XCTAssertNil(model.consent?.retentionNudgeText)
        }

        retention = retentionStatus(days: 30, source: .defaultValue)
        let withoutClaude = startedConsent([found(.codex, ".codex", count: 3)])
        XCTAssertNil(withoutClaude.consent?.retention, "retention is read only when Claude Code was found")
        XCTAssertEqual(withoutClaude.consent?.showsRetentionNudge, false)
    }

    func test_keep_one_year_failure_sets_error_and_changes_nothing() {
        retention = retentionStatus(days: 30, source: .defaultValue)
        raiseResult = .failure(ClaudeRetentionSettingsError.invalidJSON(path: "\(root)/.claude/settings.json"))
        let model = startedConsent()
        let before = model.consent

        model.keepClaudeConversationsOneYear()

        XCTAssertEqual(raiseCount, 1)
        XCTAssertEqual(model.consent?.retentionError, "Claude's settings.json isn't valid JSON; nothing was changed.")
        XCTAssertEqual(model.consent?.retention, before?.retention)
        XCTAssertEqual(model.consent?.showsRetentionNudge, true, "the nudge stays so the user can retry")
        XCTAssertEqual(model.consent?.didRaiseRetention, false)
        XCTAssertEqual(model.body, .consent)
        XCTAssertTrue(control.enabledAgents.isEmpty)
        XCTAssertTrue(savedExclusions.isEmpty)

        raiseResult = .success(.written(backupURL: nil))
        retention = retentionStatus(days: 365, source: .userSettings)
        model.keepClaudeConversationsOneYear()
        XCTAssertNil(model.consent?.retentionError)
        XCTAssertEqual(model.consent?.retention?.effectiveDays, 365)
        XCTAssertEqual(model.consent?.showsRetentionNudge, false)
        XCTAssertEqual(model.consent?.didRaiseRetention, true)
    }

    // MARK: - Excluded folders

    func test_excluded_folders_standardized_and_deduplicated() {
        excludedFolders = ["\(root)/secrets"]
        let model = startedConsent()
        XCTAssertEqual(model.consent?.excludedFolders, ["\(root)/secrets"])

        model.requestAddExcludedFolder()
        XCTAssertEqual(folderPickerRequests, 1)
        model.addExcludedFolders([
            URL(fileURLWithPath: "\(root)/secrets/"),
            URL(fileURLWithPath: "\(root)/clients/acme/../acme-secure"),
            URL(fileURLWithPath: "\(root)/clients/acme-secure"),
        ])
        XCTAssertEqual(model.consent?.excludedFolders, ["\(root)/secrets", "\(root)/clients/acme-secure"])

        model.removeExcludedFolder("\(root)/secrets/")
        XCTAssertEqual(model.consent?.excludedFolders, ["\(root)/clients/acme-secure"])
        XCTAssertTrue(savedExclusions.isEmpty, "folders are saved on confirm, not while editing")

        XCTAssertEqual(
            AgentHistoryConsentModel.normalizedFolders(["  ~/a/  ", "relative", "", "~/a"]),
            [(("~/a") as NSString).expandingTildeInPath]
        )
    }

    // MARK: - Confirm and decline

    func test_confirm_enables_agents_and_disables_checkboxes() {
        excludedFolders = ["\(root)/old"]
        let model = startedConsent()
        model.setConsentSource(.codex, enabled: false)
        model.addExcludedFolders([URL(fileURLWithPath: "\(root)/private")])

        model.handle(.consentConfirm)

        XCTAssertEqual(savedExclusions, [["\(root)/old", "\(root)/private"]], "exclusions are saved before indexing starts")
        XCTAssertEqual(control.enabledAgents, [[.claude, .opencode]])
        XCTAssertEqual(model.consent?.isIndexing, true)
        XCTAssertEqual(model.consent?.canConfirm, false)
        XCTAssertEqual(model.body, .consent)

        model.setConsentSource(.codex, enabled: true)
        model.addExcludedFolders([URL(fileURLWithPath: "\(root)/late")])
        model.removeExcludedFolder("\(root)/old")
        model.requestAddExcludedFolder()
        XCTAssertEqual(model.consent?.enabledAgents, [.claude, .opencode], "checkboxes are locked while indexing")
        XCTAssertEqual(model.consent?.excludedFolders, ["\(root)/old", "\(root)/private"])
        XCTAssertEqual(folderPickerRequests, 0)

        model.confirmConsent()
        XCTAssertEqual(control.enabledAgents.count, 1, "a second confirm does nothing")
    }

    func test_confirm_does_not_enable_when_excluded_folders_cannot_be_saved() throws {
        saveExclusionsError = AgentHistoryExcludedFoldersSaveError.notSaved
        let model = startedConsent()
        model.addExcludedFolders([URL(fileURLWithPath: "\(root)/clients/secret")])

        model.handle(.consentConfirm)

        XCTAssertTrue(control.enabledAgents.isEmpty, "nothing is indexed when the exclusions weren't saved")
        let consent = try XCTUnwrap(model.consent)
        XCTAssertFalse(consent.isIndexing)
        XCTAssertTrue(consent.canConfirm, "the card stays editable so the user can retry")
        XCTAssertEqual(consent.saveError, AgentHistoryConsentModel.excludedFoldersSaveError)
        XCTAssertEqual(consent.excludedFolders, ["\(root)/clients/secret"])
        XCTAssertEqual(model.body, .consent)

        saveExclusionsError = nil
        model.handle(.consentConfirm)

        XCTAssertEqual(savedExclusions, [["\(root)/clients/secret"]])
        XCTAssertEqual(control.enabledAgents.count, 1, "a retry after a successful save enables indexing")
        XCTAssertNil(model.consent?.saveError)
        XCTAssertEqual(model.consent?.isIndexing, true)
    }

    func test_switches_to_results_after_50_sessions_indexed() throws {
        let model = startedConsent()
        model.confirmConsent()

        var status = control.status
        status.isEnabled = true
        status.hasConsented = true
        status.state = .backfilling(AgentHistoryBackfillProgress(indexedSessions: 49, totalSessions: 1284))
        status.indexedSessions = 49
        status.sources = [
            health(.claude, ".claude", discovered: 1200, indexed: 40),
            health(.codex, ".codex", discovered: 84, indexed: 9),
        ]
        status.revision = 2
        control.publish(status)

        XCTAssertEqual(model.body, .consent)
        let consent = try XCTUnwrap(model.consent)
        XCTAssertEqual(consent.overallProgress, AgentHistoryConsentProgress(indexed: 49, total: 1284))
        XCTAssertEqual(consent.overallProgress?.fraction ?? 0, 49.0 / 1284.0, accuracy: 0.0001)
        XCTAssertEqual(consent.rows[0].progress, AgentHistoryConsentProgress(indexed: 40, total: 1200))
        XCTAssertEqual(consent.countText(for: consent.rows[0], formatting: formatting), "40 / 1,200")
        XCTAssertEqual(consent.countText(for: consent.rows[3], formatting: formatting), "Found")

        status.state = .backfilling(AgentHistoryBackfillProgress(indexedSessions: 50, totalSessions: 1284))
        status.indexedSessions = 50
        status.revision = 3
        control.publish(status)
        XCTAssertEqual(model.body, .results)

        control.status = .off
        let watching = startedConsent()
        XCTAssertEqual(watching.body, .consent)
        watching.confirmConsent()
        status.state = .watching
        status.indexedSessions = 12
        status.revision = 4
        control.publish(status)
        XCTAssertEqual(watching.body, .results, "a small history that finished indexing shows results")
    }

    func test_decline_requests_close_without_persisting() {
        let model = startedConsent()
        model.addExcludedFolders([URL(fileURLWithPath: "\(root)/private")])

        model.declineConsent()
        XCTAssertEqual(closeRequests, [true])

        model.handle(.escape)
        XCTAssertEqual(closeRequests, [true, true], "esc on the card is Not Now")

        XCTAssertTrue(control.enabledAgents.isEmpty)
        XCTAssertTrue(control.setEnabledCalls.isEmpty)
        XCTAssertTrue(savedExclusions.isEmpty)
        XCTAssertEqual(raiseCount, 0)
    }

    // MARK: - Index state bodies

    func test_index_failure_shows_unavailable_and_rebuild_calls_control() {
        let model = startedConsent()
        model.confirmConsent()

        var status = control.status
        status.isEnabled = true
        status.hasConsented = true
        status.state = .failed(.corrupt)
        status.revision = 2
        control.publish(status)
        XCTAssertEqual(model.body, .indexUnavailable(.corrupt))
        XCTAssertTrue(AgentHistoryIndexUnavailableView.offersRebuild(.corrupt, isDiskFullPause: false))

        model.rebuildIndex()
        XCTAssertEqual(control.rebuildCount, 1)

        status.state = .backfilling(AgentHistoryBackfillProgress(indexedSessions: 0, totalSessions: 10))
        status.revision = 3
        control.publish(status)
        XCTAssertEqual(model.body, .results, "the rebuilt index searches while it fills")
    }

    func test_newer_schema_shows_unavailable() {
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .failed(.newerSchema(found: 9))
        control.status = status
        let model = makeModel()
        model.start()

        XCTAssertEqual(model.body, .indexUnavailable(.newerSchema(found: 9)))
        XCTAssertEqual(
            AgentHistoryIndexUnavailableView.message(for: .newerSchema(found: 9)),
            "The index was created by a newer Zentty. Rebuild it to keep searching."
        )
        XCTAssertTrue(AgentHistoryIndexUnavailableView.offersRebuild(.newerSchema(found: 9), isDiskFullPause: false))
        XCTAssertTrue(search.metadataQueries.isEmpty, "an unavailable index is never read (D14)")
    }
}
