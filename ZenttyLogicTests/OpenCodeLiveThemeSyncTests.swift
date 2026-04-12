@testable import Zentty
import AppKit
import XCTest

@MainActor
final class OpenCodeLiveThemeSyncTests: AppKitTestCase {
    private var temporaryDirectoryURL: URL!
    private var runtimeDirectoryURL: URL!
    private var homeDirectoryURL: URL!
    private var bundledDefaultsURL: URL!
    private var themeDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.OpenCodeLiveThemeSync.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        runtimeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("runtime", isDirectory: true)
        homeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty", isDirectory: false)
        themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)

        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_sync_running_panes_rewrites_synced_theme_and_signals_pid() throws {
        try """
        background = #101820
        foreground = #E6EDF3
        palette = 4=#58A6FF
        palette = 6=#39C5CF
        palette = 12=#79C0FF
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

        let pane = OpenCodeRunningPane(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main"),
            pid: 4242
        )
        let overlayConfigDirectory = OpenCodeOverlayLayout
            .overlayRoots(
                runtimeDirectoryURL: runtimeDirectoryURL,
                worklaneID: pane.worklaneID,
                paneID: pane.paneID
            )
            .configDirectoryURL
        let themesDirectoryURL = overlayConfigDirectory.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
        try """
        {
          "$schema": "https://opencode.ai/tui.json",
          "theme": "zentty-synced"
        }
        """.write(
            to: overlayConfigDirectory.appendingPathComponent("tui.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "$schema": "https://opencode.ai/theme.json",
          "theme": {
            "background": {
              "dark": "#000000",
              "light": "#ffffff"
            }
          }
        }
        """.write(
            to: themesDirectoryURL.appendingPathComponent("zentty-synced.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var signaledPIDs: [Int32] = []
        let signaled = try OpenCodeLiveThemeSync.syncRunningPanes(
            [pane],
            runtimeDirectoryURL: runtimeDirectoryURL,
            appConfig: config,
            configEnvironment: environment,
            effectiveAppearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            themeDirectories: [themeDirectoryURL],
            isProcessAlive: { $0 == pane.pid },
            signaler: { pid in
                signaledPIDs.append(pid)
            }
        )

        XCTAssertEqual(signaled, [pane.pid])
        XCTAssertEqual(signaledPIDs, [pane.pid])

        let syncedTheme = try loadJSONObject(
            from: themesDirectoryURL.appendingPathComponent("zentty-synced.json", isDirectory: false)
        )
        let theme = try XCTUnwrap(syncedTheme["theme"] as? [String: Any])
        XCTAssertEqual(try tokenVariant("background", in: theme)["dark"], "#101820")
        XCTAssertEqual(try tokenVariant("text", in: theme)["dark"], "#E6EDF3")
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
