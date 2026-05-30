@testable import Zentty
import AppKit
import XCTest

@MainActor
final class AgentsSettingsSectionViewControllerTests: AppKitTestCase {
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
    /// whole pane blank. Loading the view must assemble the three global switch
    /// rows (menu bar status, agent teams, prevent sleep) plus one switch per
    /// agent in the integrations card, with a non-zero height.
    func test_agents_section_assembles_all_switch_rows() {
        let controller = AgentsSettingsSectionViewController(
            configStore: makeConfigStore(),
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) }
        )

        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        controller.view.layoutSubtreeIfNeeded()

        // 3 global toggles + one integration toggle per known agent.
        XCTAssertEqual(switches(in: controller.view).count, 3 + AgentIntegrationConsent.allTools.count)
        XCTAssertGreaterThan(controller.measuredContentHeight(), 0)
    }

    func test_menu_bar_status_toggle_persists() {
        let store = makeConfigStore()
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) }
        )
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.isMenuBarStatusSwitchOn)

        controller.setMenuBarStatusEnabledForTesting(false)

        XCTAssertFalse(store.current.menuBar.showStatusItem)
        XCTAssertFalse(controller.isMenuBarStatusSwitchOn)
    }

    func test_integration_disable_uninstallFailure_keepsOff_andSurfacesFailure() {
        struct UninstallError: Error {}
        let store = makeConfigStore()
        var failureTool: AgentBootstrapTool?
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) },
            consentPresenter: { _, completion in completion(.on) },
            performUninstall: { _ in throw UninstallError() },
            uninstallFailurePresenter: { _, tool, _ in failureTool = tool }
        )
        controller.loadViewIfNeeded()

        controller.simulateIntegrationToggleForTesting(.cursor, on: true)
        XCTAssertEqual(store.current.agentIntegrations.state(for: .cursor), .on)

        controller.simulateIntegrationToggleForTesting(.cursor, on: false)

        XCTAssertEqual(failureTool, .cursor, "an uninstall failure must be surfaced to the user")
        XCTAssertEqual(
            store.current.agentIntegrations.state(for: .cursor), .off,
            "the user's off choice is recorded even when hook removal fails"
        )
    }

    func test_integration_disable_uninstallSuccess_doesNotSurfaceFailure() {
        let store = makeConfigStore()
        var didPresentFailure = false
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) },
            consentPresenter: { _, completion in completion(.on) },
            performUninstall: { _ in },
            uninstallFailurePresenter: { _, _, _ in didPresentFailure = true }
        )
        controller.loadViewIfNeeded()

        controller.simulateIntegrationToggleForTesting(.cursor, on: true)
        controller.simulateIntegrationToggleForTesting(.cursor, on: false)

        XCTAssertFalse(didPresentFailure, "a successful uninstall must not surface a failure")
        XCTAssertEqual(store.current.agentIntegrations.state(for: .cursor), .off)
    }

    func test_integration_status_indicator_reflects_state() throws {
        let store = makeConfigStore()
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) },
            consentPresenter: { _, completion in completion(.on) },
            performUninstall: { _ in }
        )
        controller.loadViewIfNeeded()

        // Persistent agent defaults to `.ask`: visible amber label, no glyph and no
        // hover tooltip.
        let ask = try XCTUnwrap(controller.integrationStatusForTesting(.cursor))
        XCTAssertTrue(ask.askVisible)
        XCTAssertFalse(ask.glyphVisible)
        XCTAssertNil(ask.tooltipText)

        // Built-in agent defaults to `.on`: no trailing indicator at all.
        let builtIn = try XCTUnwrap(controller.integrationStatusForTesting(.claude))
        XCTAssertFalse(builtIn.askVisible)
        XCTAssertFalse(builtIn.glyphVisible)
        XCTAssertNil(builtIn.tooltipText)

        // Enabling a persistent agent replaces the amber ask label with the status
        // glyph and a hover tooltip. The tint/text vary with on-disk hook state
        // (read from the real config), so we assert the glyph is now the visible
        // treatment and that a non-empty tooltip is present — not which tint this
        // machine yields.
        controller.simulateIntegrationToggleForTesting(.cursor, on: true)
        let enabled = try XCTUnwrap(controller.integrationStatusForTesting(.cursor))
        XCTAssertTrue(enabled.glyphVisible)
        XCTAssertFalse(enabled.askVisible)
        let tooltip = try XCTUnwrap(enabled.tooltipText)
        XCTAssertFalse(tooltip.isEmpty)
    }

    /// Presenting the section re-reads integration state from disk, so a glyph
    /// recomputes (e.g. a launch that installed hooks, or — modelled here — a
    /// state change made behind the panel's back) without needing a config push.
    func test_prepareForPresentation_refreshes_integration_controls() throws {
        let store = makeConfigStore()
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) },
            consentPresenter: { _, completion in completion(.on) },
            performUninstall: { _ in }
        )
        controller.loadViewIfNeeded()

        controller.simulateIntegrationToggleForTesting(.cursor, on: true)
        XCTAssertEqual(controller.integrationStatusForTesting(.cursor)?.glyphVisible, true)

        // Mutate state directly, bypassing the controller, so its row goes stale.
        try store.update { $0.agentIntegrations.states["cursor"] = .ask }
        XCTAssertEqual(controller.integrationStatusForTesting(.cursor)?.glyphVisible, true,
                       "row is stale until the panel re-checks")

        controller.prepareForPresentation()

        let refreshed = try XCTUnwrap(controller.integrationStatusForTesting(.cursor))
        XCTAssertTrue(refreshed.askVisible, "presenting the section re-reads state and shows the ask label")
        XCTAssertFalse(refreshed.glyphVisible)
    }

    /// An `agentIntegrationHooksDidChange` post (fired after a launch may have
    /// (re)installed hooks) refreshes the panel live while it is already open.
    func test_hooksDidChange_notification_refreshes_integration_controls() throws {
        let store = makeConfigStore()
        let controller = AgentsSettingsSectionViewController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) },
            consentPresenter: { _, completion in completion(.on) },
            performUninstall: { _ in }
        )
        controller.loadViewIfNeeded()

        controller.simulateIntegrationToggleForTesting(.cursor, on: true)
        XCTAssertEqual(controller.integrationStatusForTesting(.cursor)?.glyphVisible, true)

        // Mutate state behind the panel's back, then signal a hook change. Posting
        // on the main thread invokes the selector observer synchronously, so the
        // refresh has already happened by the time `post` returns.
        try store.update { $0.agentIntegrations.states["cursor"] = .ask }
        NotificationCenter.default.post(name: .agentIntegrationHooksDidChange, object: nil)

        let refreshed = try XCTUnwrap(controller.integrationStatusForTesting(.cursor))
        XCTAssertTrue(refreshed.askVisible, "the hook-change signal re-reads state and shows the ask label")
        XCTAssertFalse(refreshed.glyphVisible)
    }

    func test_integration_group_headers_are_vertically_centered() {
        let controller = AgentsSettingsSectionViewController(
            configStore: makeConfigStore(),
            agentTeamsEnableWarningPresenter: { _, completion in completion(.cancel) }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        for title in ["MODIFIES YOUR CONFIG", "AUTOMATIC"] {
            let offset = controller.groupHeaderCenterYOffsetForTesting(title: title)
            XCTAssertNotNil(offset, "expected a group header titled \(title)")
            XCTAssertEqual(offset ?? .greatestFiniteMagnitude, 0, accuracy: 1.0,
                           "\(title) should be vertically centered in its band")
        }
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
