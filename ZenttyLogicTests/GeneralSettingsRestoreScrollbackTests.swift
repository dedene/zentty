@testable import Zentty
import AppKit
import XCTest

@MainActor
final class GeneralSettingsRestoreScrollbackTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.GeneralSettingsScrollback.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach {
            UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0)
        }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_restore_pane_output_toggle_defaults_on_and_persists() {
        let store = makeConfigStore()
        let controller = GeneralSettingsSectionViewController(configStore: store)
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.isRestoreScrollbackSwitchOn)
        XCTAssertTrue(controller.isRestoreScrollbackSwitchEnabled)

        controller.setRestoreScrollbackEnabledForTesting(false)

        XCTAssertFalse(store.current.restore.restoreScrollback)
        XCTAssertTrue(store.current.restore.restoreWorkspaceOnLaunch)
    }

    func test_restore_pane_output_toggle_follows_the_workspace_restore_toggle() {
        let store = makeConfigStore()
        let controller = GeneralSettingsSectionViewController(configStore: store)
        controller.loadViewIfNeeded()

        controller.setRestoreWorkspaceEnabledForTesting(false)
        XCTAssertFalse(controller.isRestoreScrollbackSwitchEnabled)
        XCTAssertTrue(controller.isRestoreScrollbackSwitchOn, "the stored preference is kept, only greyed out")

        controller.apply(restore: AppConfig.Restore(restoreWorkspaceOnLaunch: true, restoreScrollback: false))
        XCTAssertTrue(controller.isRestoreScrollbackSwitchEnabled)
        XCTAssertFalse(controller.isRestoreScrollbackSwitchOn)
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: makeDefaults(suffix: "sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults(suffix: "sidebarVisibility"),
            paneLayoutDefaults: makeDefaults(suffix: "paneLayout")
        )
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.generalSettingsScrollback.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
}
