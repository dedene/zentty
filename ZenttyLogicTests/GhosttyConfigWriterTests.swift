import Foundation
import XCTest
@testable import Zentty

@MainActor
final class GhosttyConfigWriterTests: XCTestCase {
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

    // MARK: - Insert

    func test_writeTheme_creates_file_when_config_does_not_exist() {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: configURL)

        writer.writeTheme("MyTheme")

        let content = try? String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(content, "theme = MyTheme\n")
    }

    func test_writeTheme_inserts_at_top_when_no_theme_line_exists() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try "font-size = 14\nbackground = #000000".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = GhosttyConfigWriter(configURL: configURL)
        writer.writeTheme("Dracula")

        let content = try String(contentsOf: configURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "theme = Dracula")
        XCTAssertTrue(content.contains("font-size = 14"))
        XCTAssertTrue(content.contains("background = #000000"))
    }

    // MARK: - Replace

    func test_writeTheme_replaces_existing_theme_line() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try "theme = OldTheme\nfont-size = 14".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = GhosttyConfigWriter(configURL: configURL)
        writer.writeTheme("NewTheme")

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("theme = NewTheme"))
        XCTAssertFalse(content.contains("OldTheme"))
        XCTAssertTrue(content.contains("font-size = 14"))
    }

    func test_writeTheme_leaves_commented_theme_lines_untouched() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try "# theme = Commented\ntheme = Active".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = GhosttyConfigWriter(configURL: configURL)
        writer.writeTheme("Updated")

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# theme = Commented"))
        XCTAssertTrue(content.contains("theme = Updated"))
        XCTAssertFalse(content.contains("theme = Active"))
    }

    // MARK: - Sanitization

    func test_writeTheme_strips_quotes_and_newlines() {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: configURL)

        writer.writeTheme("\"Bad\nTheme\r\"")

        let content = try? String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(content, "theme = BadTheme\n")
    }

    func test_writeTheme_is_noop_when_name_is_empty_after_sanitization() {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: configURL)

        writer.writeTheme("\"\"")

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    // MARK: - Directory creation

    func test_writeTheme_creates_parent_directories_when_needed() {
        let nestedURL = temporaryDirectoryURL
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: nestedURL)

        writer.writeTheme("Test")

        let content = try? String(contentsOf: nestedURL, encoding: .utf8)
        XCTAssertEqual(content, "theme = Test\n")
    }

    // MARK: - Background opacity

    func test_writeBackgroundOpacity_inserts_when_missing() {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: configURL)

        writer.writeBackgroundOpacity(0.85)

        let content = try? String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(content, "background-opacity = 0.85\n")
    }

    func test_writeBackgroundOpacity_replaces_existing() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try "background-opacity = 1.00\ntheme = Dracula".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = GhosttyConfigWriter(configURL: configURL)
        writer.writeBackgroundOpacity(0.50)

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("background-opacity = 0.50"))
        XCTAssertFalse(content.contains("1.00"))
        XCTAssertTrue(content.contains("theme = Dracula"))
    }

    func test_writeBackgroundOpacity_clamps_to_valid_range() {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        let writer = GhosttyConfigWriter(configURL: configURL)

        writer.writeBackgroundOpacity(1.5)

        let content = try? String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(content, "background-opacity = 1.00\n")
    }

    // MARK: - Generic updateValue

    func test_updateValue_works_for_arbitrary_keys() throws {
        let configURL = temporaryDirectoryURL.appendingPathComponent("config")
        try "font-size = 14".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = GhosttyConfigWriter(configURL: configURL)
        writer.updateValue("16", forKey: "font-size")

        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("font-size = 16"))
        XCTAssertFalse(content.contains("font-size = 14"))
    }
}
