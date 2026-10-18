import XCTest
@testable import Zentty

final class PaneKeyNamesTests: XCTestCase {
    func test_named_keys_are_case_insensitive() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "Enter"), .key(.enter, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "ENTER"), .key(.enter, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "escape"), .key(.escape, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "Esc"), .key(.escape, shift: false))
    }

    func test_cursor_navigation_and_function_keys() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "Up"), .key(.up, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "S-Left"), .key(.left, shift: true))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "PgUp"), .key(.pageUp, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "NPage"), .key(.pageDown, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "DC"), .key(.delete, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "BTab"), .key(.backTab, shift: true))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "F12"), .key(.f12, shift: false))
    }

    func test_control_aliases_resolve_to_their_named_keys() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "C-m"), .key(.enter, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "C-i"), .key(.tab, shift: false))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "C-["), .key(.escape, shift: false))
    }

    func test_control_letters() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "C-c"), .control("c"))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "C-D"), .control("d"))
        XCTAssertEqual(PaneKeyStroke.control("c").legacyText, "\u{03}")
    }

    func test_meta_prefixes_escape() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "M-x"), .text("\u{1b}x"))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "M-Enter"), .text("\u{1b}\r"))
    }

    func test_single_characters_are_literal() throws {
        XCTAssertEqual(try PaneKeyNames.stroke(for: "y"), .text("y"))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "1"), .text("1"))
        XCTAssertEqual(try PaneKeyNames.stroke(for: "é"), .text("é"))
    }

    func test_unknown_names_fail_instead_of_being_typed() {
        for token in ["Entr", "C-1", "M-", "hello"] {
            XCTAssertThrowsError(try PaneKeyNames.stroke(for: token), token) { error in
                XCTAssertEqual(error as? PaneKeyNameError, .unknownKey(token))
            }
        }
    }

    func test_legacy_text_for_cursor_keys() {
        XCTAssertEqual(PaneKeyStroke.key(.up, shift: false).legacyText, "\u{1b}[A")
        XCTAssertEqual(PaneKeyStroke.key(.enter, shift: false).legacyText, "\r")
    }

    /// The agent-teams shim's control-key table must stay byte-for-byte
    /// what it was before the table moved.
    func test_control_key_text_table_is_stable() {
        let expected: [String: String] = [
            "Enter": "\r", "C-m": "\r", "KPEnter": "\r",
            "Tab": "\t", "C-i": "\t",
            "Space": " ",
            "BSpace": "\u{7f}", "Backspace": "\u{7f}",
            "Escape": "\u{1b}", "Esc": "\u{1b}", "C-[": "\u{1b}",
            "C-c": "\u{03}", "C-d": "\u{04}", "C-z": "\u{1a}", "C-l": "\u{0c}",
        ]
        for (name, bytes) in expected {
            XCTAssertEqual(PaneKeyNames.controlKeyText(name), bytes, name)
        }
        XCTAssertNil(PaneKeyNames.controlKeyText("Up"))
        XCTAssertNil(PaneKeyNames.controlKeyText("hello"))
    }

    func test_agent_teams_shim_text_still_uses_control_table_only() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%1", "ls", "Enter"], standardInput: nil),
            "ls\r"
        )
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["Up"], standardInput: nil),
            "Up"
        )
    }
}
