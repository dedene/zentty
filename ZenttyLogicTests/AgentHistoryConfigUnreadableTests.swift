import AppKit
import XCTest
@testable import Zentty

/// A config.toml that can't be parsed hides the excluded folders: at launch the store falls back
/// to defaults (no exclusions), and while it is write-protected no exclusion edit can be saved.
/// Turning Agent History or a source on then would index folders the user excluded, so the
/// palette's consent card and Settings refuse it and say to fix config.toml first. Each test
/// runs the real controller over a temp config.toml.
@MainActor
final class AgentHistoryConfigUnreadableTests: AppKitTestCase {
    private static let malformed = """
    [agent_history]
    excluded_folders = ["/work/secret"
    """
    private static let readable = """
    [agent_history]
    excluded_folders = ["/work/secret"]
    """

    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return made }
        func record() { lock.lock(); made += 1; lock.unlock() }
    }

    private struct Fixture {
        let controller: AgentHistoryController
        let configStore: AppConfigStore
        let paths: AgentHistoryPaths
        let factory: FactoryLog
    }

    private func makeFixture(config: String) -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-config-unreadable-\(UUID().uuidString)", isDirectory: true)
        let claudeRoot = base.appendingPathComponent("claude-root", isDirectory: true)
        let codexRoot = base.appendingPathComponent("codex-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let configURL = base.appendingPathComponent("config.toml", isDirectory: false)
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        let paths = AgentHistoryPaths(directoryURL: base.appendingPathComponent("AgentHistory", isDirectory: true))
        let claude = FakeHistorySource(agent: .claude, rootPath: claudeRoot.path)
        let codex = FakeHistorySource(agent: .codex, rootPath: codexRoot.path)
        claude.setUnits([.single("claude-secret", cwd: "/work/secret/app")])
        codex.setUnits([.single("codex-one", cwd: "/work/project")])

        let factory = FactoryLog()
        let sources: [any AgentHistorySource] = [claude, codex]
        let controller = AgentHistoryController(
            launchDelay: 0,
            makeSources: { sources },
            makeIndexer: { storage, stateStore, configuration, callbacks in
                factory.record()
                return AgentHistoryIndexer(
                    storage: storage,
                    stateStore: stateStore,
                    makeSources: { sources },
                    configuration: configuration,
                    systemConditions: FakeSystemConditions(),
                    onStatusChange: callbacks.onStatusChange,
                    onSnapshotChange: callbacks.onSnapshotChange
                )
            }
        )
        let configStore = AppConfigStore(fileURL: configURL)
        controller.configure(configStore: configStore, paths: paths)
        addTeardownBlock { @MainActor in
            controller.stop()
            try? FileManager.default.removeItem(at: base)
        }
        return Fixture(controller: controller, configStore: configStore, paths: paths, factory: factory)
    }

    private func writeState(_ paths: AgentHistoryPaths, _ mutate: (inout AgentHistoryState) -> Void) throws {
        try AgentHistoryStateStore(fileURL: paths.stateURL).update(mutate)
    }

    private func persistedState(_ paths: AgentHistoryPaths) -> AgentHistoryState {
        AgentHistoryStateStore(fileURL: paths.stateURL).current
    }

    private func launch(_ controller: AgentHistoryController) -> Bool {
        let decided = expectation(description: "launch decision")
        var started = false
        controller.scheduleStartAfterLaunch { result in
            started = result
            decided.fulfill()
        }
        wait(for: [decided], timeout: 5)
        return started
    }

    /// Lets every queued state write land and its main-queue delivery run.
    private func settle(_ controller: AgentHistoryController) {
        controller.drainControlQueueForTesting()
        let delivered = expectation(description: "main deliveries")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
    }

    private func breakConfig(_ fixture: Fixture) throws {
        try Self.malformed.write(to: fixture.configStore.fileURL, atomically: true, encoding: .utf8)
        fixture.configStore.reloadFromDisk()
        XCTAssertTrue(fixture.configStore.isWriteProtected)
    }

    // MARK: - Controller

    /// First consent with an unreadable config.toml: nothing is recorded or started.
    func test_enable_is_refused_while_config_toml_is_unreadable_at_launch() throws {
        let fixture = makeFixture(config: Self.malformed)
        XCTAssertTrue(fixture.configStore.isUsingFallbackDefaults)
        XCTAssertFalse(launch(fixture.controller))

        var outcomes: [AgentHistoryStateChangeOutcome] = []
        fixture.controller.enable(agents: [.claude, .codex]) { outcomes.append($0) }
        settle(fixture.controller)

        XCTAssertEqual(outcomes, [.refusedConfigUnreadable])
        let state = persistedState(fixture.paths)
        XCTAssertNil(state.consentedAt, "no consent is recorded")
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(fixture.controller.status.hasConsented)
        XCTAssertEqual(fixture.factory.count, 0)
    }

    /// The file broke while Zentty ran: the store keeps the last good settings but can't save an
    /// exclusion change any more, so turning History or a source on waits for the file too.
    /// Turning things off still works.
    func test_turning_on_is_refused_after_config_toml_breaks_and_off_still_works() throws {
        let fixture = makeFixture(config: Self.readable)
        try writeState(fixture.paths) { state in
            state.enabled = false
            state.consentedAt = Date()
            state.setSource(.codex, enabled: false)
        }
        XCTAssertFalse(launch(fixture.controller))
        try breakConfig(fixture)

        var outcomes: [AgentHistoryStateChangeOutcome] = []
        fixture.controller.setEnabled(true) { outcomes.append($0) }
        fixture.controller.setAgentEnabled(.codex, true) { outcomes.append($0) }
        fixture.controller.enable(agents: [.claude]) { outcomes.append($0) }
        fixture.controller.setAgentEnabled(.claude, false) { outcomes.append($0) }
        settle(fixture.controller)

        XCTAssertEqual(outcomes, [.refusedConfigUnreadable, .refusedConfigUnreadable, .refusedConfigUnreadable, .saved])
        let state = persistedState(fixture.paths)
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.enabledAgents, [.grok, .opencode])
        XCTAssertEqual(fixture.factory.count, 0)
    }

    // MARK: - Palette consent card

    /// The card shows no excluded folders (the fallback has none), so confirming it unchanged
    /// would skip the folder save and its write-protection check. The controller refuses
    /// instead and the card says why.
    func test_consent_card_refuses_to_index_while_config_toml_is_unreadable() throws {
        let fixture = makeFixture(config: Self.malformed)
        let configStore = fixture.configStore
        let services = AgentHistoryPaletteServices(
            control: fixture.controller,
            search: FakeAgentHistorySearch(),
            launch: FakeAgentHistoryLaunch(),
            excludedFolders: { configStore.current.agentHistory.excludedFolders },
            setExcludedFolders: { try AgentHistoryPaletteServicesAdapter.saveExcludedFolders($0, to: configStore) },
            claudeRetention: {
                ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-config-unreadable/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-config-unreadable/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )
            },
            raiseClaudeRetention: { .alreadySufficient(currentDays: 365) },
            pasteboard: AgentHistoryTestPasteboard.make(),
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: Date.init
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
        model.start()
        let shown = expectation(description: "consent card")
        let observation = model.$consent.sink { if $0 != nil { shown.fulfill() } }
        wait(for: [shown], timeout: 5)
        observation.cancel()
        XCTAssertEqual(model.consent?.excludedFolders, [])

        model.handle(.consentConfirm)
        settle(fixture.controller)

        let consent = try XCTUnwrap(model.consent)
        XCTAssertFalse(consent.isIndexing)
        XCTAssertTrue(consent.canConfirm, "the card stays so the user can retry after fixing the file")
        XCTAssertEqual(consent.saveError, AgentHistoryConsentModel.configUnreadableError)
        XCTAssertNil(persistedState(fixture.paths).consentedAt)
        XCTAssertEqual(fixture.factory.count, 0)
    }

    // MARK: - Settings

    /// Consent is already recorded, so the switch turns History on directly: refused, the
    /// switch goes back to off, and an alert says to fix config.toml.
    func test_settings_switch_refuses_to_turn_on_while_config_toml_is_unreadable() throws {
        let fixture = makeFixture(config: Self.malformed)
        try writeState(fixture.paths) { $0.enabled = false; $0.consentedAt = Date() }
        XCTAssertFalse(launch(fixture.controller))
        XCTAssertTrue(fixture.controller.status.hasConsented)
        var errors: [String] = []
        let settings = AgentHistorySettingsSectionViewController(
            configStore: fixture.configStore,
            backend: fixture.controller,
            confirmationPresenter: { _, _, completion in completion(true) },
            folderPicker: { _, completion in completion([]) },
            errorPresenter: { _, title, message in errors.append("\(title)|\(message)") },
            retentionStatusProvider: { directory in
                ClaudeRetentionStatus(
                    configDirectory: directory, settingsFileURL: directory.appendingPathComponent("settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )
            },
            retentionWriter: { _ in .alreadySufficient(currentDays: 365) },
            locale: Locale(identifier: "en_US"),
            now: Date.init
        )
        settings.loadViewIfNeeded()
        settings.apply(status: fixture.controller.status)

        settings.statusSwitch.state = .on
        settings.handleStatusSwitchChanged(settings.statusSwitch)
        settle(fixture.controller)

        XCTAssertEqual(errors, ["Fix config.toml first|\(AgentHistoryConsentModel.configUnreadableError)"])
        XCTAssertEqual(settings.statusSwitch.state, .off)
        XCTAssertFalse(persistedState(fixture.paths).enabled)
        XCTAssertEqual(fixture.factory.count, 0)
    }
}
