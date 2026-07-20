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

    func test_app_privacy_configuration_declares_microphone_access_for_terminal_voice_input() throws {
        let repoRoot = repoRootURL()
        let entitlements = try propertyListDictionary(
            at: repoRoot.appendingPathComponent("Zentty/Zentty.entitlements")
        )
        let infoPlist = try propertyListDictionary(
            at: repoRoot.appendingPathComponent("Zentty/Info.plist")
        )

        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
        XCTAssertEqual(
            infoPlist["NSMicrophoneUsageDescription"] as? String,
            "A program running within Zentty would like to use your microphone."
        )
    }

    func test_bundled_zero_config_defaults_reference_default_theme_without_inline_colors() throws {
        let defaultsURL = repoRootURL().appendingPathComponent("ZenttyResources/ghostty/zentty-defaults.ghostty")
        let defaults = try String(contentsOf: defaultsURL, encoding: .utf8)

        XCTAssertTrue(defaults.contains("theme = \(GhosttyThemeLibrary.fallbackPersistedThemeName)"))

        for line in defaults.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else {
                continue
            }
            let key = trimmed.split(separator: "=", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? trimmed

            XCTAssertNotEqual(key, "background", "defaults must not inline an explicit background color")
            XCTAssertNotEqual(key, "foreground", "defaults must not inline an explicit foreground color")
            XCTAssertNotEqual(key, "cursor-color", "defaults must not inline an explicit cursor color")
            XCTAssertFalse(key.hasPrefix("selection-"), "defaults must not inline explicit selection colors")
            XCTAssertFalse(key.hasPrefix("palette"), "defaults must not inline an explicit palette")
        }

        XCTAssertTrue(defaults.contains("background-opacity = 0.95"))
        XCTAssertTrue(defaults.contains("font-feature = -calt"))
        XCTAssertTrue(defaults.contains("font-feature = -liga"))
        XCTAssertTrue(defaults.contains("font-feature = -dlig"))
        XCTAssertTrue(defaults.contains("window-padding-x = 10"))
        XCTAssertTrue(defaults.contains("window-padding-y = 10"))
        XCTAssertTrue(defaults.contains("window-padding-balance = false"))
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

    func test_default_theme_file_matches_built_in_resolved_theme_palette() throws {
        let themeURL = repoRootURL()
            .appendingPathComponent("ZenttyResources/ghostty/themes")
            .appendingPathComponent(GhosttyThemeLibrary.fallbackPersistedThemeName)
        let contents = try String(contentsOf: themeURL, encoding: .utf8)

        var background: NSColor?
        var foreground: NSColor?
        var cursorColor: NSColor?
        var selectionBackground: NSColor?
        var selectionForeground: NSColor?
        var palette: [Int: NSColor] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1]

            switch key {
            case "background":
                background = NSColor(hexString: value)
            case "foreground":
                foreground = NSColor(hexString: value)
            case "cursor-color":
                cursorColor = NSColor(hexString: value)
            case "selection-background":
                selectionBackground = NSColor(hexString: value)
            case "selection-foreground":
                selectionForeground = NSColor(hexString: value)
            case "palette":
                let paletteParts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard paletteParts.count == 2, let index = Int(paletteParts[0]) else { continue }
                palette[index] = NSColor(hexString: paletteParts[1])
            default:
                continue
            }
        }

        let expected = try XCTUnwrap(
            GhosttyThemeLibrary.builtInResolvedTheme(named: GhosttyThemeLibrary.fallbackThemeName)
        )

        XCTAssertEqual(background?.themeHexString, expected.background.themeHexString)
        XCTAssertEqual(foreground?.themeHexString, expected.foreground.themeHexString)
        XCTAssertEqual(cursorColor?.themeHexString, expected.cursorColor.themeHexString)
        XCTAssertEqual(selectionBackground?.themeHexString, expected.selectionBackground?.themeHexString)
        XCTAssertEqual(selectionForeground?.themeHexString, expected.selectionForeground?.themeHexString)
        XCTAssertEqual(palette.count, expected.palette.count)
        for (index, expectedColor) in expected.palette {
            XCTAssertEqual(palette[index]?.themeHexString, expectedColor.themeHexString, "palette index \(index) mismatch")
        }
    }

    func test_sync_ghostty_themes_script_excludes_custom_default_theme_from_upstream_sync() throws {
        let scriptURL = repoRootURL().appendingPathComponent("scripts/sync_ghostty_themes.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("--exclude 'GitHub-Dark-Personal'"))
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

    private func propertyListDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(propertyList as? [String: Any])
    }
}
