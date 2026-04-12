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
        displayName: String? = nil,
        background: String = "#000000",
        foreground: String = "#ffffff"
    ) -> ThemePreview {
        ThemePreview(
            name: name,
            displayName: displayName ?? name,
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

    private func firstSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider {
            return slider
        }

        for subview in view.subviews {
            if let slider = firstSlider(in: subview) {
                return slider
            }
        }

        return nil
    }

    private func render(view: NSView, size: NSSize) {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        XCTAssertNotNil(bitmap)
        guard let bitmap else {
            return
        }

        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    // MARK: - Tests

    func testTablePopulatesWithDiscoveredThemes() async {
        let themes = [
            makeTheme(name: "Dracula"),
            makeTheme(name: "Solarized"),
            makeTheme(name: "TokyoNight"),
        ]

        let (controller, _, _) = makeController(themes: themes)
        await controller.loadThemesForTesting()

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
        await controller.loadThemesForTesting()

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
        await controller.loadThemesForTesting()

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
        await controller.loadThemesForTesting()

        await controller.selectThemeForTesting("Dracula")

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
        await controller.loadThemesForTesting()

        currentAppearanceTheme = "DarkTheme"
        controller.handleAppearanceChange()

        XCTAssertEqual(controller.activeThemeNameForTesting, "DarkTheme")
    }

    func testActiveBuiltInDefaultThemeRemainsSelectableWhenOtherThemesExist() async {
        let themes = [
            makeTheme(
                name: "Zentty-Default",
                displayName: "Zentty Default Theme",
                background: "#0A0C10",
                foreground: "#F0F3F6"
            ),
            makeTheme(name: "TokyoNight"),
        ]

        let (controller, _, _) = makeController(
            themes: themes,
            activeThemeName: "Zentty-Default"
        )
        await controller.loadThemesForTesting()

        XCTAssertEqual(controller.activeThemeNameForTesting, "Zentty-Default")
        XCTAssertEqual(controller.themes.map(\.displayName), ["Zentty Default Theme", "TokyoNight"])
    }

    func testMissingCurrentThemeFallsBackToBuiltInDefaultTheme() async {
        let themes = [
            makeTheme(
                name: "Zentty-Default",
                displayName: "Zentty Default Theme",
                background: "#0A0C10",
                foreground: "#F0F3F6"
            ),
            makeTheme(name: "TokyoNight"),
        ]

        let (controller, _, _) = makeController(
            themes: themes,
            activeThemeName: nil
        )
        await controller.loadThemesForTesting()

        XCTAssertEqual(controller.activeThemeNameForTesting, "Zentty-Default")
    }

    func testMissingCurrentOpacityFallsBackToNinetyFivePercent() {
        let (controller, _, _) = makeController(backgroundOpacity: nil)

        controller.loadViewIfNeeded()

        guard let slider = firstSlider(in: controller.view) else {
            XCTFail("Expected opacity slider")
            return
        }

        XCTAssertEqual(slider.doubleValue, 0.95, accuracy: 0.0001)
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
        await controller.createSharedConfigForTesting()

        XCTAssertEqual(coordinator.createSharedConfigCallCount, 1)
    }

    func testOpacityChangeCallsCoordinator() async throws {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.loadViewIfNeeded()
        await controller.setOpacityForTesting(0.62)

        let opacity = try XCTUnwrap(coordinator.appliedOpacities.first)
        XCTAssertEqual(opacity, 0.62, accuracy: 0.0001)
    }

    func testPreviewTextAttributesFallsBackWhenPreferredFontProviderReturnsNil() throws {
        let attributes = try XCTUnwrap(
            ThemePreviewTextAttributes.make(
                foreground: NSColor(hexString: "#F0F3F6")!,
                background: NSColor(hexString: "#0A0C10")!,
                pointSize: 7,
                weight: .medium,
                preferredFontProvider: { _, _ in nil }
            )
        )

        XCTAssertNotNil(attributes[.font] as? NSFont)
        XCTAssertNotNil(attributes[.foregroundColor] as? NSColor)
    }

    func testRenderingAppearanceSettingsControllerDoesNotCrash() async {
        let themes = [
            makeTheme(
                name: "Zentty-Default",
                displayName: "Zentty Default Theme",
                background: "#0A0C10",
                foreground: "#F0F3F6"
            ),
            makeTheme(
                name: "Bright",
                background: "#F7FBFF",
                foreground: "#102030"
            ),
        ]

        let (controller, _, _) = makeController(
            themes: themes,
            activeThemeName: "Zentty-Default"
        )
        await controller.loadThemesForTesting()

        render(view: controller.view, size: NSSize(width: 860, height: 760))
        render(view: controller.view, size: NSSize(width: 860, height: 760))
    }

    func testConformsToSettingsAppearanceUpdating() {
        let controller = AppearanceSettingsSectionViewController(
            configCoordinator: StubConfigCoordinator()
        )
        XCTAssertTrue(controller is SettingsAppearanceUpdating)
    }
}
