import GhosttyKit
import XCTest
@testable import Zentty

final class TerminalClipboardConfirmationTests: XCTestCase {
    func test_request_kinds_map_from_libghostty() {
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_PASTE), .paste)
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ), .read)
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ), .read)
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE), .write)
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE), .write)
        XCTAssertEqual(TerminalClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_LIST), .list)
        XCTAssertNil(TerminalClipboardRequestKind(ghostty_clipboard_request_e(rawValue: 999)))
    }

    func test_read_prompt_offers_deny_before_allow() {
        let kind = TerminalClipboardRequestKind.read
        XCTAssertEqual(kind.denyButtonTitle, "Deny")
        XCTAssertEqual(kind.allowButtonTitle, "Allow")
        XCTAssertEqual(TerminalClipboardRequestKind.paste.allowButtonTitle, "Paste")
    }

    func test_read_preview_shows_plain_text_contents() {
        let confirmation = TerminalClipboardConfirmation(
            kind: .read,
            contents: [text("secret token\nline two")],
            available: [],
            canRemember: false
        )
        XCTAssertEqual(confirmation.previewText, "secret token\nline two")
        XCTAssertNil(confirmation.imageData)
    }

    func test_preview_makes_control_characters_visible() {
        let confirmation = TerminalClipboardConfirmation(
            kind: .paste,
            contents: [text("ls\r\u{1B}[2Krm -rf ~\u{07}\u{7F}\u{9B}\tok")],
            available: [],
            canRemember: false
        )
        XCTAssertEqual(confirmation.previewText, "ls\u{240D}\u{241B}[2Krm -rf ~\u{2407}\u{2421}\u{FFFD}\tok")
    }

    func test_preview_truncates_very_long_text() {
        let long = String(repeating: "a", count: TerminalClipboardConfirmation.previewCharacterLimit + 50)
        let preview = TerminalClipboardConfirmation.visibleText(long)
        XCTAssertEqual(preview.count, TerminalClipboardConfirmation.previewCharacterLimit + 2)
        XCTAssertTrue(preview.hasSuffix("\n\u{2026}"))
    }

    func test_image_contents_are_previewed_as_image() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let confirmation = TerminalClipboardConfirmation(
            kind: .read,
            contents: [LibghosttyClipboardContent(mime: "image/png", data: png)],
            available: [],
            canRemember: true
        )
        XCTAssertEqual(confirmation.imageData, png)
        XCTAssertTrue(confirmation.previewText.hasPrefix("image/png ("))
        XCTAssertTrue(confirmation.canRemember)
    }

    func test_list_preview_shows_available_types() {
        let confirmation = TerminalClipboardConfirmation(
            kind: .list,
            contents: [],
            available: ["text/plain", "image/png"],
            canRemember: false
        )
        XCTAssertEqual(confirmation.previewText, "text/plain\nimage/png")
    }

    func test_empty_read_says_clipboard_is_empty() {
        let confirmation = TerminalClipboardConfirmation(kind: .read, contents: [], available: [], canRemember: false)
        XCTAssertEqual(confirmation.previewText, "The clipboard is empty.")
    }

    private func text(_ string: String) -> LibghosttyClipboardContent {
        LibghosttyClipboardContent(mime: "text/plain", data: Data(string.utf8))
    }
}
