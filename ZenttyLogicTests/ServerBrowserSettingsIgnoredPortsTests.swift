@testable import Zentty
import XCTest

@MainActor
final class ServerBrowserSettingsIgnoredPortsTests: AppKitTestCase {
    private final class StubServerOpenService: ServerOpening {
        private let systemDefault = ServerBrowserTarget(
            stableID: ServerBrowserTarget.systemDefaultID,
            displayName: "System Default",
            bundleIdentifier: nil,
            appURL: nil,
            isSystemDefault: true,
            isAvailable: true
        )

        func availableBrowsers(config: AppConfig.ServerDetection) -> [ServerBrowserTarget] { [systemDefault] }
        func preferredBrowser(config: AppConfig.ServerDetection) -> ServerBrowserTarget { systemDefault }
        func icon(for browser: ServerBrowserTarget) -> NSImage? { nil }
        func open(server: DetectedServer, browserID: String?, config: AppConfig.ServerDetection) -> Bool { true }
    }

    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zentty.IgnoredPorts.\(UUID().uuidString)", isDirectory: true)
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

    func test_adding_valid_port_persists() {
        let controller = makeController()

        XCTAssertTrue(controller.addIgnoredPortRuleForTesting("9229"))

        XCTAssertEqual(controller.ignoredPortRulesForTesting, ["9229"])
        XCTAssertFalse(controller.ignoredPortErrorVisibleForTesting)
    }

    func test_adding_valid_range_persists() {
        let controller = makeController()

        XCTAssertTrue(controller.addIgnoredPortRuleForTesting("24678-24680"))

        XCTAssertEqual(controller.ignoredPortRulesForTesting, ["24678-24680"])
    }

    func test_invalid_input_blocks_save_and_shows_error() {
        for invalid in ["abc", "0", "70000", "5000-4000"] {
            let controller = makeController()

            XCTAssertFalse(controller.addIgnoredPortRuleForTesting(invalid), "\(invalid) should be rejected")
            XCTAssertTrue(controller.ignoredPortRulesForTesting.isEmpty)
            XCTAssertTrue(controller.ignoredPortErrorVisibleForTesting)
        }
    }

    func test_removing_rule_persists() {
        let controller = makeController()
        controller.addIgnoredPortRuleForTesting("9229")
        controller.addIgnoredPortRuleForTesting("3000")

        controller.removeIgnoredPortRuleForTesting("9229")

        XCTAssertEqual(controller.ignoredPortRulesForTesting, ["3000"])
    }

    // MARK: - Helpers

    private func makeController() -> ServerBrowserSettingsSectionViewController {
        let store = AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: makeDefaults("sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults("sidebarVisibility"),
            paneLayoutDefaults: makeDefaults("paneLayout")
        )
        let controller = ServerBrowserSettingsSectionViewController(
            configStore: store,
            serverOpenService: StubServerOpenService()
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private func makeDefaults(_ suffix: String) -> UserDefaults {
        let name = "ZenttyTests.IgnoredPorts.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
}
