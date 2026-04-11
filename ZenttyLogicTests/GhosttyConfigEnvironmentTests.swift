import AppKit
import XCTest
@testable import Zentty

final class GhosttyConfigEnvironmentTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var homeDirectoryURL: URL!
    private var bundledDefaultsURL: URL!

    override func setUpWithError() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        homeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)

        bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty")
        try """
        theme = \(persistedFallbackThemeName)
        background-opacity = 0.80
        """.write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_resolvedStack_uses_shared_ghostty_files_in_precedence_order_and_picks_highest_precedence_write_target() throws {
        let legacyXDGURL = try makeFile(
            relativePath: ".config/ghostty/config",
            contents: "theme = One\n"
        )
        let appSupportURL = try makeFile(
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            contents: "theme = Two\n"
        )

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { AppConfig.default }
        )

        let stack = try XCTUnwrap(environment.resolvedStack())

        XCTAssertEqual(
            stack.loadFiles,
            [appSupportURL, legacyXDGURL]
        )
        XCTAssertEqual(stack.writeTargetURL, legacyXDGURL)
        XCTAssertNil(stack.localOverrideContents)
        XCTAssertFalse(stack.usesBundledDefaultsOnly)
    }

    func test_preferredCreateTargetURL_uses_xdg_path_on_macos() {
        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { AppConfig.default }
        )

        XCTAssertEqual(
            environment.preferredCreateTargetURL,
            homeDirectoryURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false)
        )
    }

    func test_resolvedStack_treats_app_support_only_config_as_read_only_compatibility_source() throws {
        let appSupportURL = try makeFile(
            relativePath: "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            contents: "theme = Two\n"
        )

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { AppConfig.default }
        )

        let stack = try XCTUnwrap(environment.resolvedStack())

        XCTAssertEqual(stack.mode, .sharedGhostty)
        XCTAssertEqual(stack.loadFiles, [appSupportURL])
        XCTAssertNil(stack.writeTargetURL)
        XCTAssertEqual(stack.preferredCreateTargetURL, environment.preferredCreateTargetURL)
        XCTAssertFalse(stack.usesBundledDefaultsOnly)
    }

    func test_resolvedStack_uses_bundled_defaults_and_local_appearance_overrides_when_no_shared_config_exists() throws {
        var appConfig = AppConfig.default
        appConfig.appearance.localThemeName = "TokyoNight"
        appConfig.appearance.localBackgroundOpacity = 0.67

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { appConfig }
        )

        let stack = try XCTUnwrap(environment.resolvedStack())

        XCTAssertEqual(stack.loadFiles, [bundledDefaultsURL])
        XCTAssertNil(stack.writeTargetURL)
        XCTAssertEqual(
            stack.localOverrideContents,
            """
            theme = TokyoNight
            background-opacity = 0.67
            """
        )
        XCTAssertEqual(stack.preferredCreateTargetURL.path, environment.preferredCreateTargetURL.path)
        XCTAssertTrue(stack.usesBundledDefaultsOnly)
    }

    func test_resolvedStack_ignores_local_appearance_overrides_when_shared_ghostty_config_exists() throws {
        let sharedURL = try makeFile(
            relativePath: ".config/ghostty/config.ghostty",
            contents: "theme = Shared\n"
        )
        var appConfig = AppConfig.default
        appConfig.appearance.localThemeName = "Local"
        appConfig.appearance.localBackgroundOpacity = 0.45

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { appConfig }
        )

        let stack = try XCTUnwrap(environment.resolvedStack())

        XCTAssertEqual(stack.loadFiles, [sharedURL])
        XCTAssertEqual(stack.writeTargetURL, sharedURL)
        XCTAssertNil(stack.localOverrideContents)
    }

    func test_mergedUserConfigContents_includes_recursive_config_file_contents() throws {
        let includedURL = try makeFile(
            relativePath: ".config/ghostty/includes/blur.ghostty",
            contents: "background-blur-radius = 30\n"
        )
        let sharedURL = try makeFile(
            relativePath: ".config/ghostty/config.ghostty",
            contents: """
            theme = Shared
            config-file = includes/blur.ghostty
            """
        )

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { AppConfig.default }
        )

        let stack = try XCTUnwrap(environment.resolvedStack())
        let contents = try XCTUnwrap(stack.mergedUserConfigContents())

        XCTAssertTrue(contents.contains("theme = Shared"))
        XCTAssertTrue(contents.contains("config-file = includes/blur.ghostty"))
        XCTAssertTrue(contents.contains("background-blur-radius = 30"))
        XCTAssertEqual(stack.loadFiles, [sharedURL])
        XCTAssertNotEqual(sharedURL, includedURL)
    }

    private func makeFile(relativePath: String, contents: String) throws -> URL {
        let url = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
