@testable import Zentty
import XCTest

@MainActor
final class ThemeCatalogServiceTests: XCTestCase {
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

    func testDiscoversSingleThemeWithColors() async {
        let themeContent = """
        background = #1a1b26
        foreground = #c0caf5
        palette = 0=#15161e
        palette = 1=#f7768e
        """
        writeThemeFile(named: "TokyoNight", content: themeContent)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].name, "TokyoNight")
        XCTAssertEqual(themes[0].background.themeHexString, "#1A1B26")
        XCTAssertEqual(themes[0].foreground.themeHexString, "#C0CAF5")
        XCTAssertEqual(themes[0].palette.count, 2)
        XCTAssertEqual(themes[0].palette[0].themeHexString, "#15161E")
        XCTAssertEqual(themes[0].palette[1].themeHexString, "#F7768E")
    }

    func testSkipsFilesMissingForeground() async {
        let content = "background = #000000\n"
        writeThemeFile(named: "NoFg", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertTrue(themes.isEmpty)
    }

    func testSkipsFilesMissingBackground() async {
        let content = "foreground = #ffffff\n"
        writeThemeFile(named: "NoBg", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertTrue(themes.isEmpty)
    }

    func testLaterDirectoryOverridesByName() async {
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
        let themes = await service.loadThemes()

        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].name, "SharedTheme")
        XCTAssertEqual(themes[0].background.themeHexString, "#222222")
        XCTAssertEqual(themes[0].foreground.themeHexString, "#BBBBBB")
    }

    func testSortsCaseInsensitively() async {
        writeThemeFile(named: "Zebra", content: "background = #000000\nforeground = #ffffff\n")
        writeThemeFile(named: "Alpha", content: "background = #000000\nforeground = #ffffff\n")
        writeThemeFile(named: "middle", content: "background = #000000\nforeground = #ffffff\n")

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertEqual(themes.map(\.name), ["Alpha", "middle", "Zebra"])
    }

    func testIgnoresCommentsAndBlankLines() async {
        let content = """
        # This is a comment
        // Another comment

        background = #1a1b26

        foreground = #c0caf5
        """
        writeThemeFile(named: "Commented", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].background.themeHexString, "#1A1B26")
        XCTAssertEqual(themes[0].foreground.themeHexString, "#C0CAF5")
    }

    func testParsesSparsePaletteIndices() async {
        let content = """
        background = #000000
        foreground = #ffffff
        palette = 0=#ff0000
        palette = 2=#00ff00
        palette = 15=#0000ff
        """
        writeThemeFile(named: "Sparse", content: content)

        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].palette.count, 3)
        XCTAssertEqual(themes[0].palette[0].themeHexString, "#FF0000")
        XCTAssertEqual(themes[0].palette[1].themeHexString, "#00FF00")
        XCTAssertEqual(themes[0].palette[2].themeHexString, "#0000FF")
    }

    func testEmptyDirectoryReturnsEmpty() async {
        let service = ThemeCatalogService(themeDirectories: [tempDirectory])
        let themes = await service.loadThemes()

        XCTAssertTrue(themes.isEmpty)
    }

    func testNonExistentDirectoryReturnsEmpty() async {
        let missing = tempDirectory.appendingPathComponent("does-not-exist")
        let service = ThemeCatalogService(themeDirectories: [missing])
        let themes = await service.loadThemes()

        XCTAssertTrue(themes.isEmpty)
    }

    private func writeThemeFile(named name: String, content: String) {
        let url = tempDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
