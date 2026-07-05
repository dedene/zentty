import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func test_image_upload_content_rejects_oversized_raw_image_data() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data(count: TerminalClipboardImagePolicy.maxImageByteCount + 1), forType: .png)

        switch TerminalClipboard.imageUploadContent(from: pasteboard) {
        case .imageTooLarge:
            break
        case let content:
            XCTFail("Expected imageTooLarge, got \(content)")
        }
    }

    func test_file_urls_returns_file_urls_for_any_file_type_in_drop_order() {
        let pasteboard = makeTestPasteboard()
        let pdfURL = URL(fileURLWithPath: "/tmp/Quarterly Report.pdf")
        let movieURL = URL(fileURLWithPath: "/tmp/demo.mov")
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([pdfURL as NSURL, movieURL as NSURL])

        XCTAssertEqual(TerminalClipboard.fileURLs(from: pasteboard), [pdfURL, movieURL])
    }

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
