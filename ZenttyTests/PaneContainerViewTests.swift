import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewTests: XCTestCase {
    func test_pane_hosts_terminal_edge_to_edge_without_internal_header() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(pane: pane, adapter: PaneContainerTerminalAdapterSpy(), metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        paneView.layoutSubtreeIfNeeded()

        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        XCTAssertFalse(paneView.descendantSubviews().contains { $0 is NSStackView })
        XCTAssertEqual(terminalSurfaceView.frame, paneView.bounds)
    }

    func test_startup_failure_shows_retry_and_close_actions() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(adapter.startSessionCallCount, 1)
        XCTAssertEqual(paneView.statusTitleForTesting, "Pane failed to start")
        XCTAssertFalse(paneView.isRetryButtonHiddenForTesting)
        XCTAssertFalse(paneView.isCloseButtonHiddenForTesting)
    }

    func test_retry_button_retries_session_start_and_hides_error_on_success() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        paneView.retryButtonForTesting.performClick(nil)
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))

        XCTAssertEqual(adapter.startSessionCallCount, 2)
        XCTAssertTrue(paneView.isStatusOverlayHiddenForTesting)
    }

    func test_close_button_notifies_observer_when_startup_failed() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        var didRequestClose = false

        paneView.onCloseRequested = {
            didRequestClose = true
        }

        paneView.closeButtonForTesting.performClick(nil)

        XCTAssertTrue(didRequestClose)
    }

    func test_empty_metadata_keeps_overlay_hidden() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        adapter.metadataDidChange?(TerminalMetadata())

        XCTAssertTrue(paneView.isStatusOverlayHiddenForTesting)
    }

    func test_initial_empty_runtime_snapshot_stays_hidden_until_metadata_is_reported() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertTrue(paneView.isStatusOverlayHiddenForTesting)
    }

    func test_present_metadata_hides_metadata_unavailable_state() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in })
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))

        XCTAssertTrue(paneView.isStatusOverlayHiddenForTesting)
    }
}

private enum TestError: Error {
    case startupFailed
}

@MainActor
private final class PaneContainerTerminalAdapterSpy: TerminalAdapter {
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    private let terminalView = NSView()
    private var startSessionFailures: [Error]
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity()

    init(startSessionFailures: [Error] = []) {
        self.startSessionFailures = startSessionFailures
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startSessionCallCount += 1
        if !startSessionFailures.isEmpty {
            throw startSessionFailures.removeFirst()
        }
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private extension NSView {
    func descendantSubviews() -> [NSView] {
        var views: [NSView] = []

        func walk(_ view: NSView) {
            views.append(view)
            view.subviews.forEach(walk)
        }

        subviews.forEach(walk)
        return views
    }
}
