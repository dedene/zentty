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

    func test_terminal_view_tracks_host_bounds_after_resize() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.layoutSubtreeIfNeeded()
        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(adapter.terminalView.frame, hostView.bounds)
    }

    func test_start_session_if_needed_starts_adapter_only_once() throws {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        try hostView.startSessionIfNeeded(using: TerminalSessionRequest(workingDirectory: "/tmp/project"))
        try hostView.startSessionIfNeeded(using: TerminalSessionRequest(workingDirectory: "/tmp/project"))

        XCTAssertEqual(adapter.startSessionCallCount, 1)
        XCTAssertEqual(adapter.lastRequest, TerminalSessionRequest(workingDirectory: "/tmp/project"))
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
        addTeardownBlock { window.close() }

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

    func test_surface_activity_is_forwarded_to_adapter() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.setSurfaceActivity(TerminalSurfaceActivity(isVisible: false, isFocused: false))

        XCTAssertEqual(adapter.lastSurfaceActivity, TerminalSurfaceActivity(isVisible: false, isFocused: false))
    }

    func test_viewport_sync_suspension_is_forwarded_to_terminal_view() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.setViewportSyncSuspended(true)
        hostView.setViewportSyncSuspended(false)

        XCTAssertEqual(adapter.terminalView.viewportSyncSuspensionUpdates, [true, false])
    }
}

@MainActor
private final class TerminalAdapterSpy: TerminalAdapter {
    let terminalView = FirstResponderTerminalView()
    var hasScrollback = false
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastRequest: TerminalSessionRequest?
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: true, isFocused: false)

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startSessionCallCount += 1
        lastRequest = request
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private final class FirstResponderTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []

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

extension FirstResponderTerminalView: TerminalViewportSyncControlling {
    func setViewportSyncSuspended(_ suspended: Bool) {
        viewportSyncSuspensionUpdates.append(suspended)
    }
}
