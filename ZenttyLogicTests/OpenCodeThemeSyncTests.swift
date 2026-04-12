@testable import Zentty
import AppKit
import XCTest

@MainActor
final class OpenCodeThemeSyncTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var homeDirectoryURL: URL!
    private var bundledDefaultsURL: URL!
    private var overlayConfigDirectoryURL: URL!
    private var themeDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.OpenCodeThemeSync.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        homeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        overlayConfigDirectoryURL = temporaryDirectoryURL.appendingPathComponent("overlay", isDirectory: true)
        themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty", isDirectory: false)

        try FileManager.default.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlayConfigDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)
        try "theme = TokyoNight\n".write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_apply_writes_stable_synced_theme_when_counterpart_exists() throws {
        try """
        background = #1A1B26
        foreground = #C0CAF5
        palette = 1=#F7768E
        palette = 2=#9ECE6A
        palette = 3=#E0AF68
        palette = 4=#7AA2F7
        palette = 5=#BB9AF7
        palette = 6=#7DCFFF
        palette = 9=#F7768E
        palette = 10=#9ECE6A
        palette = 11=#E0AF68
        palette = 12=#7AA2F7
        palette = 13=#BB9AF7
        palette = 14=#7DCFFF
        """.write(
            to: themeDirectoryURL.appendingPathComponent("TokyoNight", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = TokyoNight\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        let tui = try loadJSONObject(
            from: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        )
        XCTAssertEqual(tui["theme"] as? String, "zentty-synced")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectoryURL
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent("zentty-synced.json", isDirectory: false)
                    .path
            )
        )
    }

    func test_apply_generates_custom_theme_when_no_exact_counterpart_exists() throws {
        try """
        background = #101820
        foreground = #E6EDF3
        cursor-color = #71B7FF
        palette = 1=#D73A49
        palette = 2=#2EA043
        palette = 3=#BF8700
        palette = 4=#58A6FF
        palette = 5=#BC8CFF
        palette = 6=#39C5CF
        palette = 9=#FF7B72
        palette = 10=#3FB950
        palette = 11=#D29922
        palette = 12=#79C0FF
        palette = 13=#D2A8FF
        palette = 14=#56D4DD
        """.write(
            to: themeDirectoryURL.appendingPathComponent("Custom Midnight", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = Custom Midnight\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        let tui = try loadJSONObject(
            from: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        )
        XCTAssertEqual(tui["theme"] as? String, "zentty-synced")

        let derived = try loadJSONObject(
            from: overlayConfigDirectoryURL
                .appendingPathComponent("themes", isDirectory: true)
                .appendingPathComponent("zentty-synced.json", isDirectory: false)
        )
        XCTAssertEqual(derived["$schema"] as? String, "https://opencode.ai/theme.json")
        let theme = try XCTUnwrap(derived["theme"] as? [String: Any])
        XCTAssertEqual(try tokenVariant("background", in: theme)["dark"], "#101820")
        XCTAssertEqual(try tokenVariant("text", in: theme)["dark"], "#E6EDF3")
        XCTAssertEqual(try tokenVariant("primary", in: theme)["dark"], "#79C0FF")
        XCTAssertEqual(try tokenVariant("secondary", in: theme)["dark"], "#D2A8FF")
        XCTAssertEqual(try tokenVariant("accent", in: theme)["dark"], "#D29922")
        XCTAssertEqual(try tokenVariant("success", in: theme)["dark"], "#3FB950")
        XCTAssertEqual(try tokenVariant("warning", in: theme)["dark"], "#D29922")
        XCTAssertEqual(try tokenVariant("error", in: theme)["dark"], "#FF7B72")
        XCTAssertEqual(try tokenVariant("info", in: theme)["dark"], "#56D4DD")
        XCTAssertEqual(try tokenVariant("primary", in: theme)["light"], "#79C0FF")
        XCTAssertEqual(theme["thinkingOpacity"] as? Double, 0.6)
    }

    func test_apply_overrides_existing_tui_theme_when_sync_enabled() throws {
        try """
        {
          "$schema": "https://opencode.ai/tui.json",
          "theme": "dracula"
        }
        """.write(
            to: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try """
        background = #1A1B26
        foreground = #C0CAF5
        palette = 4=#7AA2F7
        palette = 6=#7DCFFF
        palette = 12=#7AA2F7
        palette = 14=#7DCFFF
        """.write(
            to: themeDirectoryURL.appendingPathComponent("TokyoNight", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = TokyoNight\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        let tui = try loadJSONObject(
            from: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        )
        XCTAssertEqual(tui["theme"] as? String, "zentty-synced")
    }

    func test_apply_leaves_malformed_tui_untouched() throws {
        let malformed = """
        {
          "theme": "dracula",
        """
        try malformed.write(
            to: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try """
        background = #1A1B26
        foreground = #C0CAF5
        palette = 4=#7AA2F7
        palette = 12=#7AA2F7
        """.write(
            to: themeDirectoryURL.appendingPathComponent("TokyoNight", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = TokyoNight\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        XCTAssertEqual(
            try String(contentsOf: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)),
            malformed
        )
    }

    func test_apply_uses_explicit_light_and_dark_theme_pair_for_generated_variants() throws {
        try """
        background = #FFF8E7
        foreground = #3C3836
        palette = 4=#005F87
        palette = 6=#008787
        palette = 12=#1F78B4
        palette = 14=#00A3CC
        """.write(
            to: themeDirectoryURL.appendingPathComponent("Day Theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        background = #101820
        foreground = #E6EDF3
        palette = 4=#58A6FF
        palette = 6=#39C5CF
        palette = 12=#79C0FF
        palette = 14=#56D4DD
        """.write(
            to: themeDirectoryURL.appendingPathComponent("Night Theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = light:Day Theme,dark:Night Theme\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        let derived = try loadJSONObject(
            from: overlayConfigDirectoryURL
                .appendingPathComponent("themes", isDirectory: true)
                .appendingPathComponent("zentty-synced.json", isDirectory: false)
        )
        let theme = try XCTUnwrap(derived["theme"] as? [String: Any])
        XCTAssertEqual(try tokenVariant("background", in: theme)["dark"], "#101820")
        XCTAssertEqual(try tokenVariant("background", in: theme)["light"], "#FFF8E7")
        XCTAssertNotEqual(
            try tokenVariant("primary", in: theme)["dark"],
            try tokenVariant("primary", in: theme)["light"]
        )
    }

    func test_apply_generates_custom_theme_for_one_dark_pro_because_tui_has_no_builtin_counterpart() throws {
        try """
        background = #282C34
        foreground = #ABB2BF
        palette = 1=#E06C75
        palette = 2=#98C379
        palette = 3=#E5C07B
        palette = 4=#61AFEF
        palette = 5=#C678DD
        palette = 6=#56B6C2
        palette = 9=#E06C75
        palette = 10=#98C379
        palette = 11=#E5C07B
        palette = 12=#61AFEF
        palette = 13=#C678DD
        palette = 14=#56B6C2
        """.write(
            to: themeDirectoryURL.appendingPathComponent("One Dark Pro", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var config = AppConfig.default
        config.appearance.syncOpenCodeThemeWithTerminal = true
        let environment = makeGhosttyConfigEnvironment(
            appConfig: config,
            bundledDefaults: "theme = One Dark Pro\n"
        )

        try OpenCodeThemeSync.apply(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL]
        )

        let tui = try loadJSONObject(
            from: overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        )
        XCTAssertEqual(tui["theme"] as? String, "zentty-synced")
    }

    private func makeGhosttyConfigEnvironment(
        appConfig: AppConfig,
        bundledDefaults: String
    ) -> GhosttyConfigEnvironment {
        try? bundledDefaults.write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)
        return GhosttyConfigEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { appConfig }
        )
    }

    private func loadJSONObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func tokenVariant(
        _ key: String,
        in theme: [String: Any]
    ) throws -> [String: String] {
        try XCTUnwrap(theme[key] as? [String: String])
    }
}
