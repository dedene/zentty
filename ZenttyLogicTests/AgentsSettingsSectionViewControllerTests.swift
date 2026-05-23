@testable import Zentty
import XCTest

@MainActor
final class AgentsSettingsSectionViewControllerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.AgentsSettings.\(UUID().uuidString)", isDirectory: true)
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

    /// Regression: the Agents section once activated a separator's width
    /// constraint *before* the separator was added to its stack, throwing a
    /// "no common ancestor" exception that aborted `assembleContent` and left the
    /// whole pane blank. Loading the view must assemble all three switch rows
    /// (menu bar status, agent teams, prevent sleep) with a non-zero height.
    func test_agents_section_assembles_all_switch_rows() {
        let controller = AgentsSettingsSectionViewController(
            configStore: makeConfigStore(),
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) }
        )

        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(switches(in: controller.view).count, 3)
        XCTAssertGreaterThan(controller.measuredContentHeight(), 0)
    }

    // MARK: - Helpers

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: makeDefaults(suffix: "sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults(suffix: "sidebarVisibility"),
            paneLayoutDefaults: makeDefaults(suffix: "paneLayout")
        )
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let name = "be.zenjoy.zentty.tests.agentsSettings.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func switches(in view: NSView) -> [NSSwitch] {
        view.subviews.reduce(into: []) { result, subview in
            if let toggle = subview as? NSSwitch {
                result.append(toggle)
            }
            result.append(contentsOf: switches(in: subview))
        }
    }
}
