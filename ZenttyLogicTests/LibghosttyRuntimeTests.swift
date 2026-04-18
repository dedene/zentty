import XCTest
@testable import Zentty

@MainActor
final class LibghosttyRuntimeTests: XCTestCase {
    func testGhosttyResourcesDirectory_returnsDirectory_whenAdjacentTerminfoSentinelExists() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let ghosttyURL = resourcesURL.appendingPathComponent("ghostty", isDirectory: true)
        let terminfoURL = resourcesURL
            .appendingPathComponent("terminfo/78", isDirectory: true)

        try FileManager.default.createDirectory(at: ghosttyURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfoURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: terminfoURL.appendingPathComponent("xterm-ghostty", isDirectory: false).path,
            contents: Data()
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertEqual(
            LibghosttyRuntime.ghosttyResourcesDirectory(ifTerminfoPresentAt: ghosttyURL),
            ghosttyURL
        )
    }

    func testGhosttyResourcesDirectory_returnsNil_whenAdjacentTerminfoSentinelIsMissing() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ghosttyURL = rootURL
            .appendingPathComponent("Resources/ghostty", isDirectory: true)

        try FileManager.default.createDirectory(at: ghosttyURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertNil(LibghosttyRuntime.ghosttyResourcesDirectory(ifTerminfoPresentAt: ghosttyURL))
    }

    func testBuiltInThemeOverrideContents_inlinesZenttyDefaultPaletteWhenThemeFileIsUnavailable() {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let contents = LibghosttyRuntime.builtInThemeOverrideContents(
            userConfigContents: """
            theme = \(persistedFallbackThemeName)
            background-opacity = 0.95
            """,
            themeDirectories: []
        )

        XCTAssertNotNil(contents)
        XCTAssertFalse(contents?.contains("theme = \(persistedFallbackThemeName)") ?? true)
        XCTAssertTrue(contents?.contains("background = #0A0C10") ?? false)
        XCTAssertTrue(contents?.contains("foreground = #F0F3F6") ?? false)
        XCTAssertTrue(contents?.contains("cursor-color = #71B7FF") ?? false)
        XCTAssertTrue(contents?.contains("selection-background = #F0F3F6") ?? false)
        XCTAssertTrue(contents?.contains("selection-foreground = #0A0C10") ?? false)
        XCTAssertTrue(contents?.contains("palette = 0=#7A828E") ?? false)
        XCTAssertTrue(contents?.contains("palette = 15=#FFFFFF") ?? false)
        XCTAssertTrue(contents?.contains("font-feature = -calt") ?? false)
        XCTAssertTrue(contents?.contains("font-feature = -liga") ?? false)
        XCTAssertTrue(contents?.contains("font-feature = -dlig") ?? false)
        XCTAssertFalse(contents?.contains("window-padding-x") ?? true)
        XCTAssertFalse(contents?.contains("window-padding-y") ?? true)
        XCTAssertTrue(contents?.contains("cursor-style = block") ?? false)
        XCTAssertTrue(contents?.contains("cursor-style-blink = true") ?? false)
        XCTAssertTrue(contents?.contains("cursor-opacity = 0.8") ?? false)
        XCTAssertTrue(contents?.contains("mouse-hide-while-typing = true") ?? false)
        XCTAssertTrue(contents?.contains("copy-on-select = clipboard") ?? false)
        XCTAssertTrue(contents?.contains("clipboard-paste-protection = false") ?? false)
        XCTAssertTrue(contents?.contains("clipboard-paste-bracketed-safe = true") ?? false)
        XCTAssertFalse(contents?.contains("quick-terminal-position") ?? true)
    }

