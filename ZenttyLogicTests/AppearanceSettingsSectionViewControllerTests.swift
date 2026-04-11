@testable import Zentty
import XCTest

@MainActor
final class AppearanceSettingsSectionViewControllerTests: AppKitTestCase {

    // MARK: - Stubs

    private final class StubCatalogProvider: ThemeCatalogProviding {
        var themes: [ThemePreview] = []

        func loadThemes() async -> [ThemePreview] {
            themes
        }
    }

    private final class StubConfigCoordinator: AppearanceSettingsConfigCoordinating {
        var sourceState = AppearanceSettingsSourceState(
            subtitle: "Using your Ghostty config.",
            showsCreateSharedConfigAction: false
        )
        private(set) var appliedThemes: [String] = []
        private(set) var appliedOpacities: [CGFloat] = []
        private(set) var createSharedConfigCallCount = 0

        func applyTheme(_ name: String, presentingWindow _: NSWindow?) async {
            appliedThemes.append(name)
        }

        func applyBackgroundOpacity(_ opacity: CGFloat, presentingWindow _: NSWindow?) async {
            appliedOpacities.append(opacity)
        }

        func createSharedConfig(presentingWindow _: NSWindow?) async {
            createSharedConfigCallCount += 1
        }
    }

    // MARK: - Helpers

    private func makeTheme(
        name: String,
        background: String = "#000000",
        foreground: String = "#ffffff"
    ) -> ThemePreview {
        ThemePreview(
            name: name,
            background: NSColor(hexString: background)!,
            foreground: NSColor(hexString: foreground)!,
            palette: []
        )
    }

    private func makeController(
        themes: [ThemePreview] = [],
        activeThemeName: String? = nil,
        backgroundOpacity: CGFloat? = 0.8,
        configCoordinator: StubConfigCoordinator = StubConfigCoordinator()
    ) -> (AppearanceSettingsSectionViewController, StubCatalogProvider, StubConfigCoordinator) {
        let catalog = StubCatalogProvider()
        catalog.themes = themes

        let controller = AppearanceSettingsSectionViewController(
            catalogProvider: catalog,
            configCoordinator: configCoordinator,
            currentThemeName: { _ in activeThemeName },
            currentBackgroundOpacity: { backgroundOpacity }
        )
        return (controller, catalog, configCoordinator)
    }

    private func loadAndWaitForThemes(
        _ controller: AppearanceSettingsSectionViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        controller.loadViewIfNeeded()
        let expectation = XCTestExpectation(description: "Themes loaded")
        Task {
            while controller.themes.isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    private func waitForCondition(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let expectation = XCTestExpectation(description: "Condition satisfied")
        Task {
            while predicate() == false {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Tests

    func testTablePopulatesWithDiscoveredThemes() async {
        let themes = [
            makeTheme(name: "Dracula"),
            makeTheme(name: "Solarized"),
            makeTheme(name: "TokyoNight"),
        ]

        let (controller, _, _) = makeController(themes: themes)
        await loadAndWaitForThemes(controller)

        XCTAssertEqual(controller.themes.count, 3)
        XCTAssertEqual(controller.themes.map(\.name), ["Dracula", "Solarized", "TokyoNight"])
    }

    func testSearchFiltersByName() async {
        let themes = [
            makeTheme(name: "Dracula"),
            makeTheme(name: "Dark+"),
            makeTheme(name: "Solarized"),
        ]

        let (controller, _, _) = makeController(themes: themes)
        await loadAndWaitForThemes(controller)

        controller.setSearchQueryForTesting("Dra")

        XCTAssertEqual(controller.themes.count, 1)
        XCTAssertEqual(controller.themes.first?.name, "Dracula")
    }

    func testClearingSearchShowsAllThemes() async {
        let themes = [
            makeTheme(name: "Alpha"),
            makeTheme(name: "Beta"),
        ]

        let (controller, _, _) = makeController(themes: themes)
        await loadAndWaitForThemes(controller)

        controller.setSearchQueryForTesting("Alpha")
        XCTAssertEqual(controller.themes.count, 1)

        controller.setSearchQueryForTesting("")
        XCTAssertEqual(controller.themes.count, 2)
    }

    func testThemeSelectionTriggersWriteAndReload() async {
        let themes = [makeTheme(name: "Dracula")]
        let coordinator = StubConfigCoordinator()

        let (controller, _, _) = makeController(
            themes: themes,
            configCoordinator: coordinator
        )
        await loadAndWaitForThemes(controller)

        controller.selectThemeForTesting("Dracula")
        await waitForCondition { coordinator.appliedThemes == ["Dracula"] }

        XCTAssertEqual(coordinator.appliedThemes, ["Dracula"])
    }

    func testHandleAppearanceChangeRefreshesActiveTheme() async {
        var currentAppearanceTheme: String? = "LightTheme"

        let catalog = StubCatalogProvider()
        catalog.themes = [
            makeTheme(name: "LightTheme"),
            makeTheme(name: "DarkTheme"),
        ]

        let controller = AppearanceSettingsSectionViewController(
            catalogProvider: catalog,
            configCoordinator: StubConfigCoordinator(),
            currentThemeName: { _ in currentAppearanceTheme },
            currentBackgroundOpacity: { 0.8 }
        )
        await loadAndWaitForThemes(controller)

        currentAppearanceTheme = "DarkTheme"
        controller.handleAppearanceChange()

        XCTAssertEqual(controller.activeThemeNameForTesting, "DarkTheme")
    }

    func testLocalOnlySourceStateShowsCreateSharedConfigAction() {
        let coordinator = StubConfigCoordinator()
        coordinator.sourceState = AppearanceSettingsSourceState(
            subtitle: "Using Zentty defaults. Appearance changes stay local until you create a shared Ghostty config.",
            showsCreateSharedConfigAction: true
        )
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.isCreateSharedConfigButtonHiddenForTesting)
    }

    func testCreateSharedConfigActionCallsCoordinator() async {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.loadViewIfNeeded()
        controller.createSharedConfigForTesting()
        await waitForCondition { coordinator.createSharedConfigCallCount == 1 }

        XCTAssertEqual(coordinator.createSharedConfigCallCount, 1)
    }

    func testOpacityChangeCallsCoordinator() async throws {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.loadViewIfNeeded()
        controller.setOpacityForTesting(0.62)
        await waitForCondition { coordinator.appliedOpacities.count == 1 }

        let opacity = try XCTUnwrap(coordinator.appliedOpacities.first)
        XCTAssertEqual(opacity, 0.62, accuracy: 0.0001)
    }

    func testConformsToSettingsAppearanceUpdating() {
        let controller = AppearanceSettingsSectionViewController(
            configCoordinator: StubConfigCoordinator()
        )
        XCTAssertTrue(controller is SettingsAppearanceUpdating)
    }
}
