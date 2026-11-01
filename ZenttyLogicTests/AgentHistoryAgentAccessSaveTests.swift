@testable import Zentty
import AppKit
import XCTest

/// The "Allow agents to search all projects" switch over a config.toml that can't be parsed.
/// `AppConfigStore.update` then only changes memory, and the file's value comes back once the
/// file is fixed or Zentty restarts. Turning access on is refused; turning it off holds, the
/// user is told it isn't saved, and a fixed file doesn't quietly switch it back on.
@MainActor
final class AgentHistoryAgentAccessSaveTests: AppKitTestCase {
    private static let malformed = "[agent_history\nallow_agents_all_projects = "
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []
    private var errors: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    private var configURL: URL {
        temporaryDirectoryURL.appendingPathComponent("config.toml")
    }

    // MARK: - Settings

    func test_turning_access_off_over_a_broken_config_holds_and_says_it_is_not_saved() throws {
        let store = makeConfigStore()
        try store.update { $0.agentHistory.allowAgentsAllProjects = true }
        let settings = makeSettings(store)
        XCTAssertEqual(settings.agentAccessSwitch.state, .on)
        try Self.malformed.write(to: configURL, atomically: true, encoding: .utf8)

        toggle(settings.agentAccessSwitch, on: false, settings.handleAgentAccessChanged)

        XCTAssertTrue(store.isWriteProtected)
        XCTAssertFalse(store.current.agentHistory.allowAgentsAllProjects, "off holds in memory")
        XCTAssertEqual(settings.agentAccessSwitch.state, .off)
        XCTAssertEqual(errors, [
            "Couldn't save agent access|Agents can only search their own project for now, but Zentty couldn't write config.toml. Fix the file and Zentty saves this. Until then, a restart lets agents search all projects again.",
        ])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), Self.malformed)
    }

    func test_turning_access_on_over_a_broken_config_is_refused() throws {
        let store = makeConfigStore()
        try store.update { $0.agentHistory.excludedFolders = ["/work/secret"] }
        let settings = makeSettings(store)
        try Self.malformed.write(to: configURL, atomically: true, encoding: .utf8)

        toggle(settings.agentAccessSwitch, on: true, settings.handleAgentAccessChanged)

        XCTAssertTrue(store.isWriteProtected)
        XCTAssertFalse(store.current.agentHistory.allowAgentsAllProjects, "nothing new is granted")
        XCTAssertEqual(settings.agentAccessSwitch.state, .off)
        XCTAssertEqual(errors, [
            "Couldn't save agent access|Zentty couldn't write its config file, so this change isn't saved. Fix config.toml and try again.",
        ])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), Self.malformed)
    }

    // MARK: - Controller

    /// The file still says on after it's fixed. The revocation wins and is written then.
    func test_fixing_the_config_saves_the_revocation_instead_of_restoring_access() throws {
        let store = makeConfigStore()
        try store.update { $0.agentHistory.allowAgentsAllProjects = true }
        let controller = makeController(store)
        waitUntil("access mirrored") { controller.allowsAgentsAllProjects }
        try Self.malformed.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentHistoryPaletteServicesAdapter.saveAgentAccess(false, to: store)) { error in
            XCTAssertEqual(error as? AgentHistoryAgentAccessSaveError, .offNotSaved)
        }
        waitUntil("access revoked") { !controller.allowsAgentsAllProjects }
        XCTAssertFalse(controller.allowsAgentsAllProjects)

        // Fixed by hand, with access still on in the file.
        try "[agent_history]\nallow_agents_all_projects = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        let mirroredDuringRepair = MirrorLog()
        let observer = store.addObserver { _ in
            Task { @MainActor in mirroredDuringRepair.values.append(controller.allowsAgentsAllProjects) }
        }
        defer { store.removeObserver(observer) }
        store.reloadFromDisk()

        waitUntil("revocation saved") { (try? String(contentsOf: self.configURL, encoding: .utf8))?.contains("allow_agents_all_projects = false") == true }
        waitUntil("observers drained") { mirroredDuringRepair.values.count >= 2 }
        XCTAssertFalse(store.isWriteProtected)
        XCTAssertFalse(store.current.agentHistory.allowAgentsAllProjects)
        XCTAssertFalse(controller.allowsAgentsAllProjects)
        XCTAssertEqual(mirroredDuringRepair.values.filter { $0 }, [], "access never came back, not even briefly")
    }

    /// Once the revocation is saved, the switch works as before.
    func test_access_can_be_turned_on_again_after_the_revocation_is_saved() throws {
        let store = makeConfigStore()
        try store.update { $0.agentHistory.allowAgentsAllProjects = true }
        let controller = makeController(store)
        try Self.malformed.write(to: configURL, atomically: true, encoding: .utf8)
        _ = try? AgentHistoryPaletteServicesAdapter.saveAgentAccess(false, to: store)
        try "[agent_history]\nallow_agents_all_projects = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        store.reloadFromDisk()
        waitUntil("revocation saved") { !store.current.agentHistory.allowAgentsAllProjects }

        try AgentHistoryPaletteServicesAdapter.saveAgentAccess(true, to: store)

        waitUntil("access granted") { controller.allowsAgentsAllProjects }
        XCTAssertTrue(controller.allowsAgentsAllProjects)
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("allow_agents_all_projects = true"))
    }

    // MARK: - Helpers

    private func makeSettings(_ store: AppConfigStore) -> AgentHistorySettingsSectionViewController {
        let settings = AgentHistorySettingsSectionViewController(
            configStore: store,
            backend: FakeAgentHistoryControl(),
            confirmationPresenter: { _, _, completion in completion(false) },
            folderPicker: { _, completion in completion([]) },
            errorPresenter: { [weak self] _, title, message in
                self?.errors.append("\(title)|\(message)")
            },
            retentionStatusProvider: { directory in
                ClaudeRetentionStatus(
                    configDirectory: directory,
                    settingsFileURL: directory.appendingPathComponent("settings.json"),
                    effectiveDays: 365,
                    source: .userSettings,
                    readError: nil
                )
            },
            retentionWriter: { _ in .alreadySufficient(currentDays: 365) },
            retentionRunner: .inline,
            locale: Locale(identifier: "en_US")
        )
        settings.loadViewIfNeeded()
        return settings
    }

    private func makeController(_ store: AppConfigStore) -> AgentHistoryController {
        let controller = AgentHistoryController(launchDelay: 0, makeSources: { [] })
        let paths = AgentHistoryPaths(directoryURL: temporaryDirectoryURL.appendingPathComponent("AgentHistory", isDirectory: true))
        controller.configure(configStore: store, paths: paths)
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: configURL,
            sidebarWidthDefaults: makeDefaults("sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults("sidebarVisibility"),
            paneLayoutDefaults: makeDefaults("paneLayout")
        )
    }

    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.agentHistoryAccess.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func toggle(_ toggle: NSSwitch, on: Bool, _ handler: (NSSwitch) -> Void) {
        toggle.state = on ? .on : .off
        handler(toggle)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline {
                done.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
        wait(for: [done], timeout: timeout + 1)
    }
}

/// What the controller mirrored each time the config changed, read on main.
@MainActor
private final class MirrorLog {
    var values: [Bool] = []
}
