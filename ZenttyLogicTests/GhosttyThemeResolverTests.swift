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

    func test_themeSpec_formatter_uses_pair_for_follow_macos() throws {
        let spec = GhosttyThemeSpec(
            mode: .followMacOS,
            darkThemeName: "Catppuccin Frappe",
            lightThemeName: "Catppuccin Latte"
        )

        XCTAssertEqual(spec.rawValue, "dark:Catppuccin Frappe,light:Catppuccin Latte")
        XCTAssertEqual(spec.themeName(for: NSAppearance(named: .darkAqua)), "Catppuccin Frappe")
        XCTAssertEqual(spec.themeName(for: NSAppearance(named: .aqua)), "Catppuccin Latte")
    }

    func test_themeSpec_formatter_uses_selected_slot_for_always_modes() throws {
        let darkSpec = GhosttyThemeSpec(
            mode: .alwaysDark,
            darkThemeName: "TokyoNight",
            lightThemeName: "GitHub Light Default"
        )
        let lightSpec = GhosttyThemeSpec(
            mode: .alwaysLight,
            darkThemeName: "TokyoNight",
            lightThemeName: "GitHub Light Default"
        )

        XCTAssertEqual(darkSpec.rawValue, "TokyoNight")
        XCTAssertEqual(darkSpec.themeName(for: NSAppearance(named: .aqua)), "TokyoNight")
        XCTAssertEqual(lightSpec.rawValue, "GitHub Light Default")
        XCTAssertEqual(lightSpec.themeName(for: NSAppearance(named: .darkAqua)), "GitHub Light Default")
    }

    func test_themeSpec_parser_reads_pair_from_ghostty_theme_spec() throws {
        let spec = try XCTUnwrap(GhosttyThemeSpec(rawValue: "light:Catppuccin Latte,dark:Catppuccin Frappe"))

        XCTAssertEqual(spec.mode, .followMacOS)
        XCTAssertEqual(spec.darkThemeName, "Catppuccin Frappe")
        XCTAssertEqual(spec.lightThemeName, "Catppuccin Latte")
    }

    func test_themeSpec_parser_reads_single_theme_as_always_dark_preference() throws {
        let spec = try XCTUnwrap(GhosttyThemeSpec(rawValue: "TokyoNight"))

        XCTAssertEqual(spec.mode, .alwaysDark)
        XCTAssertEqual(spec.darkThemeName, "TokyoNight")
        XCTAssertNil(spec.lightThemeName)
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

    func test_derived_theme_uses_mostly_opaque_dark_zoom_pane_fills() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.5,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false
        )

        XCTAssertEqual(theme.paneZoomFillUnfocused.srgbClamped.alphaComponent, 0.92, accuracy: 0.001)
        XCTAssertEqual(theme.paneZoomFillFocused.srgbClamped.alphaComponent, 0.92, accuracy: 0.001)
        XCTAssertEqual(theme.paneZoomFillFocused.themeToken, theme.paneZoomFillUnfocused.themeToken)
        XCTAssertLessThan(
            theme.paneZoomFillUnfocused.perceivedLuminance,
            theme.windowBackground.withAlphaComponent(1).perceivedLuminance
        )
    }

    func test_derived_theme_uses_mostly_opaque_light_zoom_pane_fills() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F7F4EC")!,
                foreground: NSColor(hexString: "#1E2428")!,
                cursorColor: NSColor(hexString: "#006DAD")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.5,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false
        )

        XCTAssertEqual(theme.paneZoomFillUnfocused.srgbClamped.alphaComponent, 0.95, accuracy: 0.001)
        XCTAssertEqual(theme.paneZoomFillFocused.srgbClamped.alphaComponent, 0.95, accuracy: 0.001)
        XCTAssertEqual(theme.paneZoomFillFocused.themeToken, theme.paneZoomFillUnfocused.themeToken)
        XCTAssertGreaterThan(
            theme.paneZoomFillUnfocused.perceivedLuminance,
            theme.windowBackground.withAlphaComponent(1).perceivedLuminance
        )
    }

    func test_derived_theme_makes_zoom_pane_fills_opaque_when_reducing_transparency() {
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.4,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: true
        )

        XCTAssertEqual(theme.paneZoomFillUnfocused.srgbClamped.alphaComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(theme.paneZoomFillFocused.srgbClamped.alphaComponent, 1.0, accuracy: 0.001)
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

    // MARK: - Sidebar selection emphasis (issue #51)

    private func sidebarTheme(
        background: String,
        foreground: String,
        cursor: String,
        emphasis: AppConfig.Appearance.SidebarSelectionEmphasis,
        palette: [Int: NSColor] = [:],
        reduceTransparency: Bool = false
    ) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: background)!,
                foreground: NSColor(hexString: foreground)!,
                cursorColor: NSColor(hexString: cursor)!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: palette,
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: reduceTransparency,
            sidebarSelectionEmphasis: emphasis
        )
    }

    /// Composited contrast between the selected and idle rows, as they actually
    /// render (each fill flattened over the sidebar surface over the window).
    private func selectionVsIdleContrast(_ theme: ZenttyTheme, background: String) -> CGFloat {
        let bg = NSColor(hexString: background)!.srgbClamped
        let surface = theme.sidebarBackground.composited(over: bg)
        let active = theme.sidebarButtonActiveBackground.composited(over: surface)
        let idle = theme.sidebarButtonInactiveBackground.composited(over: surface)
        return active.contrastRatio(against: idle)
    }

    private func activeTextVsFillContrast(_ theme: ZenttyTheme, background: String) -> CGFloat {
        let bg = NSColor(hexString: background)!.srgbClamped
        let surface = theme.sidebarBackground.composited(over: bg)
        let fill = theme.sidebarButtonActiveBackground.composited(over: surface)
        return theme.sidebarButtonActiveText.contrastRatio(against: fill)
    }

    func test_subtle_emphasis_healthy_dark_theme_matches_shipped_selection_derivation() {
        // Byte-for-byte regression guard: the safety floor must be a no-op in
        // subtle mode on a normal dark theme (values captured from the shipped
        // derivation, reduceTransparency = false).
        let theme = sidebarTheme(
            background: "#0A0C10", foreground: "#F0F3F6", cursor: "#71B7FF",
            emphasis: .subtle
        )

        XCTAssertEqual(theme.sidebarButtonActiveBackground.themeToken, "#111316-620")
        XCTAssertEqual(theme.sidebarButtonActiveBorder.themeToken, "#71B7FF-120")
        XCTAssertEqual(theme.sidebarButtonActiveText.themeToken, "#F0F3F6-980")
    }

    func test_vivid_emphasis_dark_theme_pushes_selection_far_above_subtle_contrast() {
        let subtle = sidebarTheme(
            background: "#0A0C10", foreground: "#F0F3F6", cursor: "#71B7FF", emphasis: .subtle
        )
        let vivid = sidebarTheme(
            background: "#0A0C10", foreground: "#F0F3F6", cursor: "#71B7FF", emphasis: .vivid
        )

        let subtleContrast = selectionVsIdleContrast(subtle, background: "#0A0C10")
        let vividContrast = selectionVsIdleContrast(vivid, background: "#0A0C10")

        // Subtle stays low (that is the #51 pain point); vivid is unmistakable.
        XCTAssertLessThan(subtleContrast, 1.4)
        XCTAssertGreaterThanOrEqual(vividContrast, 1.8)
        XCTAssertGreaterThan(vividContrast, subtleContrast)

        // The vivid fill reads as accent-tinted, not the near-black recessed fill.
        let accent = NSColor(hexString: "#71B7FF")!
        XCTAssertLessThan(
            colorDistance(vivid.sidebarButtonActiveBackground, accent),
            colorDistance(subtle.sidebarButtonActiveBackground, accent)
        )

        // Border matches the focused-pane treatment (accent at 0.42 on dark).
        XCTAssertEqual(vivid.sidebarButtonActiveBorder.srgbClamped.alphaComponent, 0.42, accuracy: 0.001)
        XCTAssertEqual(
            vivid.sidebarButtonActiveBorder.srgbClamped.alphaComponent,
            vivid.paneBorderFocused.srgbClamped.alphaComponent,
            accuracy: 0.001
        )

        // Selected label stays legible on the stronger fill.
        XCTAssertGreaterThanOrEqual(activeTextVsFillContrast(vivid, background: "#0A0C10"), 4.5)
    }

    func test_vivid_emphasis_light_theme_selection_is_legible_and_accent_bordered() {
        let vivid = sidebarTheme(
            background: "#F7FBFF", foreground: "#102030", cursor: "#2F74D0", emphasis: .vivid
        )

        XCTAssertGreaterThanOrEqual(selectionVsIdleContrast(vivid, background: "#F7FBFF"), 1.8)
        XCTAssertGreaterThanOrEqual(activeTextVsFillContrast(vivid, background: "#F7FBFF"), 4.5)
        // Focused-pane treatment on light is accent at 0.34.
        XCTAssertEqual(vivid.sidebarButtonActiveBorder.srgbClamped.alphaComponent, 0.34, accuracy: 0.001)
        XCTAssertEqual(
            vivid.sidebarButtonActiveBorder.srgbClamped.alphaComponent,
            vivid.paneBorderFocused.srgbClamped.alphaComponent,
            accuracy: 0.001
        )
    }

    func test_vivid_emphasis_survives_degenerate_accent_matching_background() {
        // Cursor color == background: the raw accent would vanish into the
        // sidebar. The guarded fallback (palette blue) keeps the selection visible.
        let vivid = sidebarTheme(
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#1A1B26",
            emphasis: .vivid,
            palette: [12: NSColor(hexString: "#7AA2F7")!]
        )

        XCTAssertGreaterThanOrEqual(selectionVsIdleContrast(vivid, background: "#1A1B26"), 1.8)
        XCTAssertGreaterThanOrEqual(activeTextVsFillContrast(vivid, background: "#1A1B26"), 4.5)
        XCTAssertNotEqual(
            vivid.sidebarButtonActiveBackground.themeToken,
            vivid.sidebarBackground.themeToken
        )
    }

    func test_vivid_emphasis_survives_accent_and_palette_matching_background() {
        // Even when both cursor and the palette blue collapse into the background,
        // the foreground fallback keeps a visible, legible selection.
        let vivid = sidebarTheme(
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#1A1B26",
            emphasis: .vivid,
            palette: [12: NSColor(hexString: "#1B1C27")!]
        )

        XCTAssertGreaterThanOrEqual(selectionVsIdleContrast(vivid, background: "#1A1B26"), 1.6)
        XCTAssertGreaterThanOrEqual(activeTextVsFillContrast(vivid, background: "#1A1B26"), 4.5)
    }

    private func selectionVsIdleSeparation(_ theme: ZenttyTheme, background: String) -> CGFloat {
        let bg = NSColor(hexString: background)!.srgbClamped
        let surface = theme.sidebarBackground.composited(over: bg)
        let active = theme.sidebarButtonActiveBackground.composited(over: surface)
        let idle = theme.sidebarButtonInactiveBackground.composited(over: surface)
        return active.srgbDistance(to: idle)
    }

    func test_subtle_guard_is_noop_on_healthy_light_theme() {
        // Healthy light theme: separation is well above the guard threshold, so the
        // fill is untouched and the border stays at the whisper base alpha (0.10).
        let theme = sidebarTheme(
            background: "#F7FBFF", foreground: "#102030", cursor: "#2F74D0", emphasis: .subtle
        )

        XCTAssertGreaterThanOrEqual(selectionVsIdleSeparation(theme, background: "#F7FBFF"), 0.012)
        XCTAssertEqual(theme.sidebarButtonActiveBorder.srgbClamped.alphaComponent, 0.10, accuracy: 0.001)
    }

    func test_subtle_guard_rescues_collapsed_dark_theme_by_widening_fill() {
        // Low-contrast dark theme whose selected/idle fills collapse (~0.011 apart).
        // Remedy A widens the fill along the darker axis; the border stays base.
        let collapsed = sidebarTheme(
            background: "#2A2A2A", foreground: "#323232", cursor: "#343434", emphasis: .subtle
        )

        XCTAssertGreaterThanOrEqual(selectionVsIdleSeparation(collapsed, background: "#2A2A2A"), 0.012)
        // Fill headroom was enough, so the border is not escalated.
        XCTAssertEqual(collapsed.sidebarButtonActiveBorder.srgbClamped.alphaComponent, 0.12, accuracy: 0.001)
        // Selected stays the darkest row (ordering preserved by construction).
        XCTAssertLessThan(
            collapsed.sidebarButtonActiveBackground.perceivedLuminance,
            collapsed.sidebarButtonInactiveBackground.perceivedLuminance
        )
    }

    func test_subtle_guard_escalates_border_when_fill_has_no_headroom() {
        // Pure-black theme: darkening the fill cannot create separation, so remedy B
        // raises the accent border alpha toward the focused-pane level (0.42).
        let collapsed = sidebarTheme(
            background: "#000000", foreground: "#050505", cursor: "#000000", emphasis: .subtle
        )

        let borderAlpha = collapsed.sidebarButtonActiveBorder.srgbClamped.alphaComponent
        XCTAssertGreaterThanOrEqual(borderAlpha, 0.30)
        XCTAssertLessThanOrEqual(borderAlpha, 0.42)
    }

    func test_subtle_guard_escalated_border_stays_visible_when_accent_matches_background() {
        // Same no-headroom theme as the escalation test, but with a black cursor
        // color and a real palette blue: the escalated rescue border must not
        // inherit the invisible raw accent — it should fall back through the
        // guarded-accent chain (landing on palette blue) so the outline is visible.
        let collapsed = sidebarTheme(
            background: "#000000", foreground: "#050505", cursor: "#000000", emphasis: .subtle,
            palette: [4: NSColor(hexString: "#4A8FD4")!, 12: NSColor(hexString: "#71B7FF")!]
        )

        let border = collapsed.sidebarButtonActiveBorder.srgbClamped
        XCTAssertGreaterThanOrEqual(border.alphaComponent, 0.30)
        let sidebarSurface = collapsed.sidebarBackground.composited(over: collapsed.windowBackground)
        let opaqueBorder = border.withAlphaComponent(1)
        XCTAssertGreaterThanOrEqual(
            opaqueBorder.contrastRatio(against: sidebarSurface), 1.2,
            "Escalated subtle rescue border must remain visible against the sidebar surface"
        )
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
