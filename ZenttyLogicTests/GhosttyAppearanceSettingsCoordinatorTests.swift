@testable import Zentty
import XCTest

@MainActor
final class GhosttyAppearanceSettingsCoordinatorTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var homeDirectoryURL: URL!
    private var bundledDefaultsURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        homeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)

        bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty")
        try """
        theme = BundledTheme
        background-opacity = 0.80
        """.write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_applyTheme_withSharedConfig_writesThroughWithoutPrompt() async throws {
        let store = makeConfigStore()
        let sharedConfigURL = try makeGhosttyConfig(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "theme = Existing\n"
        )

        var decisionCallCount = 0
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in
                decisionCallCount += 1
                return .keepOnlyInZentty
            },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyTheme("TokyoNight", presentingWindow: nil)

        let content = try String(contentsOf: sharedConfigURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = TokyoNight"))
        XCTAssertEqual(decisionCallCount, 0)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(store.current.appearance.themeMode, .alwaysDark)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "TokyoNight")
        XCTAssertNil(store.current.appearance.preferredLightThemeName)
        XCTAssertEqual(
            coordinator.sourceState,
            AppearanceSettingsSourceState(
                subtitle: "Using your Ghostty config.",
                showsCreateSharedConfigAction: false
            )
        )
    }

    func test_applyTheme_with_app_support_only_shared_config_seeds_xdg_config_without_prompt() async throws {
        let store = makeConfigStore()
        let appSupportConfigURL = try makeGhosttyConfig(
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            contents: """
            theme = Existing
            background-opacity = 0.88
            """
        )

        var decisionCallCount = 0
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in
                decisionCallCount += 1
                return .keepOnlyInZentty
            },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyTheme("TokyoNight", presentingWindow: nil)

        let content = try String(contentsOf: coordinatorTestCreateTargetURL(), encoding: .utf8)
        XCTAssertTrue(content.contains("theme = TokyoNight"))
        XCTAssertTrue(content.contains("background-opacity = 0.88"))
        XCTAssertEqual(try String(contentsOf: appSupportConfigURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       """
                       theme = Existing
                       background-opacity = 0.88
                       """.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(decisionCallCount, 0)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "TokyoNight")
        XCTAssertEqual(
            coordinator.sourceState,
            AppearanceSettingsSourceState(
                subtitle: "Using your Ghostty config.",
                showsCreateSharedConfigAction: false
            )
        )
    }

    func test_localOnlyAppearanceChangesPersistWithoutPrompt() async throws {
        let store = makeConfigStore()
        let promptSession = GhosttySharedConfigPromptSession()
        var decisionCallCount = 0
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in
                decisionCallCount += 1
                return .keepOnlyInZentty
            },
            promptSession: promptSession,
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyTheme("TokyoNight", presentingWindow: nil)
        await coordinator.applyBackgroundOpacity(0.67, presentingWindow: nil)

        XCTAssertEqual(store.current.appearance.localThemeName, "TokyoNight")
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "TokyoNight")
        XCTAssertEqual(try XCTUnwrap(store.current.appearance.localBackgroundOpacity), 0.67, accuracy: 0.0001)
        XCTAssertEqual(decisionCallCount, 0)
        XCTAssertEqual(reloadCount, 2)
        XCTAssertNil(try? String(contentsOf: coordinatorTestCreateTargetURL(), encoding: .utf8))
        XCTAssertEqual(
            coordinator.sourceState,
            AppearanceSettingsSourceState(
                subtitle: "Using Zentty defaults. Appearance changes stay local until you create a shared Ghostty config.",
                showsCreateSharedConfigAction: true
            )
        )
    }

    func test_applyTheme_withBuiltInAlias_persistsGhosttyCompatibleThemeName() async throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let store = makeConfigStore()
        let promptSession = GhosttySharedConfigPromptSession()
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .keepOnlyInZentty },
            promptSession: promptSession,
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyTheme("Zentty-Default", presentingWindow: nil)

        XCTAssertEqual(store.current.appearance.localThemeName, persistedFallbackThemeName)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, persistedFallbackThemeName)
        XCTAssertEqual(reloadCount, 1)
    }

    func test_createSharedConfig_seedsBundledDefaultsAndLocalOverrides_thenKeepsLocalThemeMemory() async throws {
        let store = makeConfigStore()
        try store.update { config in
            config.appearance.preferredDarkThemeName = "LocalTheme"
            config.appearance.preferredLightThemeName = "GitHub Light Default"
            config.appearance.localThemeName = "LocalTheme"
            config.appearance.localBackgroundOpacity = 0.65
        }

        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .createSharedConfig },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.createSharedConfig(presentingWindow: nil)

        let targetURL = coordinatorTestCreateTargetURL()
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = LocalTheme"))
        XCTAssertTrue(content.contains("background-opacity = 0.65"))
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "LocalTheme")
        XCTAssertEqual(store.current.appearance.preferredLightThemeName, "GitHub Light Default")
        XCTAssertEqual(reloadCount, 1)
    }

    func test_applyThemeMode_writesGhosttyPairAndKeepsInactiveSlotMemory() async throws {
        let store = makeConfigStore()
        var reloadCount = 0
        let sharedConfigURL = try makeGhosttyConfig(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "theme = TokyoNight\n"
        )
        try store.update { config in
            config.appearance.preferredLightThemeName = "GitHub Light Default"
        }
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .cancel },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyThemeMode(.followMacOS, presentingWindow: nil)

        let content = try String(contentsOf: sharedConfigURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = dark:TokyoNight,light:GitHub Light Default"))
        XCTAssertEqual(store.current.appearance.themeMode, .followMacOS)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "TokyoNight")
        XCTAssertEqual(store.current.appearance.preferredLightThemeName, "GitHub Light Default")
        XCTAssertEqual(reloadCount, 1)
    }

    func test_applyAlwaysLightMode_keepsModeAndDarkThemeMemoryWhenSharedConfigStoresSingleTheme() async throws {
        let store = makeConfigStore()
        var reloadCount = 0
        let sharedConfigURL = try makeGhosttyConfig(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "theme = TokyoNight\n"
        )
        try store.update { config in
            config.appearance.preferredLightThemeName = "GitHub Light Default"
        }
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .cancel },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyThemeMode(.alwaysLight, presentingWindow: nil)

        let content = try String(contentsOf: sharedConfigURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = GitHub Light Default"))
        XCTAssertEqual(store.current.appearance.themeMode, .alwaysLight)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "TokyoNight")
        XCTAssertEqual(store.current.appearance.preferredLightThemeName, "GitHub Light Default")
        XCTAssertEqual(coordinator.themePreferences.mode, .alwaysLight)
        XCTAssertEqual(coordinator.themePreferences.darkThemeName, "TokyoNight")
        XCTAssertEqual(coordinator.themePreferences.lightThemeName, "GitHub Light Default")
        XCTAssertEqual(reloadCount, 1)
    }

    func test_applyThemeMode_respectsThemeDeclaredAfterConfigFileInclude() async throws {
        let store = makeConfigStore()
        var reloadCount = 0
        let sharedConfigURL = try makeGhosttyConfig(
            relativePath: ".config/ghostty/config.ghostty",
            contents: """
            theme = ParentBefore
            config-file = child.conf
            theme = ParentAfter
            """
        )
        _ = try makeGhosttyConfig(
            relativePath: ".config/ghostty/child.conf",
            contents: "theme = ChildTheme\n"
        )
        try store.update { config in
            config.appearance.preferredLightThemeName = "GitHub Light Default"
        }
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .cancel },
            runtimeReload: { reloadCount += 1 }
        )

        XCTAssertEqual(coordinator.themePreferences.darkThemeName, "ParentAfter")

        await coordinator.applyThemeMode(.followMacOS, presentingWindow: nil)

        let content = try String(contentsOf: sharedConfigURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = dark:ParentAfter,light:GitHub Light Default"))
        XCTAssertEqual(store.current.appearance.themeMode, .followMacOS)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, "ParentAfter")
        XCTAssertEqual(store.current.appearance.preferredLightThemeName, "GitHub Light Default")
        XCTAssertEqual(reloadCount, 1)
    }

    func test_resetThemePreferencesRestoresAlwaysDarkWithRememberedLightDefault() async throws {
        let store = makeConfigStore()
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .keepOnlyInZentty },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.resetThemePreferences(presentingWindow: nil)

        XCTAssertEqual(store.current.appearance.themeMode, .alwaysDark)
        XCTAssertEqual(store.current.appearance.preferredDarkThemeName, GhosttyThemeLibrary.fallbackPersistedThemeName)
        XCTAssertEqual(store.current.appearance.preferredLightThemeName, GhosttyThemeLibrary.fallbackLightThemeName)
        XCTAssertEqual(store.current.appearance.localThemeName, GhosttyThemeLibrary.fallbackPersistedThemeName)
        XCTAssertEqual(reloadCount, 1)
    }

    private func makeConfigStore() -> AppConfigStore {
        AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.toml")
        )
    }

    private func makeCoordinator(
        store: AppConfigStore,
        decisionProvider: @escaping GhosttySharedConfigDecisionProvider,
        promptSession: GhosttySharedConfigPromptSession = GhosttySharedConfigPromptSession(),
        runtimeReload: @escaping @MainActor () -> Void
    ) -> GhosttyAppearanceSettingsCoordinator {
        let configEnvironmentProvider = {
            GhosttyConfigEnvironment(
                homeDirectoryURL: self.homeDirectoryURL,
                bundledDefaultsURL: self.bundledDefaultsURL,
                appConfigProvider: { store.current }
            )
        }

        return GhosttyAppearanceSettingsCoordinator(
            configStore: store,
            configEnvironmentProvider: configEnvironmentProvider,
            runtimeReload: runtimeReload,
            decisionProvider: decisionProvider,
            promptSession: promptSession
        )
    }

    private func makeGhosttyConfig(relativePath: String, contents: String) throws -> URL {
        let url = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func coordinatorTestCreateTargetURL() -> URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }
}
