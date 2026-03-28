import XCTest
@testable import Zentty

final class ShellEscapingTests: XCTestCase {
    func test_plain_path_is_unchanged() {
        XCTAssertEqual(ShellEscaping.escapePath("/usr/local/bin"), "/usr/local/bin")
    }

    func test_spaces_are_escaped() {
        XCTAssertEqual(ShellEscaping.escapePath("/Users/me/my folder"), "/Users/me/my\\ folder")
    }

    func test_parentheses_are_escaped() {
        XCTAssertEqual(ShellEscaping.escapePath("/tmp/file (1).txt"), "/tmp/file\\ \\(1\\).txt")
    }

    func test_multiple_special_characters() {
        XCTAssertEqual(ShellEscaping.escapePath("/tmp/it's \"fun\""), "/tmp/it\\'s\\ \\\"fun\\\"")
    }

    func test_backslash_is_escaped() {
        XCTAssertEqual(ShellEscaping.escapePath("/tmp/a\\b"), "/tmp/a\\\\b")
    }

    func test_empty_string() {
        XCTAssertEqual(ShellEscaping.escapePath(""), "")
    }

    func test_tab_is_escaped() {
        XCTAssertEqual(ShellEscaping.escapePath("/tmp/a\tb"), "/tmp/a\\\tb")
    }

    func test_multiple_paths_joined() {
        let paths = ["/tmp/a b", "/tmp/c d"]
        let result = paths.map(ShellEscaping.escapePath).joined(separator: " ")
        XCTAssertEqual(result, "/tmp/a\\ b /tmp/c\\ d")
    }
}
