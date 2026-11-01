@testable import Zentty
import AppKit
import XCTest

@MainActor
final class AgentHistorySettingsSectionViewControllerTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []
    private var storedConfigStore: AppConfigStore?
    private var confirmations: [AgentHistorySettingsConfirmation] = []
    private var confirmResult = true
    private var pickedFolders: [URL] = []
    private var errors: [String] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    /// A config store over a temp `config.toml`, created on first use.
    private var configStore: AppConfigStore {
        if let storedConfigStore {
            return storedConfigStore
        }
        let store = makeConfigStore()
        storedConfigStore = store
        return store
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    // MARK: - Assembly and status

    func test_assembles_all_cards_with_nonzero_height() {
        let controller = makeController(backend: FakeAgentHistoryControl())
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        // Status + one per agent + agent access.
        XCTAssertEqual(controller.view.agentHistoryDescendants(ofType: NSSwitch.self).count, 6)
        XCTAssertGreaterThan(controller.measuredContentHeight(), 0)
    }

    func test_status_switch_and_summary_reflect_status() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)

        controller.apply(status: makeStatus())
        XCTAssertEqual(controller.statusSwitch.state, .on)
        XCTAssertTrue(controller.statusSwitch.isEnabled)
        XCTAssertEqual(controller.summaryTextForTesting, "1,284 sessions · 412 MB on disk · updated 3 minutes ago")

        controller.apply(status: makeStatus(isEnabled: false, state: .off))
        XCTAssertEqual(controller.statusSwitch.state, .off)
        XCTAssertEqual(controller.summaryTextForTesting, "Off. The index is kept until you delete it.")
    }

    func test_status_observer_follows_appearance() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)

        controller.viewWillAppear()
        XCTAssertEqual(backend.observerCount, 1)
        backend.publish(makeStatus())
        XCTAssertEqual(controller.statusSwitch.state, .on)

        controller.viewDidDisappear()
        XCTAssertEqual(backend.observerCount, 0)
    }

    func test_prepare_for_presentation_pulls_status_and_requests_refresh() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)
        backend.status = makeStatus()
        backend.detectedSources = detectedSources()

        controller.prepareForPresentation()

        XCTAssertEqual(controller.status, backend.status)
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(controller.statusSwitch.state, .on)
        XCTAssertEqual(controller.sourceRowForTesting(.claude)?.textsForTesting.contains("120 found"), true)
    }

    func test_progress_visible_only_while_backfilling() {
        let controller = makeController(backend: FakeAgentHistoryControl())
        let progress = AgentHistoryBackfillProgress(indexedSessions: 312, totalSessions: 1284)

        controller.apply(status: makeStatus(state: .backfilling(progress)))
        XCTAssertFalse(controller.progressIndicator.isHidden)
        XCTAssertEqual(controller.progressIndicator.doubleValue, 312.0 / 1284.0, accuracy: 0.0001)
        XCTAssertEqual(controller.activityTextForTesting, "Indexing 312 of 1,284 sessions")

        controller.apply(status: makeStatus(state: .paused(.lowPower, progress)))
        XCTAssertTrue(controller.progressIndicator.isHidden)
        XCTAssertEqual(controller.activityTextForTesting, "Paused while Low Power Mode is on")

        controller.apply(status: makeStatus(state: .watching))
        XCTAssertTrue(controller.progressIndicator.isHidden)
        XCTAssertNil(controller.activityTextForTesting)
    }

    func test_newer_schema_callout() {
        let controller = makeController(backend: FakeAgentHistoryControl())

        controller.apply(status: makeStatus(state: .failed(.newerSchema(found: 9))))

        XCTAssertEqual(controller.calloutTextForTesting, "Index was created by a newer Zentty. Rebuild it to keep searching.")
        XCTAssertNil(controller.activityTextForTesting)
        XCTAssertTrue(controller.rebuildButton.isEnabled)
    }

    func test_nil_backend_shows_unavailable_and_disables_controls() {
        let controller = makeController(backend: nil)
        controller.prepareForPresentation()

        XCTAssertEqual(controller.summaryTextForTesting, AgentHistorySettingsSectionViewController.unavailableText)
        XCTAssertFalse(controller.statusSwitch.isEnabled)
        XCTAssertFalse(controller.agentAccessSwitch.isEnabled)
        XCTAssertFalse(controller.addFolderButton.isEnabled)
        XCTAssertFalse(controller.restoreAllButton.isEnabled)
        XCTAssertFalse(controller.rebuildButton.isEnabled)
        XCTAssertFalse(controller.deleteButton.isEnabled)
        for agent in AgentHistoryAgent.allCases {
            XCTAssertEqual(controller.sourceRowForTesting(agent)?.toggle.isEnabled, false)
        }
    }

    // MARK: - Turning on and off

    func test_enable_without_consent_cancel_reverts_switch() {
        let backend = FakeAgentHistoryControl()
        backend.detectedSources = detectedSources()
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()
        confirmResult = false

        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)

        XCTAssertEqual(confirmations, [.enable(detected: detectedSources())])
        XCTAssertEqual(controller.statusSwitch.state, .off)
        XCTAssertTrue(backend.enabledAgents.isEmpty)
        XCTAssertTrue(backend.setEnabledCalls.isEmpty)
    }

    func test_enable_without_consent_confirm_calls_backend() {
        let backend = FakeAgentHistoryControl()
        backend.detectedSources = detectedSources()
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)

        XCTAssertEqual(confirmations, [.enable(detected: detectedSources())])
        XCTAssertEqual(backend.enabledAgents, [[.claude, .codex]])
        XCTAssertTrue(backend.setEnabledCalls.isEmpty)
    }

    /// First consent refused because config.toml can't be read: the user hears why and the
    /// switch goes back to off.
    func test_enable_without_consent_refused_for_unreadable_config_shows_why() {
        let backend = FakeAgentHistoryControl()
        backend.detectedSources = detectedSources()
        backend.stateChangeOutcome = .refusedConfigUnreadable
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)

        XCTAssertEqual(backend.enabledAgents, [[.claude, .codex]])
        XCTAssertEqual(errors, ["Fix config.toml first|\(AgentHistoryConsentModel.configUnreadableError)"])
        XCTAssertEqual(controller.statusSwitch.state, .off)
    }

    /// The real probe answers later from a background queue. Turning on before it does would
    /// record consent without knowing which agents exist, so the switch waits for it.
    func test_turning_on_waits_for_the_source_probe() {
        let backend = FakeAgentHistoryControl()
        backend.holdsDetection = true
        backend.detectedSources = detectedSources()
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        XCTAssertFalse(controller.statusSwitch.isEnabled)
        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)
        XCTAssertEqual(controller.statusSwitch.state, .off)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertTrue(backend.enabledAgents.isEmpty)

        backend.releaseDetections()
        XCTAssertTrue(controller.statusSwitch.isEnabled)
        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)
        XCTAssertEqual(confirmations, [.enable(detected: detectedSources())])
        XCTAssertEqual(backend.enabledAgents, [[.claude, .codex]], "only the agents found")
    }

    func test_turning_on_unavailable_when_no_agent_was_found() {
        let backend = FakeAgentHistoryControl()
        backend.detectedSources = detectedSources().map {
            AgentHistoryDetectedSource(agent: $0.agent, rootPath: nil, isFound: false, sessionCount: nil, checkedPaths: $0.checkedPaths, problem: nil)
        }
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        XCTAssertFalse(controller.statusSwitch.isEnabled)
        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)
        XCTAssertEqual(controller.statusSwitch.state, .off)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertTrue(backend.enabledAgents.isEmpty)
    }

    func test_enable_with_prior_consent_skips_confirmation() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(isEnabled: false, state: .off)
        let controller = makeController(backend: backend)

        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)

        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(backend.setEnabledCalls, [true])
        XCTAssertTrue(backend.enabledAgents.isEmpty)
    }

    /// Before state.json is read the status is a placeholder: a consented user would be asked
    /// again and their per-agent choices overwritten, so the switch waits.
    func test_status_switch_waits_until_the_saved_state_is_read() {
        let backend = FakeAgentHistoryControl()
        backend.status = .off
        backend.detectedSources = detectedSources()
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        XCTAssertFalse(controller.statusSwitch.isEnabled)
        XCTAssertEqual(controller.summaryTextForTesting, AgentHistorySettingsFormatter.loadingSummary)
        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)
        XCTAssertEqual(controller.statusSwitch.state, .off)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertTrue(backend.enabledAgents.isEmpty)
        XCTAssertTrue(backend.setEnabledCalls.isEmpty)

        // The read finds earlier consent: turning on keeps the saved choices.
        controller.apply(status: makeStatus(isEnabled: false, state: .off))
        XCTAssertTrue(controller.statusSwitch.isEnabled)
        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(backend.setEnabledCalls, [true])
        XCTAssertTrue(backend.enabledAgents.isEmpty)
    }

    func test_disable_calls_backend_without_confirmation() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus()
        let controller = makeController(backend: backend)

        toggle(controller.statusSwitch, on: false, controller.handleStatusSwitchChanged)

        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(backend.setEnabledCalls, [false])
        XCTAssertTrue(backend.disableCalls.isEmpty)
    }

    func test_enable_confirmation_copy_matches_consent_card() {
        let formatting = AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        var detected = detectedSources()
        detected[0] = AgentHistoryDetectedSource(agent: .claude, rootPath: "/opt/claude", isFound: true, sessionCount: 1284, checkedPaths: ["/opt/claude"], problem: nil)
        let copy = AgentHistorySettingsAlerts.copy(for: .enable(detected: detected), formatting: formatting)

        XCTAssertEqual(copy.title, AgentHistoryConsentModel.title)
        let cardBody = AgentHistoryConsentModel.make(detected: detected, excluded: [], retentions: []).bodyText(formatting: formatting)
        XCTAssertEqual(copy.message, cardBody + "\n\n" + AgentHistoryConsentModel.footnote)
        XCTAssertEqual(copy.confirmTitle, "Turn On")
    }

    /// Database sources (Codex here) can't be counted before consent: the sheet names them
    /// instead of leaving them out of the count.
    func test_enable_confirmation_names_sources_it_cannot_count() {
        let copy = AgentHistorySettingsAlerts.copy(
            for: .enable(detected: detectedSources()),
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        XCTAssertTrue(
            copy.message.hasPrefix("Zentty found 120 conversations on this Mac, plus the ones in \(AgentHistoryAgent.codex.displayName)."),
            copy.message
        )
    }

    // MARK: - Sources

    func test_source_toggle_calls_set_agent_enabled() throws {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(sources: [AgentHistorySourceHealth(agent: .codex, root: "/opt/codex", isDefaultRoot: true)])
        let controller = makeController(backend: backend)
        let row = try XCTUnwrap(controller.sourceRowForTesting(.codex))
        XCTAssertTrue(row.toggle.isEnabled)
        XCTAssertEqual(row.toggle.state, .on)

        toggle(row.toggle, on: false, controller.handleSourceSwitchChanged)

        XCTAssertEqual(backend.setAgentEnabledCalls, [.codex: false])
    }

    /// Off still takes effect when state.json can't be written; the user is told it may not last.
    func test_turn_off_that_was_not_saved_shows_an_error() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus()
        backend.stateChangeOutcome = .appliedButNotSaved
        let controller = makeController(backend: backend)

        toggle(controller.statusSwitch, on: false, controller.handleStatusSwitchChanged)

        XCTAssertEqual(errors, ["Couldn't save this change|Agent History is off for now, but Zentty couldn't save that. It may turn back on the next time Zentty starts."])
    }

    func test_source_off_that_was_not_saved_shows_an_error() throws {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(sources: [AgentHistorySourceHealth(agent: .codex, root: "/opt/codex", isDefaultRoot: true)])
        backend.stateChangeOutcome = .appliedButNotSaved
        let controller = makeController(backend: backend)

        toggle(try XCTUnwrap(controller.sourceRowForTesting(.codex)).toggle, on: false, controller.handleSourceSwitchChanged)

        XCTAssertEqual(errors, ["Couldn't save this change|\(AgentHistoryAgent.codex.displayName) is off in Agent History for now, but Zentty couldn't save that. It may turn back on the next time Zentty starts."])
    }

    /// Turning on that couldn't be saved changes nothing, and the switch goes back to off.
    func test_turn_on_that_was_not_saved_shows_an_error_and_resets_the_switch() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(isEnabled: false, state: .off)
        backend.stateChangeOutcome = .notSaved
        let controller = makeController(backend: backend)

        toggle(controller.statusSwitch, on: true, controller.handleStatusSwitchChanged)

        XCTAssertEqual(backend.setEnabledCalls, [true])
        XCTAssertEqual(errors, ["Couldn't save this change|Zentty couldn't save Agent History's settings, so nothing changed. Check that your disk has free space, then try again."])
        XCTAssertEqual(controller.statusSwitch.state, .off)
    }

    func test_undetected_source_switch_is_disabled() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus()
        backend.detectedSources = detectedSources()
        let controller = makeController(backend: backend)
        controller.prepareForPresentation()

        let grok = controller.sourceRowForTesting(.grok)
        XCTAssertEqual(grok?.toggle.isEnabled, false)
        XCTAssertEqual(grok?.toggle.state, .off)
        XCTAssertEqual(grok?.textsForTesting, ["Not found", "Checked:\n/opt/grok"])
        XCTAssertEqual(controller.sourceRowForTesting(.claude)?.toggle.isEnabled, true)
    }

    // MARK: - Privacy and agent access

    func test_add_excluded_folders_persists_normalized_paths() throws {
        pickedFolders = [
            URL(fileURLWithPath: "/Users/example/work/../secrets/", isDirectory: true),
            URL(fileURLWithPath: "/Users/example/keys", isDirectory: true),
            URL(fileURLWithPath: "/Users/example/secrets", isDirectory: true),
        ]
        let controller = makeController(backend: FakeAgentHistoryControl())

        controller.handleAddFolder(nil)

        let expected = ["/Users/example/secrets", "/Users/example/keys"]
        XCTAssertEqual(configStore.current.agentHistory.excludedFolders, expected)
        XCTAssertEqual(controller.excludedFolderRowsForTesting, expected)
        let reloaded = makeConfigStore()
        XCTAssertEqual(reloaded.current.agentHistory.excludedFolders, expected)
        XCTAssertTrue(errors.isEmpty)
    }

    func test_remove_excluded_folder_persists() throws {
        try configStore.update { $0.agentHistory.excludedFolders = ["/Users/example/a", "/Users/example/b"] }
        let controller = makeController(backend: FakeAgentHistoryControl())
        let button = try XCTUnwrap(
            controller.view.agentHistoryDescendants(ofType: NSButton.self)
                .first { $0.identifier?.rawValue == "/Users/example/a" }
        )

        controller.handleRemoveFolder(button)

        XCTAssertEqual(configStore.current.agentHistory.excludedFolders, ["/Users/example/b"])
        XCTAssertEqual(controller.excludedFolderRowsForTesting, ["/Users/example/b"])
    }

    /// config.toml that can't be parsed only takes changes in memory. Adding or removing an
    /// excluded folder then is an error the user sees; the list stays what the file holds, and
    /// nothing acts on a list the file doesn't have.
    func test_excluded_folder_changes_that_cannot_be_saved_present_an_error() throws {
        try configStore.update { $0.agentHistory.excludedFolders = ["/Users/example/a"] }
        let controller = makeController(backend: FakeAgentHistoryControl())
        let configURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let malformed = "[agent_history\nexcluded_folders = ["
        try malformed.write(to: configURL, atomically: true, encoding: .utf8)
        let saveError = "Couldn't save the excluded folders|Zentty couldn't write its config file, so this change isn't saved. Fix config.toml and try again."

        pickedFolders = [URL(fileURLWithPath: "/Users/example/keys", isDirectory: true)]
        controller.handleAddFolder(nil)

        XCTAssertTrue(configStore.isWriteProtected)
        XCTAssertEqual(errors, [saveError])
        XCTAssertEqual(controller.excludedFolderRowsForTesting, ["/Users/example/a"])
        XCTAssertEqual(configStore.current.agentHistory.excludedFolders, ["/Users/example/a"])

        let remove = try XCTUnwrap(
            controller.view.agentHistoryDescendants(ofType: NSButton.self)
                .first { $0.identifier?.rawValue == "/Users/example/a" }
        )
        controller.handleRemoveFolder(remove)

        XCTAssertEqual(errors, [saveError, saveError])
        XCTAssertEqual(controller.excludedFolderRowsForTesting, ["/Users/example/a"], "still excluded")
        XCTAssertEqual(configStore.current.agentHistory.excludedFolders, ["/Users/example/a"])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), malformed)
    }

    func test_apply_config_rebuilds_folder_rows() {
        let controller = makeController(backend: FakeAgentHistoryControl())
        XCTAssertEqual(controller.excludedFolderRowsForTesting, [])

        controller.apply(agentHistory: AppConfig.AgentHistory(excludedFolders: ["/a", "/b"], allowAgentsAllProjects: true))

        XCTAssertEqual(controller.excludedFolderRowsForTesting, ["/a", "/b"])
        XCTAssertEqual(controller.agentAccessSwitch.state, .on)
    }

    func test_restore_all_disabled_at_zero_and_calls_backend() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)

        controller.apply(status: makeStatus(removed: 0))
        XCTAssertFalse(controller.restoreAllButton.isEnabled)
        XCTAssertEqual(controller.removedSessionsTextForTesting, "No sessions removed from Agent History.")

        controller.apply(status: makeStatus(removed: 3))
        XCTAssertTrue(controller.restoreAllButton.isEnabled)
        XCTAssertEqual(controller.removedSessionsTextForTesting, "3 sessions removed from Agent History")
        controller.handleRestoreAll(nil)
        XCTAssertEqual(backend.restoreAllCount, 1)
    }

    func test_agent_access_toggle_persists_allow_flag() {
        let controller = makeController(backend: FakeAgentHistoryControl())
        XCTAssertEqual(controller.agentAccessSwitch.state, .off)

        toggle(controller.agentAccessSwitch, on: true, controller.handleAgentAccessChanged)

        XCTAssertTrue(configStore.current.agentHistory.allowAgentsAllProjects)
        XCTAssertEqual(controller.agentAccessSwitch.state, .on)
    }

    // MARK: - Maintenance

    func test_rebuild_disabled_when_off_and_calls_backend_when_on() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)

        controller.apply(status: makeStatus(isEnabled: false, state: .off))
        XCTAssertFalse(controller.rebuildButton.isEnabled)
        controller.handleRebuild(nil)
        XCTAssertEqual(backend.rebuildCount, 0)

        controller.apply(status: makeStatus())
        XCTAssertTrue(controller.rebuildButton.isEnabled)
        controller.handleRebuild(nil)
        XCTAssertEqual(backend.rebuildCount, 1)
    }

    func test_unreadable_removals_block_rebuild_with_explanation() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)

        controller.apply(status: makeStatus(state: .failed(.removalsUnreadable)))

        XCTAssertFalse(controller.rebuildButton.isEnabled)
        XCTAssertEqual(controller.rebuildBlockedTextForTesting, AgentHistorySettingsRows.rebuildBlockedText)
        XCTAssertTrue(controller.deleteButton.isEnabled)

        controller.apply(status: makeStatus())
        XCTAssertNil(controller.rebuildBlockedTextForTesting)
    }

    func test_delete_cancel_does_nothing_and_confirm_calls_backend() {
        let backend = FakeAgentHistoryControl()
        backend.disableOutcome = .deleted
        let controller = makeController(backend: backend)
        controller.apply(status: makeStatus(isEnabled: false, state: .off))
        XCTAssertTrue(controller.deleteButton.isEnabled)

        confirmResult = false
        controller.handleDelete(nil)
        XCTAssertEqual(confirmations, [.deleteIndex])
        XCTAssertTrue(backend.disableCalls.isEmpty)

        confirmResult = true
        controller.handleDelete(nil)
        XCTAssertEqual(backend.disableCalls, [true])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(backend.refreshCount, 1)
    }

    func test_delete_refused_by_another_instance_presents_error() {
        let backend = FakeAgentHistoryControl()
        backend.disableOutcome = .refusedAnotherInstance
        let controller = makeController(backend: backend)
        controller.apply(status: makeStatus())

        controller.handleDelete(nil)

        XCTAssertEqual(backend.disableCalls, [true])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("Couldn't delete the index|Another running copy of Zentty"))
    }

    func test_delete_disabled_without_index_or_history() {
        let controller = makeController(backend: FakeAgentHistoryControl())
        controller.apply(status: .off)
        XCTAssertFalse(controller.deleteButton.isEnabled)
    }

    /// History off keeps the index and the consent: both are still there to delete, and the
    /// removed sessions are counted but can only be restored while the index runs.
    func test_history_off_keeps_delete_available_and_shows_removed_count() {
        let backend = FakeAgentHistoryControl()
        let controller = makeController(backend: backend)
        var status = makeStatus(isEnabled: false, state: .off, removed: 2)

        controller.apply(status: status)
        XCTAssertTrue(controller.deleteButton.isEnabled)
        XCTAssertEqual(controller.removedSessionsTextForTesting, "2 sessions removed from Agent History")
        XCTAssertFalse(controller.restoreAllButton.isEnabled)

        status.indexExists = false
        controller.apply(status: status)
        XCTAssertTrue(controller.deleteButton.isEnabled, "the consent alone is worth deleting")
    }

    // MARK: - Claude retention

    func test_retention_button_shown_below_365_and_click_writes_settings() throws {
        let claudeRoot = temporaryDirectoryURL.appendingPathComponent("claude-root", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let settingsURL = claudeRoot.appendingPathComponent("settings.json")
        try Data("{\n  \"cleanupPeriodDays\": 30\n}\n".utf8).write(to: settingsURL)
        let missingManaged = temporaryDirectoryURL.appendingPathComponent("managed-settings.json")
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(sources: [AgentHistorySourceHealth(agent: .claude, root: claudeRoot.path, isDefaultRoot: true)])
        let controller = makeController(
            backend: backend,
            retentionStatusProvider: { ClaudeRetentionSettings.status(configDirectory: $0, managedSettingsURL: missingManaged) },
            retentionWriter: { try ClaudeRetentionSettings.raiseRetention(configDirectory: $0) }
        )
        controller.prepareForPresentation()

        XCTAssertEqual(controller.retentionRows.map(\.text), [AgentHistorySettingsRows.retentionText(days: 30)])
        let button = try XCTUnwrap(controller.keepOneYearButtonForTesting(directory: claudeRoot.path))
        controller.handleKeepOneYear(button)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        XCTAssertEqual(written?["cleanupPeriodDays"] as? Int, 365)
        XCTAssertEqual(controller.retentionRows.map(\.text), [AgentHistoryConsentModel.raisedRetentionText])
        XCTAssertNil(controller.keepOneYearButtonForTesting(directory: claudeRoot.path))
        XCTAssertTrue(errors.isEmpty)
    }

    func test_retention_row_without_button_for_managed_value() {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(sources: [AgentHistorySourceHealth(agent: .claude, root: "/opt/claude", isDefaultRoot: true)])
        let controller = makeController(backend: backend, retentionStatusProvider: { directory in
            ClaudeRetentionStatus(
                configDirectory: directory,
                settingsFileURL: directory.appendingPathComponent("settings.json"),
                effectiveDays: 14,
                source: .managedSettings,
                readError: nil
            )
        })
        controller.prepareForPresentation()

        XCTAssertEqual(controller.retentionRows.count, 1)
        XCTAssertEqual(controller.retentionRows.first?.note, "Set by your organization")
        XCTAssertEqual(controller.retentionRows.first?.offersKeepOneYear, false)
        XCTAssertNil(controller.keepOneYearButtonForTesting(directory: "/opt/claude"))
    }

    func test_retention_write_failure_presents_error() throws {
        let backend = FakeAgentHistoryControl()
        backend.status = makeStatus(sources: [AgentHistorySourceHealth(agent: .claude, root: "/opt/claude", isDefaultRoot: true)])
        let controller = makeController(
            backend: backend,
            retentionStatusProvider: { Self.userRetention(directory: $0, days: 30) },
            retentionWriter: { _ in throw ClaudeRetentionSettingsError.invalidJSON(path: "/opt/claude/settings.json") }
        )
        controller.prepareForPresentation()
        let button = try XCTUnwrap(controller.keepOneYearButtonForTesting(directory: "/opt/claude"))

        controller.handleKeepOneYear(button)

        XCTAssertEqual(errors, ["Couldn't change Claude Code's settings|Claude's settings.json isn't valid JSON; nothing was changed."])
        XCTAssertNotNil(controller.keepOneYearButtonForTesting(directory: "/opt/claude"))
    }

    // MARK: - Helpers

    private func makeController(
        backend: FakeAgentHistoryControl?,
        retentionStatusProvider: @escaping @Sendable (URL) -> ClaudeRetentionStatus = { AgentHistorySettingsSectionViewControllerTests.userRetention(directory: $0, days: 365) },
        retentionWriter: @escaping @Sendable (URL) throws -> ClaudeRetentionWriteOutcome = { _ in .alreadySufficient(currentDays: 365) }
    ) -> AgentHistorySettingsSectionViewController {
        let controller = AgentHistorySettingsSectionViewController(
            configStore: configStore,
            backend: backend,
            confirmationPresenter: { [weak self] _, confirmation, completion in
                guard let self else { return }
                self.confirmations.append(confirmation)
                completion(self.confirmResult)
            },
            folderPicker: { [weak self] _, completion in
                completion(self?.pickedFolders ?? [])
            },
            errorPresenter: { [weak self] _, title, message in
                self?.errors.append("\(title)|\(message)")
            },
            retentionStatusProvider: retentionStatusProvider,
            retentionWriter: retentionWriter,
            // Synchronous here; `AgentHistorySettingsRetentionOffMainTests` covers the threading.
            retentionRunner: .inline,
            locale: Locale(identifier: "en_US"),
            now: { [now] in now }
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private nonisolated static func userRetention(directory: URL, days: Int) -> ClaudeRetentionStatus {
        ClaudeRetentionStatus(
            configDirectory: directory,
            settingsFileURL: directory.appendingPathComponent("settings.json"),
            effectiveDays: days,
            source: .userSettings,
            readError: nil
        )
    }

    private func makeStatus(
        isEnabled: Bool = true,
        state: AgentHistoryIndexerState = .watching,
        sources: [AgentHistorySourceHealth] = [],
        removed: Int = 0
    ) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = isEnabled
        status.hasConsented = true
        status.enabledAgents = Set(AgentHistoryAgent.allCases)
        status.state = state
        status.sources = sources
        status.indexedSessions = 1284
        status.removedSessionCount = removed
        status.indexExists = true
        status.indexSizeBytes = 412_000_000
        status.lastUpdatedAt = now.addingTimeInterval(-180)
        status.tokenizer = .trigram
        return status
    }

    private func detectedSources() -> [AgentHistoryDetectedSource] {
        [
            AgentHistoryDetectedSource(agent: .claude, rootPath: "/opt/claude", isFound: true, sessionCount: 120, checkedPaths: ["/opt/claude"], problem: nil),
            AgentHistoryDetectedSource(agent: .codex, rootPath: "/opt/codex", isFound: true, sessionCount: nil, checkedPaths: ["/opt/codex"], problem: nil),
            AgentHistoryDetectedSource(agent: .grok, rootPath: nil, isFound: false, sessionCount: nil, checkedPaths: ["/opt/grok"], problem: nil),
            AgentHistoryDetectedSource(agent: .opencode, rootPath: nil, isFound: false, sessionCount: nil, checkedPaths: ["/opt/opencode"], problem: nil),
        ]
    }

    private func toggle(_ toggle: NSSwitch, on: Bool, _ handler: (NSSwitch) -> Void) {
        toggle.state = on ? .on : .off
        handler(toggle)
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: makeDefaults("sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults("sidebarVisibility"),
            paneLayoutDefaults: makeDefaults("paneLayout")
        )
    }

    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.agentHistorySettings.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
}
