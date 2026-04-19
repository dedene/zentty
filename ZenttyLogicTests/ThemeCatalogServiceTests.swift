@testable import Zentty
import XCTest

@MainActor
final class ThemeCatalogServiceTests: AppKitTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeCatalogServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testDiscoversSingleThemeWithColors() {
        let themeContent = """
        background = #1a1b26
        foreground = #c0caf5
        palette = 0=#15161e
        palette = 1=#f7768e
        """
        writeThemeFile(named: "TokyoNight", content: themeContent)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()
        guard let tokyoNight = themes.first(where: { $0.name == "TokyoNight" }) else {
            XCTFail("Expected TokyoNight preview")
            return
        }

        XCTAssertEqual(themes.count, 2)
        XCTAssertEqual(tokyoNight.name, "TokyoNight")
        XCTAssertEqual(tokyoNight.background.themeHexString, "#1A1B26")
        XCTAssertEqual(tokyoNight.foreground.themeHexString, "#C0CAF5")
        XCTAssertEqual(tokyoNight.palette.count, 2)
        XCTAssertEqual(tokyoNight.palette[0].themeHexString, "#15161E")
        XCTAssertEqual(tokyoNight.palette[1].themeHexString, "#F7768E")
    }

    func testSkipsFilesMissingForeground() {
        let content = "background = #000000\n"
        writeThemeFile(named: "NoFg", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.map(\.name), ["Zentty-Default"])
        XCTAssertEqual(themes.map(\.displayName), ["Zentty Default Theme"])
    }

    func testSkipsFilesMissingBackground() {
        let content = "foreground = #ffffff\n"
        writeThemeFile(named: "NoBg", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.map(\.name), ["Zentty-Default"])
        XCTAssertEqual(themes.map(\.displayName), ["Zentty Default Theme"])
    }

    func testLaterDirectoryOverridesByName() {
        let bundledDir = tempDirectory.appendingPathComponent("bundled")
        let userDir = tempDirectory.appendingPathComponent("user")
        try? FileManager.default.createDirectory(at: bundledDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        let bundledContent = """
        background = #111111
        foreground = #aaaaaa
        """
        try? bundledContent.write(
            to: bundledDir.appendingPathComponent("SharedTheme"),
            atomically: true,
            encoding: .utf8
        )

        let userContent = """
        background = #222222
        foreground = #bbbbbb
        """
        try? userContent.write(
            to: userDir.appendingPathComponent("SharedTheme"),
            atomically: true,
            encoding: .utf8
        )

        let service = ThemeCatalogService(themeDirectories: [bundledDir, userDir])
        let themes = service.loadThemesSynchronouslyForTesting()
        guard let sharedTheme = themes.first(where: { $0.name == "SharedTheme" }) else {
            XCTFail("Expected SharedTheme preview")
            return
        }

        XCTAssertEqual(themes.count, 2)
        XCTAssertEqual(sharedTheme.name, "SharedTheme")
        XCTAssertEqual(sharedTheme.background.themeHexString, "#222222")
        XCTAssertEqual(sharedTheme.foreground.themeHexString, "#BBBBBB")
    }

    func testSortsCaseInsensitively() {
        writeThemeFile(named: "Zebra", content: "background = #000000\nforeground = #ffffff\n")
        writeThemeFile(named: "Alpha", content: "background = #000000\nforeground = #ffffff\n")
        writeThemeFile(named: "middle", content: "background = #000000\nforeground = #ffffff\n")

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.map(\.name), ["Alpha", "middle", "Zebra", "Zentty-Default"])
        XCTAssertEqual(
            themes.map(\.displayName),
            ["Alpha", "middle", "Zebra", "Zentty Default Theme"]
        )
    }

    func testIgnoresCommentsAndBlankLines() {
        let content = """
        # This is a comment
        // Another comment

        background = #1a1b26

        foreground = #c0caf5
        """
        writeThemeFile(named: "Commented", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()
        guard let commentedTheme = themes.first(where: { $0.name == "Commented" }) else {
            XCTFail("Expected Commented preview")
            return
        }

        XCTAssertEqual(themes.count, 2)
        XCTAssertEqual(commentedTheme.background.themeHexString, "#1A1B26")
        XCTAssertEqual(commentedTheme.foreground.themeHexString, "#C0CAF5")
    }

    func testParsesSparsePaletteIndices() {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 0=#ff0000
        palette = 2=#00ff00
        palette = 15=#0000ff
        """
        writeThemeFile(named: "Sparse", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()
        guard let sparseTheme = themes.first(where: { $0.name == "Sparse" }) else {
            XCTFail("Expected Sparse preview")
            return
        }

        XCTAssertEqual(themes.count, 2)
        XCTAssertEqual(sparseTheme.palette.count, 3)
        XCTAssertEqual(sparseTheme.palette[0].themeHexString, "#FF0000")
        XCTAssertEqual(sparseTheme.palette[1].themeHexString, "#00FF00")
        XCTAssertEqual(sparseTheme.palette[2].themeHexString, "#0000FF")
    }

    func testEmptyDirectoryReturnsEmpty() {
        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.map(\.name), ["Zentty-Default"])
        XCTAssertEqual(themes.map(\.displayName), ["Zentty Default Theme"])
    }

    func testNonExistentDirectoryReturnsEmpty() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist")
        let service = ThemeCatalogService(themeDirectories: [missing])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.map(\.name), ["Zentty-Default"])
        XCTAssertEqual(themes.map(\.displayName), ["Zentty Default Theme"])
    }

    func testDiscoveredThemeOverridesBuiltInFallbackByName() {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let content = """
        background = #101418
        foreground = #e6edf3
        palette = 0=#111111
        """
        writeThemeFile(named: persistedFallbackThemeName, content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()

        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].name, "Zentty-Default")
        XCTAssertEqual(themes[0].displayName, "Zentty Default Theme")
        XCTAssertEqual(themes[0].background.themeHexString, "#101418")
        XCTAssertEqual(themes[0].foreground.themeHexString, "#E6EDF3")
        XCTAssertEqual(themes[0].palette.first?.themeHexString, "#111111")
    }

    func testAddsBuiltInFallbackAlongsideDiscoveredThemes() {
        writeThemeFile(named: "TokyoNight", content: "background = #1a1b26\nforeground = #c0caf5\n")

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = service.loadThemesSynchronouslyForTesting()
        guard let fallbackTheme = themes.first(where: { $0.name == "Zentty-Default" }) else {
            XCTFail("Expected built-in default theme preview")
            return
        }

        XCTAssertEqual(themes.map(\.name), ["TokyoNight", "Zentty-Default"])
        XCTAssertEqual(themes.map(\.displayName), ["TokyoNight", "Zentty Default Theme"])
        XCTAssertEqual(fallbackTheme.background.themeHexString, "#0A0C10")
        XCTAssertEqual(fallbackTheme.foreground.themeHexString, "#F0F3F6")
    }

    func testAsyncLoadThemesYieldsMainActorWhileDiscovering() {
        let finished = expectation(description: "Async theme load finished")

        Task { @MainActor in
            let themeContent = """
            background = #101418
            foreground = #e6edf3
            palette = 0=#111111
            palette = 1=#222222
            palette = 2=#333333
            palette = 3=#444444
            """
            for index in 0..<4_000 {
                writeThemeFile(named: "Theme-\(index)", content: themeContent)
            }

            let service = ThemeCatalogService(themeDirectories: [tempDirectory])
            var mainQueueHeartbeatRan = false
            DispatchQueue.main.async {
                mainQueueHeartbeatRan = true
            }

            let themes = await service.loadThemes()

            XCTAssertEqual(themes.count, 4_001)
            XCTAssertTrue(
                mainQueueHeartbeatRan,
                "Expected async theme discovery to yield the main actor so the Appearance pane can paint its first frame."
            )
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
    }

    private func writeThemeFile(named name: String, content: String) {
        let url = tempDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
