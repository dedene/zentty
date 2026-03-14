import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalPaneHostViewTests: XCTestCase {
    func test_host_view_embeds_adapter_terminal_view_edge_to_edge() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertTrue(hostView.subviews.contains { $0 === adapter.terminalView })
        XCTAssertEqual(adapter.terminalView.frame, hostView.bounds)
    }

    func test_start_session_if_needed_starts_adapter_only_once() throws {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        try hostView.startSessionIfNeeded()
        try hostView.startSessionIfNeeded()

        XCTAssertEqual(adapter.startSessionCallCount, 1)
    }

    func test_metadata_callback_is_forwarded_to_host_observer() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        let metadata = TerminalMetadata(
            title: "shell",
            currentWorkingDirectory: "/tmp/project",
            processName: "zsh",
            gitBranch: "main"
        )
        var receivedMetadata: TerminalMetadata?

        hostView.onMetadataDidChange = { receivedMetadata = $0 }
        adapter.metadataDidChange?(metadata)

        XCTAssertEqual(receivedMetadata, metadata)
    }
}

@MainActor
private final class TerminalAdapterSpy: TerminalAdapter {
    let terminalView = NSView()
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    private(set) var startSessionCallCount = 0

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession() throws {
        startSessionCallCount += 1
    }
}
