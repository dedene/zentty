import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalClipboardTests: XCTestCase {
    func test_image_upload_content_rejects_oversized_image_file_before_reading() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zentty.TerminalClipboardTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let imageURL = directoryURL.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: Data([0x89, 0x50, 0x4E, 0x47])))
        let fileHandle = try FileHandle(forWritingTo: imageURL)
        try fileHandle.truncate(atOffset: UInt64(TerminalClipboardImagePolicy.maxImageByteCount + 1))
        try fileHandle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: imageURL.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([imageURL as NSURL])

        switch TerminalClipboard.imageUploadContent(from: pasteboard) {
        case .imageTooLarge:
            break
        case let content:
            XCTFail("Expected imageTooLarge, got \(content)")
        }
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
