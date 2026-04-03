import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func test_pasted_string_returns_plain_text() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("echo hello world", forType: .string)

        XCTAssertEqual(TerminalClipboard.pastedString(from: pasteboard), "echo hello world")
    }

    func test_pasted_string_ignores_file_urls() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/screenshot.png") as NSURL])

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    func test_pasted_string_ignores_file_urls_even_when_string_representation_exists() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL, .string], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/screenshot.png") as NSURL])
        pasteboard.setString("/tmp/screenshot.png", forType: .string)

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    func test_pasted_string_ignores_non_text_types() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.png], owner: nil)

        XCTAssertNil(TerminalClipboard.pastedString(from: pasteboard))
    }

    private func makeTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("test-\(UUID().uuidString)"))
    }
}
