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
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
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
        XCTAssertEqual(store.current.appearance, .default)
        XCTAssertEqual(
            coordinator.sourceState,
            AppearanceSettingsSourceState(
                subtitle: "Using your Ghostty config.",
                showsCreateSharedConfigAction: false
            )
        )
    }

    func test_keepOnlyInZentty_prompt_persistsLocalOverrides_andOnlyPromptsOncePerSession() async throws {
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
        XCTAssertEqual(try XCTUnwrap(store.current.appearance.localBackgroundOpacity), 0.67, accuracy: 0.0001)
        XCTAssertEqual(decisionCallCount, 1)
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

    func test_createSharedConfig_seedsBundledDefaultsAndLocalOverrides_thenClearsLocalState() async throws {
        let store = makeConfigStore()
        try store.update { config in
            config.appearance.localThemeName = "LocalTheme"
        }

        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in .createSharedConfig },
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyBackgroundOpacity(0.65, presentingWindow: nil)

        let targetURL = coordinatorTestCreateTargetURL()
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = LocalTheme"))
        XCTAssertTrue(content.contains("background-opacity = 0.65"))
        XCTAssertEqual(store.current.appearance, .default)
        XCTAssertEqual(reloadCount, 1)
    }

    func test_cancel_prompt_skipsCurrentMutation_thenFutureWritesStayLocalWithoutReprompt() async throws {
        let store = makeConfigStore()
        let promptSession = GhosttySharedConfigPromptSession()
        var decisionCallCount = 0
        var reloadCount = 0
        let coordinator = makeCoordinator(
            store: store,
            decisionProvider: { _ in
                decisionCallCount += 1
                return .cancel
            },
            promptSession: promptSession,
            runtimeReload: { reloadCount += 1 }
        )

        await coordinator.applyTheme("TokyoNight", presentingWindow: nil)
        XCTAssertEqual(store.current.appearance, .default)
        XCTAssertEqual(decisionCallCount, 1)
        XCTAssertEqual(reloadCount, 0)

        await coordinator.applyBackgroundOpacity(0.55, presentingWindow: nil)

        XCTAssertNil(store.current.appearance.localThemeName)
        XCTAssertEqual(try XCTUnwrap(store.current.appearance.localBackgroundOpacity), 0.55, accuracy: 0.0001)
        XCTAssertEqual(decisionCallCount, 1)
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
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }
}
