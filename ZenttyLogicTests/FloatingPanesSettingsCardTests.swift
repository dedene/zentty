@testable import Zentty
import AppKit
import XCTest

/// The General section's floating panes card writes `[floats]` and follows
/// config changes made elsewhere.
@MainActor
final class FloatingPanesSettingsCardTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.FloatingPanesSettings.\(UUID().uuidString)", isDirectory: true)
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

    func test_controls_start_from_the_defaults() {
        let card = FloatingPanesSettingsCard(configStore: makeConfigStore())

        XCTAssertTrue(card.isAutoPopSwitchOnForTesting)
        XCTAssertEqual(card.selectedPipSizeForTesting, .small)
    }

    func test_auto_pop_switch_persists() throws {
        let store = makeConfigStore()
        let card = FloatingPanesSettingsCard(configStore: store)

        card.setAutoPopForTesting(false)

        XCTAssertFalse(store.current.floats.autoPopNeedsInput)
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("auto_pop_needs_input = false"))
    }

    func test_pip_size_popup_persists() throws {
        let store = makeConfigStore()
        let card = FloatingPanesSettingsCard(configStore: store)

        card.selectPipSizeForTesting(.medium)

        XCTAssertEqual(store.current.floats.pipSize, .medium)
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("pip_size = \"medium\""))
    }

    func test_apply_mirrors_outside_changes() {
        let card = FloatingPanesSettingsCard(configStore: makeConfigStore())

        card.apply(floats: AppConfig.Floats(autoPopNeedsInput: false, pipSize: .medium))

        XCTAssertFalse(card.isAutoPopSwitchOnForTesting)
        XCTAssertEqual(card.selectedPipSizeForTesting, .medium)
    }

    func test_general_section_hosts_the_card_and_forwards_apply() {
        let controller = GeneralSettingsSectionViewController(configStore: makeConfigStore())
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.floatingPanesCard.view.superview, "the card is in the General section")

        controller.apply(floats: AppConfig.Floats(autoPopNeedsInput: true, pipSize: .medium))
        XCTAssertEqual(controller.floatingPanesCard.selectedPipSizeForTesting, .medium)
    }

    func test_general_section_is_found_by_float_search_terms() {
        XCTAssertTrue(SettingsSection.general.searchKeywords.contains("picture in picture"))
        XCTAssertTrue(SettingsSection.general.searchKeywords.contains("float"))
    }

    // MARK: - Fixtures

    private var configURL: URL {
        temporaryDirectoryURL.appendingPathComponent("config.toml")
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: configURL,
            sidebarWidthDefaults: makeDefaults(suffix: "sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults(suffix: "sidebarVisibility"),
            paneLayoutDefaults: makeDefaults(suffix: "paneLayout")
        )
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.floatingPanesSettings.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
}
