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

    func test_focus_terminal_makes_adapter_view_first_responder() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        hostView.focusTerminal()

        XCTAssertTrue(window.firstResponder === hostView.terminalViewForTesting)
    }

    func test_focus_changes_from_terminal_view_are_forwarded() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        var didBecomeFocused = false

        hostView.onFocusDidChange = { isFocused in
            didBecomeFocused = isFocused
        }

        _ = adapter.terminalView.becomeFirstResponder()

        XCTAssertTrue(didBecomeFocused)
    }
}

@MainActor
private final class TerminalAdapterSpy: TerminalAdapter {
    let terminalView = FirstResponderTerminalView()
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    private(set) var startSessionCallCount = 0

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession() throws {
        startSessionCallCount += 1
    }
}

private final class FirstResponderTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }
}
