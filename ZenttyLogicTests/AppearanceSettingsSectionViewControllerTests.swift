@testable import Zentty
import XCTest

@MainActor
final class AppearanceSettingsSectionViewControllerTests: XCTestCase {

    // MARK: - Stubs

    private final class StubCatalogProvider: ThemeCatalogProviding {
        var themes: [ThemePreview] = []

        func loadThemes() async -> [ThemePreview] {
            themes
        }
    }

    private final class SpyConfigWriter: GhosttyConfigWriting {
        private(set) var writtenValues: [(key: String, value: String)] = []

        var writtenThemes: [String] {
            writtenValues.filter { $0.key == "theme" }.map(\.value)
        }

        func updateValue(_ value: String, forKey key: String) {
            writtenValues.append((key: key, value: value))
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
        configWriter: SpyConfigWriter = SpyConfigWriter(),
        reloadCount: UnsafeMutablePointer<Int>? = nil
    ) -> (AppearanceSettingsSectionViewController, StubCatalogProvider, SpyConfigWriter) {
        let catalog = StubCatalogProvider()
        catalog.themes = themes

        var reloadCallCount = 0
        let controller = AppearanceSettingsSectionViewController(
            catalogProvider: catalog,
            configWriter: configWriter,
            currentThemeName: { _ in activeThemeName },
            currentBackgroundOpacity: { backgroundOpacity },
            runtimeReload: {
                reloadCallCount += 1
                reloadCount?.pointee = reloadCallCount
            }
        )
        return (controller, catalog, configWriter)
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
        let writer = SpyConfigWriter()
        var reloadCount = 0

        let (controller, _, _) = makeController(
            themes: themes,
            configWriter: writer,
            reloadCount: &reloadCount
        )
        await loadAndWaitForThemes(controller)

        controller.selectThemeForTesting("Dracula")

        XCTAssertEqual(writer.writtenThemes, ["Dracula"])
        XCTAssertEqual(reloadCount, 1)
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
            configWriter: SpyConfigWriter(),
            currentThemeName: { _ in currentAppearanceTheme },
            currentBackgroundOpacity: { 0.8 },
            runtimeReload: {}
        )
        await loadAndWaitForThemes(controller)

        currentAppearanceTheme = "DarkTheme"
        controller.handleAppearanceChange()

        XCTAssertEqual(controller.activeThemeNameForTesting, "DarkTheme")
    }

    func testConformsToSettingsAppearanceUpdating() {
        let controller = AppearanceSettingsSectionViewController()
        XCTAssertTrue(controller is SettingsAppearanceUpdating)
    }
}
