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
        var themePreferences = AppearanceThemePreferences(
            mode: .alwaysDark,
            darkThemeName: nil,
            lightThemeName: nil
        )
        var syncOpenCodeThemeWithTerminal = false
        private(set) var appliedThemes: [String] = []
        private(set) var appliedThemeSlots: [AppearanceThemeSlot] = []
        private(set) var appliedThemeModes: [AppConfig.Appearance.ThemeMode] = []
        private(set) var resetThemePreferencesCallCount = 0
        private(set) var appliedOpacities: [CGFloat] = []
        private(set) var appliedOpenCodeThemeSyncValues: [Bool] = []
        private(set) var createSharedConfigCallCount = 0

        func applyTheme(_ name: String, presentingWindow _: NSWindow?) async {
            appliedThemes.append(name)
        }

        func applyTheme(_ name: String, slot: AppearanceThemeSlot, presentingWindow _: NSWindow?) async {
            appliedThemes.append(name)
            appliedThemeSlots.append(slot)
        }

        func applyThemeMode(_ mode: AppConfig.Appearance.ThemeMode, presentingWindow _: NSWindow?) async {
            themePreferences.mode = mode
            appliedThemeModes.append(mode)
        }

        func resetThemePreferences(presentingWindow _: NSWindow?) async {
            themePreferences = AppearanceThemePreferences(
                mode: .alwaysDark,
                darkThemeName: nil,
                lightThemeName: nil
            )
            resetThemePreferencesCallCount += 1
        }

        func applyBackgroundOpacity(_ opacity: CGFloat, presentingWindow _: NSWindow?) async {
            appliedOpacities.append(opacity)
        }

        func applyOpenCodeThemeSync(_ enabled: Bool) async {
            syncOpenCodeThemeWithTerminal = enabled
            appliedOpenCodeThemeSyncValues.append(enabled)
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
        configCoordinator: StubConfigCoordinator? = nil
    ) -> (AppearanceSettingsSectionViewController, StubCatalogProvider, StubConfigCoordinator) {
        let actualConfigCoordinator = configCoordinator ?? StubConfigCoordinator()
        let catalog = StubCatalogProvider()
        catalog.themes = themes

        let controller = AppearanceSettingsSectionViewController(
            catalogProvider: catalog,
            configCoordinator: actualConfigCoordinator,
            currentThemeName: { _ in activeThemeName },
            currentBackgroundOpacity: { backgroundOpacity }
        )
        return (controller, catalog, actualConfigCoordinator)
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

    private func labelStrings(in view: NSView) -> [String] {
        let ownLabel = (view as? NSTextField)
            .flatMap { $0.isEditable ? nil : $0.stringValue }
            .map { [$0] } ?? []

        return ownLabel + view.subviews.flatMap { labelStrings(in: $0) }
    }

    private func viewClassNames(in view: NSView) -> [String] {
        [String(describing: type(of: view))] + view.subviews.flatMap { viewClassNames(in: $0) }
    }

    private func makeVisibleWindow(
        with controller: NSViewController,
        size: NSSize = NSSize(width: 980, height: 760)
    ) -> NSWindow {
        controller.backwardCompatibleLoadViewIfNeeded()
        controller.view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        window.contentView = controller.view
        window.orderFrontRegardless()
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        return window
    }

    private func renderView(_ view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Expected bitmap image rep for rendering")
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

    func testSelectingLightSlotAppliesThemeToLightPreference() async {
        let themes = [
            makeTheme(name: "TokyoNight", background: "#05070A", foreground: "#F0F3F6"),
            makeTheme(name: "GitHub Light Default", background: "#FFFFFF", foreground: "#102030"),
        ]
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(
            themes: themes,
            configCoordinator: coordinator
        )
        await controller.loadThemesForTesting()

        controller.selectThemeSlotForTesting(.light)
        await controller.selectThemeForTesting("GitHub Light Default")

        XCTAssertEqual(coordinator.appliedThemes, ["GitHub Light Default"])
        XCTAssertEqual(coordinator.appliedThemeSlots, [.light])
        XCTAssertEqual(controller.editingThemeSlotForTesting, .light)
    }

    func testThemeModeSelectionCallsCoordinator() async {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)
        controller.backwardCompatibleLoadViewIfNeeded()

        await controller.selectThemeModeForTesting(.followMacOS)

        XCTAssertEqual(coordinator.appliedThemeModes, [.followMacOS])
        XCTAssertEqual(controller.themeModeForTesting, .followMacOS)
    }

    func testThemePickerHasSeparateThemesSection() {
        let (controller, _, _) = makeController()
        controller.backwardCompatibleLoadViewIfNeeded()

        let labels = labelStrings(in: controller.view)

        XCTAssertTrue(labels.contains("Theme Behavior"))
        XCTAssertTrue(labels.contains("Themes"))
        XCTAssertTrue(labels.contains("Choose the dark and light themes used by the behavior above."))
    }

    func testThemeSlotTabsRenderSelectedThemePreviews() async {
        let themes = [
            makeTheme(name: "DarkTheme", background: "#05070A", foreground: "#F0F3F6"),
            makeTheme(name: "LightTheme", background: "#FFFFFF", foreground: "#102030"),
        ]
        let coordinator = StubConfigCoordinator()
        coordinator.themePreferences.darkThemeName = "DarkTheme"
        coordinator.themePreferences.lightThemeName = "LightTheme"
        let (controller, _, _) = makeController(
            themes: themes,
            configCoordinator: coordinator
        )

        await controller.loadThemesForTesting()

        let slotPreviewCount = viewClassNames(in: controller.view)
            .filter { $0.contains("ThemeSlotPreviewView") }
            .count
        XCTAssertEqual(slotPreviewCount, 2)
    }

    func testThemeFilterDefaultsToEditingSlotBrightness() async {
        let themes = [
            makeTheme(name: "DarkTheme", background: "#05070A", foreground: "#F0F3F6"),
            makeTheme(name: "LightTheme", background: "#FFFFFF", foreground: "#102030"),
        ]
        let (controller, _, _) = makeController(themes: themes)
        await controller.loadThemesForTesting()

        XCTAssertEqual(controller.themes.map(\.name), ["DarkTheme"])

        controller.selectThemeSlotForTesting(.light)
        XCTAssertEqual(controller.themes.map(\.name), ["LightTheme"])
    }

    func testExplicitAllThemeFilterPersistsWhenSwitchingSlots() async {
        let themes = [
            makeTheme(name: "DarkTheme", background: "#05070A", foreground: "#F0F3F6"),
            makeTheme(name: "LightTheme", background: "#FFFFFF", foreground: "#102030"),
        ]
        let (controller, _, _) = makeController(themes: themes)
        await controller.loadThemesForTesting()

        controller.setThemeCatalogFilterForTesting(2)
        controller.selectThemeSlotForTesting(.light)

        XCTAssertEqual(controller.themes.map(\.name), ["DarkTheme", "LightTheme"])
    }

    func testResetThemePreferencesClearsTransientSlotAndFilterChoices() async {
        let themes = [
            makeTheme(name: "DarkTheme", background: "#05070A", foreground: "#F0F3F6"),
            makeTheme(name: "LightTheme", background: "#FFFFFF", foreground: "#102030"),
        ]
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(
            themes: themes,
            configCoordinator: coordinator
        )
        await controller.loadThemesForTesting()

        controller.setThemeCatalogFilterForTesting(2)
        controller.selectThemeSlotForTesting(.light)
        await controller.resetThemePreferencesForTesting()

        XCTAssertEqual(coordinator.resetThemePreferencesCallCount, 1)
        XCTAssertEqual(controller.editingThemeSlotForTesting, .dark)
        XCTAssertEqual(controller.themes.map(\.name), ["DarkTheme"])
    }

    func testCurrentThemeSummaryShowsEffectiveTheme() async {
        let themes = [
            makeTheme(name: "TokyoNight", displayName: "Tokyo Night"),
        ]
        let (controller, _, _) = makeController(
            themes: themes,
            activeThemeName: "TokyoNight"
        )

        await controller.loadThemesForTesting()

        XCTAssertEqual(controller.currentThemeSummaryForTesting, "Current: Tokyo Night")
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

    func testActiveBuiltInDefaultThemeRemainsSelectableWhenOtherThemesExist() async throws {
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
        let window = makeVisibleWindow(with: controller)
        addTeardownBlock {
            window.close()
        }
        await controller.loadThemesForTesting()
        try renderView(controller.view)

        XCTAssertEqual(controller.activeThemeNameForTesting, "Zentty-Default")
        XCTAssertEqual(controller.themes.map(\.displayName), ["Zentty Default Theme", "TokyoNight"])
    }

    func testSavedBuiltInAliasSelectsCanonicalPreviewTheme() async {
        let themes = [
            makeTheme(
                name: "Zentty-Default",
                displayName: "Zentty Default Theme",
                background: "#0A0C10",
                foreground: "#F0F3F6"
            ),
            makeTheme(name: "TokyoNight"),
        ]
        let coordinator = StubConfigCoordinator()
        coordinator.themePreferences.darkThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName

        let (controller, _, _) = makeController(
            themes: themes,
            configCoordinator: coordinator
        )

        await controller.loadThemesForTesting()

        XCTAssertEqual(controller.selectedPreviewThemeNameForTesting, "Zentty-Default")
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

        controller.backwardCompatibleLoadViewIfNeeded()

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

        controller.backwardCompatibleLoadViewIfNeeded()

        XCTAssertFalse(controller.isCreateSharedConfigButtonHiddenForTesting)
    }

    func testCreateSharedConfigActionCallsCoordinator() async {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.backwardCompatibleLoadViewIfNeeded()
        await controller.createSharedConfigForTesting()

        XCTAssertEqual(coordinator.createSharedConfigCallCount, 1)
    }

    func testOpacityChangeCallsCoordinator() async throws {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.backwardCompatibleLoadViewIfNeeded()
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

    func testRenderingAppearanceSettingsControllerDoesNotCrash() async throws {
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

        let window = makeVisibleWindow(with: controller, size: NSSize(width: 860, height: 760))
        addTeardownBlock {
            window.close()
        }

        try renderView(controller.view)
        try renderView(controller.view)
    }

    func testOpenCodeThemeSyncToggleReflectsCoordinatorState() {
        let coordinator = StubConfigCoordinator()
        coordinator.syncOpenCodeThemeWithTerminal = true
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.backwardCompatibleLoadViewIfNeeded()

        XCTAssertTrue(controller.isOpenCodeThemeSyncEnabledForTesting)
    }

    func testOpenCodeThemeSyncToggleCallsCoordinator() async {
        let coordinator = StubConfigCoordinator()
        let (controller, _, _) = makeController(configCoordinator: coordinator)

        controller.backwardCompatibleLoadViewIfNeeded()
        controller.setOpenCodeThemeSyncEnabledForTesting(true)
        await waitForCondition { coordinator.appliedOpenCodeThemeSyncValues == [true] }

        XCTAssertEqual(coordinator.appliedOpenCodeThemeSyncValues, [true])
    }

    func testConformsToSettingsAppearanceUpdating() {
        let controller = AppearanceSettingsSectionViewController(
            configCoordinator: StubConfigCoordinator()
        )
        XCTAssertTrue(controller is SettingsAppearanceUpdating)
    }
}
