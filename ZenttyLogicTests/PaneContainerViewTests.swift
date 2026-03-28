import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewTests: XCTestCase {
    func test_pane_hosts_terminal_edge_to_edge_without_internal_header() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil),
            backingScaleFactorProvider: { 2 }
        )
        paneView.layoutSubtreeIfNeeded()

        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }
        let borderFrame = paneView.insetBorderFrame

        XCTAssertFalse(paneView.descendantSubviews().contains { $0 is NSStackView })
        XCTAssertEqual(terminalSurfaceView.frame, paneView.bounds)
        XCTAssertEqual(paneView.layer?.borderWidth ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(paneView.layer?.cornerRadius ?? 0, ChromeGeometry.paneRadius, accuracy: 0.001)
        XCTAssertTrue(paneView.usesInsetBorderLayer)
        XCTAssertEqual(paneView.insetBorderLineWidth, 1, accuracy: 0.001)
        let expectedInset = ChromeGeometry.paneBorderInset(backingScaleFactor: 2)
        XCTAssertEqual(paneView.insetBorderInset, expectedInset, accuracy: 0.001)
        XCTAssertEqual(
            paneView.insetBorderCornerRadius,
            max(0, ChromeGeometry.paneRadius - expectedInset),
            accuracy: 0.001
        )
        XCTAssertEqual(paneView.insetBorderCornerCurve, .continuous)
        XCTAssertEqual(borderFrame.minX, expectedInset, accuracy: 0.001)
        XCTAssertLessThan(borderFrame.maxX, paneView.bounds.maxX)
        XCTAssertEqual(borderFrame.minY, expectedInset, accuracy: 0.001)
        XCTAssertLessThan(borderFrame.maxY, paneView.bounds.maxY)
    }

    func test_startup_failure_shows_retry_and_close_actions() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        runtime.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(adapter.startSessionCallCount, 1)
        XCTAssertEqual(paneView.statusTitle, "Pane failed to start")
        XCTAssertFalse(paneView.isRetryButtonHidden)
        XCTAssertFalse(paneView.isCloseButtonHidden)
    }

    func test_retry_button_retries_session_start_and_hides_error_on_success() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        runtime.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        paneView.retryButtonForTesting.performClick(paneView)
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))

        XCTAssertEqual(adapter.startSessionCallCount, 2)
        XCTAssertTrue(paneView.isStatusOverlayHidden)
    }

    func test_close_button_notifies_observer_when_startup_failed() {
        let adapter = PaneContainerTerminalAdapterSpy(startSessionFailures: [TestError.startupFailed])
        let pane = PaneState(id: PaneID("broken"), title: "broken")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        runtime.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))
        var didRequestClose = false

        paneView.onCloseRequested = {
            didRequestClose = true
        }

        paneView.closeButtonForTesting.performClick(paneView)

        XCTAssertTrue(didRequestClose)
    }

    func test_empty_metadata_keeps_overlay_hidden() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
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

        XCTAssertTrue(paneView.isStatusOverlayHidden)
    }

    func test_present_metadata_hides_metadata_unavailable_state() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
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

        XCTAssertTrue(paneView.isStatusOverlayHidden)
    }

    func test_pane_container_keeps_border_context_chrome_outside_pane_ownership() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil),
            backingScaleFactorProvider: { 2 }
        )

        paneView.render(
            pane: pane,
            emphasis: 1,
            isFocused: true
        )
        paneView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneView.hasPaneContextChrome)
    }

    func test_render_updates_content_without_mutating_frame() {
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        let originalFrame = paneView.frame

        paneView.render(
            pane: PaneState(id: PaneID("logs"), title: "logs"),
            emphasis: 0.92,
            isFocused: false
        )

        XCTAssertEqual(paneView.frame, originalFrame)
        XCTAssertEqual(paneView.paneID, PaneID("logs"))
        XCTAssertEqual(paneView.titleText, "logs")
    }

    func test_terminal_host_and_overlay_follow_bounds_after_resize() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        paneView.frame.size = NSSize(width: 610, height: 330)
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(terminalSurfaceView.frame, paneView.bounds)
        XCTAssertEqual(paneView.statusOverlayFrame, paneView.bounds)
    }

    func test_vertical_freeze_keeps_terminal_height_stable() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        paneView.layoutSubtreeIfNeeded()

        paneView.beginVerticalFreeze(gravity: .top)
        XCTAssertTrue(paneView.isTerminalAnimationFrozenForTesting)

        paneView.frame.size = NSSize(width: 420, height: 300)
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(terminalSurfaceView.frame.height, 520, accuracy: 0.001,
                       "Terminal height should stay at original size during freeze")

        paneView.endVerticalFreeze()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneView.isTerminalAnimationFrozenForTesting)
        XCTAssertEqual(terminalSurfaceView.frame.height, paneView.bounds.height, accuracy: 0.001)
    }

    func test_vertical_freeze_keeps_clip_and_anchor_tracking_bounds() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
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
        paneView.beginVerticalFreeze(gravity: .bottom)
        paneView.frame.size = NSSize(width: 420, height: 300)
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneView.contentClipFrameForTesting, paneView.bounds)
        XCTAssertEqual(paneView.terminalAnchorFrameForTesting, paneView.bounds)
    }

    func test_nonzero_cell_height_does_not_leave_bottom_remainder() {
        let adapter = PaneContainerTerminalAdapterSpy()
        adapter.cellHeight = 18
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 517,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(terminalSurfaceView.frame.height, paneView.bounds.height, accuracy: 0.001)
    }

    func test_content_clip_background_matches_startup_surface() {
        let theme = ZenttyTheme.fallback(for: nil)
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: theme
        )

        XCTAssertEqual(paneView.contentClipBackgroundColorTokenForTesting, theme.startupSurface.themeToken)
    }

    func test_pane_contents_are_clipped_to_the_pane_bounds() {
        let pane = PaneState(id: PaneID("editor"), title: "editor")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: PaneContainerTerminalAdapterSpy(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertTrue(paneView.clipsContentToBounds)
    }

    func test_initial_focused_pane_uses_focused_chrome_tokens() {
        let theme = ZenttyTheme.fallback(for: nil)
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: theme
        )

        XCTAssertEqual(paneView.backgroundColorTokenForTesting, theme.paneFillFocused.themeToken)
        XCTAssertEqual(paneView.insetBorderColorToken, theme.paneBorderFocused.themeToken)
        XCTAssertGreaterThan(paneView.shadowOpacityForTesting, 0)
        XCTAssertGreaterThan(paneView.shadowRadiusForTesting, 6)
    }

    func test_animated_unfocused_render_updates_focus_chrome_without_mutating_alpha() {
        let theme = ZenttyTheme.fallback(for: nil)
        let adapter = PaneContainerTerminalAdapterSpy()
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: theme
        )
        let originalAlpha = paneView.alphaValue

        paneView.render(
            pane: pane,
            emphasis: 0.92,
            isFocused: false,
            animated: true
        )

        XCTAssertEqual(paneView.backgroundColorTokenForTesting, theme.paneFillUnfocused.themeToken)
        XCTAssertEqual(paneView.insetBorderColorToken, theme.paneBorderUnfocused.themeToken)
        XCTAssertEqual(paneView.shadowOpacityForTesting, Float((0.92 - 0.88) * 2.2), accuracy: 0.001)
        XCTAssertEqual(paneView.shadowRadiusForTesting, 6, accuracy: 0.001)
        XCTAssertEqual(paneView.alphaValue, originalAlpha, accuracy: 0.001)
    }

    func test_unfocused_presentation_alpha_uses_stronger_inactive_dimming() {
        XCTAssertEqual(
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            0.7,
            accuracy: 0.001
        )
    }
}

private enum TestError: Error {
    case startupFailed
}

@MainActor
private final class PaneContainerTerminalAdapterSpy: TerminalAdapter {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
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
