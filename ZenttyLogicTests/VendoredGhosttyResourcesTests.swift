import Foundation
import XCTest
@testable import Zentty

final class VendoredGhosttyResourcesTests: XCTestCase {
    func test_vendored_ghostty_terminfo_entries_are_present() {
        let repoRoot = repoRootURL()
        let terminfoRoot = repoRoot.appendingPathComponent("ZenttyResources/terminfo", isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: terminfoRoot.appendingPathComponent("67/ghostty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminfoRoot.appendingPathComponent("78/xterm-ghostty").path))
    }

    func test_vendored_ghostty_theme_tree_is_present_and_populated() throws {
        let themesDirectory = repoRootURL()
            .appendingPathComponent("ZenttyResources/ghostty/themes", isDirectory: true)

        let themeNames = try FileManager.default.contentsOfDirectory(
            atPath: themesDirectory.path
        )

        XCTAssertGreaterThan(themeNames.count, 100)
    }

    func test_third_party_catalog_includes_iterm2_color_schemes_license() throws {
        let catalogURL = repoRootURL().appendingPathComponent("ZenttyResources/ThirdPartyLicenses.json")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(ThirdPartyLicenseCatalog.self, from: catalogData)
        let entry = try XCTUnwrap(catalog.entries.first { $0.id == "iterm2-color-schemes" })

        XCTAssertEqual(entry.displayName, "iTerm2 Color Schemes")
        XCTAssertEqual(entry.licenseName, "MIT License")
        XCTAssertEqual(entry.spdxID, "MIT")
        XCTAssertEqual(
            entry.sourceURLString,
            "https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/LICENSE"
        )
        XCTAssertEqual(entry.homepageURLString, "https://github.com/mbadolato/iTerm2-Color-Schemes")
        XCTAssertTrue(entry.fullText.contains("Copyright (c) 2011 to Present Mark Badolato"))
    }

    func test_project_configuration_does_not_reference_ghostty_theme_cache() throws {
        let projectYAML = try String(
            contentsOf: repoRootURL().appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertFalse(projectYAML.contains("Library/Caches/zentty/ghostty-src"))
        XCTAssertFalse(projectYAML.contains("GHOSTTY_THEME_CACHE_SRC"))
        XCTAssertFalse(projectYAML.contains("rm -rf \"${RESOURCES_DST}/ghostty/themes\""))
    }

    func test_project_configuration_copies_vendored_terminfo_into_app_resources() throws {
        let projectYAML = try String(
            contentsOf: repoRootURL().appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(projectYAML.contains("mkdir -p \"${RESOURCES_DST}/bin\""))
        XCTAssertTrue(projectYAML.contains("\"${RESOURCES_DST}/terminfo\""))
        XCTAssertTrue(projectYAML.contains("rsync -a --delete \"${RESOURCES_SRC}/terminfo/\" \"${RESOURCES_DST}/terminfo/\""))
    }

    func test_bundled_zero_config_defaults_inline_zentty_default_theme_palette_and_visual_defaults() throws {
        let defaultsURL = repoRootURL().appendingPathComponent("ZenttyResources/ghostty/zentty-defaults.ghostty")
        let defaults = try String(contentsOf: defaultsURL, encoding: .utf8)

        XCTAssertFalse(defaults.contains("theme = \(GhosttyThemeLibrary.fallbackPersistedThemeName)"))
        XCTAssertTrue(defaults.contains("background = #0A0C10"))
        XCTAssertTrue(defaults.contains("foreground = #F0F3F6"))
        XCTAssertTrue(defaults.contains("cursor-color = #71B7FF"))
        XCTAssertTrue(defaults.contains("selection-background = #F0F3F6"))
        XCTAssertTrue(defaults.contains("selection-foreground = #0A0C10"))
        XCTAssertTrue(defaults.contains("palette = 0=#7A828E"))
        XCTAssertTrue(defaults.contains("palette = 15=#FFFFFF"))
        XCTAssertTrue(defaults.contains("background-opacity = 0.95"))
        XCTAssertTrue(defaults.contains("font-feature = -calt"))
        XCTAssertTrue(defaults.contains("font-feature = -liga"))
        XCTAssertTrue(defaults.contains("font-feature = -dlig"))
        XCTAssertTrue(defaults.contains("window-padding-x = 10"))
        XCTAssertTrue(defaults.contains("window-padding-y = 10"))
        XCTAssertTrue(defaults.contains("cursor-style = block"))
        XCTAssertTrue(defaults.contains("cursor-style-blink = true"))
        XCTAssertTrue(defaults.contains("cursor-opacity = 0.8"))
        XCTAssertTrue(defaults.contains("mouse-hide-while-typing = true"))
        XCTAssertTrue(defaults.contains("copy-on-select = clipboard"))
        XCTAssertTrue(defaults.contains("clipboard-paste-protection = false"))
        XCTAssertTrue(defaults.contains("clipboard-paste-bracketed-safe = true"))
        XCTAssertFalse(defaults.contains("background-blur-radius = 25"))
        XCTAssertFalse(defaults.contains("quick-terminal-position"))
    }

    @MainActor
    func test_theme_catalog_includes_built_in_default_when_loading_vendored_library() throws {
        let themeDirectory = repoRootURL()
            .appendingPathComponent("ZenttyResources/ghostty/themes", isDirectory: true)

        let themes = ThemeCatalogService(themeDirectories: [themeDirectory]).loadThemesSynchronouslyForTesting()

        XCTAssertGreaterThan(themes.count, 100)
        let fallback = try XCTUnwrap(themes.first { $0.name == "Zentty-Default" })
        XCTAssertEqual(fallback.displayName, "Zentty Default Theme")
        XCTAssertEqual(fallback.background.themeHexString, "#0A0C10")
        XCTAssertEqual(fallback.foreground.themeHexString, "#F0F3F6")
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