    func testBuiltInThemeOverrideContents_skipsInliningWhenThemeFileExists() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let themeDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)
        try addTeardownBlock {
            try? FileManager.default.removeItem(at: themeDirectoryURL)
        }

        try """
        background = #111111
        foreground = #EEEEEE
        """.write(
            to: themeDirectoryURL.appendingPathComponent(persistedFallbackThemeName),
            atomically: true,
            encoding: .utf8
        )

        let contents = LibghosttyRuntime.builtInThemeOverrideContents(
            userConfigContents: """
            theme = \(persistedFallbackThemeName)
            """,
            themeDirectories: [themeDirectoryURL]
        )

        XCTAssertNil(contents)
    }

    func testBuiltInThemeOverrideContents_preserves_explicit_user_values_for_safe_defaults() {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let contents = LibghosttyRuntime.builtInThemeOverrideContents(
            userConfigContents: """
            theme = \(persistedFallbackThemeName)
            font-feature = calt
            cursor-opacity = 0.3
            cursor-style = underline
            cursor-style-blink = false
            mouse-hide-while-typing = false
            copy-on-select = false
            clipboard-paste-protection = true
            clipboard-paste-bracketed-safe = false
            """,
            themeDirectories: []
        )

        XCTAssertNotNil(contents)
        XCTAssertFalse(contents?.contains("font-feature = -calt") ?? true)
        XCTAssertFalse(contents?.contains("cursor-opacity = 0.8") ?? true)
        XCTAssertFalse(contents?.contains("cursor-style = block") ?? true)
        XCTAssertFalse(contents?.contains("cursor-style-blink = true") ?? true)
        XCTAssertFalse(contents?.contains("mouse-hide-while-typing = true") ?? true)
        XCTAssertFalse(contents?.contains("copy-on-select = clipboard") ?? true)
        XCTAssertFalse(contents?.contains("clipboard-paste-protection = false") ?? true)
        XCTAssertFalse(contents?.contains("clipboard-paste-bracketed-safe = true") ?? true)
        XCTAssertFalse(contents?.contains("window-padding-x") ?? true)
        XCTAssertFalse(contents?.contains("window-padding-y") ?? true)
    }

    func testTransparentBackgroundOverrideContents_forcesTransparentEmbeddedSurfaceAndAddsFallbackBlur() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            theme = \(GhosttyThemeLibrary.fallbackPersistedThemeName)
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\nbackground-blur-radius = 20\n")
    }

    func testTransparentBackgroundOverrideContents_keepsTransparencyOverrideWhenBlurRadiusConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur-radius = 25
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\n")
    }

    func testTransparentBackgroundOverrideContents_keepsTransparencyOverrideWhenLegacyBackgroundBlurConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur = 25
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\n")
    }

    func testPaddingPolicyOverrideContents_injectsDefaultsWhenKeysMissing() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            theme = MyTheme
            font-family = Monaspace Neon
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 10\nwindow-padding-y = 10\nwindow-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_injectsDefaultsWhenUserConfigIsNil() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(userConfigContents: nil)

        XCTAssertEqual(contents, "window-padding-x = 10\nwindow-padding-y = 10\nwindow-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_bumpsZeroToFloor() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 0
            window-padding-y = 0
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 6\nwindow-padding-y = 6\nwindow-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_bumpsBelowFloorToFloor() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 4
            window-padding-y = 5
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 6\nwindow-padding-y = 6\nwindow-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_returnsNilWhenEverythingIsAlreadyFine() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 6
            window-padding-y = 6
            window-padding-balance = true
            """
        )

        XCTAssertNil(contents)
    }

    func testPaddingPolicyOverrideContents_returnsNilWhenValuesMatchDefaultAndBalanceSet() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 10
            window-padding-y = 10
            window-padding-balance = false
            """
        )

        XCTAssertNil(contents)
    }

    func testPaddingPolicyOverrideContents_returnsOnlyBalanceWhenValuesAboveDefault() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 20
            window-padding-y = 24
            """
        )

        XCTAssertEqual(contents, "window-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_handlesAsymmetricXMissingYZero() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-y = 0
            window-padding-balance = true
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 10\nwindow-padding-y = 6")
    }

    func testPaddingPolicyOverrideContents_handlesAsymmetricXBelowFloorYMissing() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 4
            window-padding-balance = false
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 6\nwindow-padding-y = 10")
    }

    func testPaddingPolicyOverrideContents_ignoresCommentedKey() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            # window-padding-x = 0
            // window-padding-y = 2
            # window-padding-balance = false
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 10\nwindow-padding-y = 10\nwindow-padding-balance = true")
    }

    func testPaddingPolicyOverrideContents_honorsLastValueForDuplicateKey() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 20
            window-padding-x = 2
            window-padding-y = 8
            window-padding-balance = true
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 6")
    }

    func testPaddingPolicyOverrideContents_treatsNonNumericValueAsMissing() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = foo
            window-padding-y = bar
            window-padding-balance = true
            """
        )

        XCTAssertEqual(contents, "window-padding-x = 10\nwindow-padding-y = 10")
    }

    func testPaddingPolicyOverrideContents_respectsExplicitBalanceFalse() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 12
            window-padding-y = 12
            window-padding-balance = false
            """
        )

        XCTAssertNil(contents)
    }

    func testPaddingPolicyOverrideContents_doesNotDuplicateExplicitBalanceTrue() {
        let contents = LibghosttyRuntime.paddingPolicyOverrideContents(
            userConfigContents: """
            window-padding-x = 12
            window-padding-y = 12
            window-padding-balance = true
            """
        )

        XCTAssertNil(contents)
    }
}
