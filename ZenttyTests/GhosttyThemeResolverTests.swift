import AppKit
import XCTest
@testable import Zentty

final class GhosttyThemeResolverTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_resolve_applies_config_overrides_after_theme_values() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)

        try """
        background = #0A0C10
        foreground = #F0F3F6
        cursor-color = #71B7FF
        """.write(to: themeDirectoryURL.appendingPathComponent("GitHub-Dark-Personal"), atomically: true, encoding: .utf8)

        try """
        theme = GitHub-Dark-Personal
        foreground = #E6EDF3
        background-opacity = 0.90
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: [themeDirectoryURL])

        let resolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(resolution.theme.background.themeHexString, "#0A0C10")
        XCTAssertEqual(resolution.theme.foreground.themeHexString, "#E6EDF3")
        XCTAssertEqual(resolution.theme.cursorColor.themeHexString, "#71B7FF")
        XCTAssertEqual(resolution.theme.backgroundOpacity, 0.90)
        XCTAssertEqual(Set(resolution.watchedURLs), Set([configURL, themeDirectoryURL.appendingPathComponent("GitHub-Dark-Personal")]))
    }

    func test_resolve_picks_light_or_dark_theme_from_pair() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)

        try """
        background = #FFFFFF
        foreground = #0A0C10
        """.write(to: themeDirectoryURL.appendingPathComponent("Light"), atomically: true, encoding: .utf8)

        try """
        background = #0A0C10
        foreground = #F0F3F6
        """.write(to: themeDirectoryURL.appendingPathComponent("Dark"), atomically: true, encoding: .utf8)

        try """
        theme = light:Light,dark:Dark
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: [themeDirectoryURL])

        let darkResolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(darkResolution.theme.background.themeHexString, "#0A0C10")

        let lightResolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .aqua)))
        XCTAssertEqual(lightResolution.theme.background.themeHexString, "#FFFFFF")
    }

    func test_derived_theme_keeps_sidebar_and_canvas_distinct_from_terminal_surface() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertNotEqual(theme.windowBackground.themeToken, theme.sidebarBackground.themeToken)
        XCTAssertNotEqual(theme.canvasBackground.themeToken, theme.startupSurface.themeToken)
        XCTAssertNotEqual(theme.windowBackground.themeToken, theme.canvasBackground.themeToken)
        XCTAssertEqual(theme.topChromeBackground.themeToken, theme.canvasBackground.themeToken)
    }

    func test_derived_theme_creates_distinct_shell_material_from_window_background() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertNotEqual(theme.windowBackground.themeToken, theme.sidebarBackground.themeToken)
    }

    func test_derived_theme_keeps_sidebar_darker_than_stitched_content_shell_for_dark_themes() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertLessThan(theme.sidebarBackground.perceivedLuminance, theme.canvasBackground.perceivedLuminance)
        XCTAssertNotEqual(theme.sidebarBackground.themeToken, theme.canvasBackground.themeToken)
    }

    func test_dark_theme_sidebar_uses_translucent_glass_fill_instead_of_opaque_slab() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertLessThan(theme.sidebarBackground.srgbClamped.alphaComponent, 0.5)
    }

    func test_dark_theme_sidebar_rows_stay_translucent_enough_to_reveal_underlap_motion() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertLessThan(theme.sidebarButtonActiveBackground.srgbClamped.alphaComponent, 0.7)
        XCTAssertLessThan(theme.sidebarButtonInactiveBackground.srgbClamped.alphaComponent, 0.2)
    }
}
