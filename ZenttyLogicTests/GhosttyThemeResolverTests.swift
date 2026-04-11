import AppKit
import XCTest
@testable import Zentty

final class GhosttyThemeResolverTests: AppKitTestCase {
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
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)

        try """
        background = #0A0C10
        foreground = #F0F3F6
        cursor-color = #71B7FF
        """.write(
            to: themeDirectoryURL.appendingPathComponent(persistedFallbackThemeName),
            atomically: true,
            encoding: .utf8
        )

        try """
        theme = \(persistedFallbackThemeName)
        foreground = #E6EDF3
        background-opacity = 0.90
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: [themeDirectoryURL])

        let resolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(resolution.theme.background.themeHexString, "#0A0C10")
        XCTAssertEqual(resolution.theme.foreground.themeHexString, "#E6EDF3")
        XCTAssertEqual(resolution.theme.cursorColor.themeHexString, "#71B7FF")
        XCTAssertEqual(resolution.theme.backgroundOpacity, 0.90)
        XCTAssertEqual(
            Set(resolution.watchedURLs),
            Set([configURL, themeDirectoryURL.appendingPathComponent(persistedFallbackThemeName)])
        )
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

    func test_resolve_uses_bundled_defaults_and_local_app_overrides_when_shared_config_missing() throws {
        let bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty")
        let themeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)

        try """
        background = #111111
        foreground = #EEEEEE
        """.write(to: themeDirectoryURL.appendingPathComponent("BundledTheme"), atomically: true, encoding: .utf8)

        try """
        background = #222222
        foreground = #DDDDDD
        """.write(to: themeDirectoryURL.appendingPathComponent("LocalTheme"), atomically: true, encoding: .utf8)

        try """
        theme = BundledTheme
        background-opacity = 0.84
        """.write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)

        var appConfig = AppConfig.default
        appConfig.appearance.localThemeName = "LocalTheme"
        appConfig.appearance.localBackgroundOpacity = 0.65

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: temporaryDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { appConfig }
        )
        let resolver = GhosttyThemeResolver(
            configEnvironment: environment,
            additionalThemeDirectories: [themeDirectoryURL]
        )

        let resolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(resolution.theme.background.themeHexString, "#222222")
        XCTAssertEqual(resolution.theme.foreground.themeHexString, "#DDDDDD")
        XCTAssertEqual(resolution.theme.backgroundOpacity, 0.65)
        XCTAssertEqual(
            Set(resolution.watchedURLs),
            Set([bundledDefaultsURL, themeDirectoryURL.appendingPathComponent("LocalTheme")])
        )
    }

    func test_resolve_prefers_ghostty_app_resources_over_bundled_resources() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let appThemeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("ghostty-app/themes", isDirectory: true)
        let bundledThemeDirectoryURL = temporaryDirectoryURL.appendingPathComponent("bundled/themes", isDirectory: true)
        try FileManager.default.createDirectory(at: appThemeDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledThemeDirectoryURL, withIntermediateDirectories: true)

        try """
        background = #111111
        foreground = #EEEEEE
        """.write(to: bundledThemeDirectoryURL.appendingPathComponent("SharedTheme"), atomically: true, encoding: .utf8)

        try """
        background = #222222
        foreground = #DDDDDD
        """.write(to: appThemeDirectoryURL.appendingPathComponent("SharedTheme"), atomically: true, encoding: .utf8)

        try """
        theme = SharedTheme
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = GhosttyThemeResolver(
            configURL: configURL,
            additionalThemeDirectories: [appThemeDirectoryURL, bundledThemeDirectoryURL]
        )

        let resolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(resolution.theme.background.themeHexString, "#222222")
        XCTAssertEqual(resolution.theme.foreground.themeHexString, "#DDDDDD")
        XCTAssertEqual(
            Set(resolution.watchedURLs),
            Set([configURL, appThemeDirectoryURL.appendingPathComponent("SharedTheme")])
        )
    }

    func test_resolve_uses_built_in_fallback_theme_when_defaults_reference_the_persisted_alias_without_theme_file() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let bundledDefaultsURL = temporaryDirectoryURL.appendingPathComponent("zentty-defaults.ghostty")
        try """
        theme = \(persistedFallbackThemeName)
        background-opacity = 0.80
        """.write(to: bundledDefaultsURL, atomically: true, encoding: .utf8)

        let environment = GhosttyConfigEnvironment(
            homeDirectoryURL: temporaryDirectoryURL,
            bundledDefaultsURL: bundledDefaultsURL,
            appConfigProvider: { AppConfig.default }
        )
        let resolver = GhosttyThemeResolver(
            configEnvironment: environment,
            additionalThemeDirectories: []
        )

        let resolution = try XCTUnwrap(resolver.resolve(for: NSAppearance(named: .darkAqua)))
        XCTAssertEqual(resolution.theme.background.themeHexString, "#0A0C10")
        XCTAssertEqual(resolution.theme.foreground.themeHexString, "#F0F3F6")
        XCTAssertEqual(resolution.theme.cursorColor.themeHexString, "#71B7FF")
        XCTAssertEqual(resolution.theme.selectionBackground?.themeHexString, "#F0F3F6")
        XCTAssertEqual(resolution.theme.selectionForeground?.themeHexString, "#0A0C10")
        XCTAssertEqual(resolution.theme.palette[0]?.themeHexString, "#7A828E")
        XCTAssertEqual(resolution.theme.palette[12]?.themeHexString, "#91CBFF")
        XCTAssertEqual(resolution.theme.backgroundOpacity, 0.80)
        XCTAssertEqual(Set(resolution.watchedURLs), Set([bundledDefaultsURL]))
    }

    func test_currentThemeName_canonicalizes_built_in_default_alias() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try """
        theme = \(persistedFallbackThemeName)
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: [])

        XCTAssertEqual(
            resolver.currentThemeName(for: NSAppearance(named: .darkAqua)),
            "Zentty-Default"
        )
    }

    func test_derived_theme_stitches_main_shell_to_terminal_surface_when_opaque() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 1.0,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertNotEqual(theme.windowBackground.themeToken, theme.sidebarBackground.themeToken)
        XCTAssertEqual(theme.canvasBackground.themeToken, theme.startupSurface.themeToken)
        XCTAssertEqual(theme.windowBackground.themeToken, theme.canvasBackground.themeToken)
        XCTAssertEqual(theme.topChromeBackground.themeToken, theme.canvasBackground.themeToken)
    }

    func test_derived_theme_clears_chrome_layers_when_translucent() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.8,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertLessThan(theme.windowBackground.srgbClamped.alphaComponent, 1.0)
        XCTAssertEqual(theme.canvasBackground, .clear)
        XCTAssertEqual(theme.topChromeBackground, .clear)
        XCTAssertLessThan(theme.startupSurface.srgbClamped.alphaComponent, 1.0)
    }

    func test_derived_theme_keeps_sidebar_distinct_from_main_window_background() {
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

    func test_derived_theme_keeps_sidebar_visibly_distinct_from_stitched_content_shell_for_dark_themes() {
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

        XCTAssertGreaterThan(theme.sidebarBackground.perceivedLuminance, theme.canvasBackground.perceivedLuminance)
        XCTAssertNotEqual(theme.sidebarBackground.themeToken, theme.canvasBackground.themeToken)
    }

    func test_dark_theme_sidebar_uses_translucent_glass_fill_when_opacity_is_low() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.3,
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

    func test_dark_theme_sidebar_row_palette_orders_selected_hover_and_idle_luminance() {
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

        XCTAssertLessThan(
            theme.sidebarButtonActiveBackground.perceivedLuminance,
            theme.sidebarButtonHoverBackground.perceivedLuminance
        )
        XCTAssertLessThan(
            theme.sidebarButtonHoverBackground.perceivedLuminance,
            theme.sidebarButtonInactiveBackground.perceivedLuminance
        )
        XCTAssertGreaterThan(
            theme.sidebarButtonHoverBackground.srgbClamped.alphaComponent,
            theme.sidebarButtonInactiveBackground.srgbClamped.alphaComponent
        )
    }

    func test_dark_theme_sidebar_selected_border_keeps_accent_tint_while_idle_border_stays_neutral() {
        let accent = NSColor(hexString: "#71B7FF")!
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: accent,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        let selectedDistance = colorDistance(theme.sidebarButtonActiveBorder, accent)
        let idleDistance = colorDistance(theme.sidebarButtonInactiveBorder, accent)

        XCTAssertLessThan(selectedDistance, idleDistance)
        XCTAssertLessThan(theme.sidebarButtonActiveBorder.srgbClamped.alphaComponent, 0.16)
        XCTAssertNotEqual(theme.sidebarBackground.themeToken, theme.sidebarButtonActiveBackground.themeToken)
        XCTAssertNotEqual(theme.sidebarGradientStart.themeToken, theme.sidebarButtonActiveBackground.themeToken)
        XCTAssertNotEqual(theme.sidebarGradientEnd.themeToken, theme.sidebarButtonActiveBackground.themeToken)
    }

    func test_dark_theme_open_with_chrome_stays_softer_than_context_strip() {
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

        XCTAssertGreaterThan(
            colorDistance(theme.openWithChromeBackground, theme.windowBackground),
            0
        )
        XCTAssertLessThan(
            colorDistance(theme.openWithChromeBackground, theme.windowBackground),
            colorDistance(theme.contextStripBackground, theme.windowBackground)
        )
        XCTAssertLessThan(
            theme.openWithChromeDivider.srgbClamped.alphaComponent,
            theme.contextStripBorder.srgbClamped.alphaComponent
        )
    }

    func test_light_theme_open_with_popover_selected_row_stays_more_emphasized_than_hover_row() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F7FBFF")!,
                foreground: NSColor(hexString: "#102030")!,
                cursorColor: NSColor(hexString: "#2F74D0")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.94,
                backgroundBlurRadius: 18
            )
        )

        XCTAssertNotEqual(theme.openWithPopoverBackground.themeToken, theme.sidebarBackground.themeToken)
        XCTAssertGreaterThan(
            theme.openWithPopoverRowSelectedBackground.srgbClamped.alphaComponent,
            theme.openWithPopoverRowHoverBackground.srgbClamped.alphaComponent
        )
    }

    func test_dark_theme_working_text_highlight_stays_closer_to_text_than_sidebar_surface() {
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

        XCTAssertLessThan(
            colorDistance(theme.sidebarWorkingTextHighlight, theme.primaryText),
            colorDistance(theme.sidebarGradientStart, theme.primaryText)
        )
    }

    func test_light_theme_working_text_highlight_stays_lighter_and_closer_to_text_than_sidebar_surface() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F7FBFF")!,
                foreground: NSColor(hexString: "#102030")!,
                cursorColor: NSColor(hexString: "#2F74D0")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.94,
                backgroundBlurRadius: 18
            )
        )

        XCTAssertGreaterThan(
            theme.sidebarWorkingTextHighlight.perceivedLuminance,
            theme.primaryText.perceivedLuminance
        )
    }

    func test_dark_background_with_dark_foreground_inverts_text_palette_to_light_readable_text() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#101418")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        XCTAssertGreaterThan(theme.primaryText.contrastRatio(against: theme.windowBackground), 7)
        XCTAssertGreaterThan(theme.sidebarButtonInactiveText.contrastRatio(against: theme.sidebarBackground), 4.5)
        XCTAssertGreaterThan(theme.primaryText.perceivedLuminance, theme.windowBackground.perceivedLuminance)
        XCTAssertGreaterThan(theme.sidebarButtonInactiveText.perceivedLuminance, theme.sidebarBackground.perceivedLuminance)
    }

    func test_derived_theme_prefers_dark_sidebar_glass_for_dark_terminal_backgrounds() {
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

        XCTAssertEqual(theme.sidebarGlassAppearance, .dark)
    }

    func test_derived_theme_prefers_light_sidebar_glass_for_light_terminal_backgrounds() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F7FBFF")!,
                foreground: NSColor(hexString: "#102030")!,
                cursorColor: NSColor(hexString: "#2F74D0")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.94,
                backgroundBlurRadius: 18
            )
        )

        XCTAssertEqual(theme.sidebarGlassAppearance, .light)
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.srgbClamped
        let right = rhs.srgbClamped
        let red = left.redComponent - right.redComponent
        let green = left.greenComponent - right.greenComponent
        let blue = left.blueComponent - right.blueComponent
        return sqrt((red * red) + (green * green) + (blue * blue))
    }
}
