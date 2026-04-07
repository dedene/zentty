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

    func test_search_hud_renders_inside_pane_when_search_is_visible() {
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneView.isSearchHUDHiddenForTesting)
        XCTAssertGreaterThan(paneView.searchHUDFrameForTesting.midX, paneView.bounds.midX)
        XCTAssertGreaterThan(paneView.searchHUDFrameForTesting.midY, paneView.bounds.midY)
    }

    func test_search_hud_shows_unselected_count_when_opened_before_results_arrive() {
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            paneView.searchHUDCountTextForTesting,
            "-/0",
            "Opening the HUD should not imply that the first match is already selected before search results arrive"
        )
    }

    func test_search_hud_is_portal_hosted_inside_terminal_host() {
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
        guard let terminalHostView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            paneView.searchHUDCloseButtonForTesting.isDescendant(of: terminalHostView),
            "Search HUD controls should be mounted inside the terminal host like the app's terminal-hosted overlay"
        )
        XCTAssertTrue(
            paneView.searchHUDQueryFieldForTesting.isDescendant(of: terminalHostView),
            "Search field should live in the terminal host view tree so AppKit focus and hit testing stay local"
        )
    }

    func test_search_hud_mounts_inside_terminal_overlay_host_when_available() {
        let terminalView = OverlayHostingTerminalView()
        let adapter = PaneContainerTerminalAdapterSpy(terminalView: terminalView)
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            paneView.searchHUDCloseButtonForTesting.isDescendant(of: terminalView.overlayHostView),
            "When the terminal provides an overlay host, the search HUD should mount there instead of the generic wrapper"
        )
    }

    func test_search_hud_updates_terminal_mouse_suppression_rects() {
        let terminalView = OverlayHostingTerminalView()
        let adapter = PaneContainerTerminalAdapterSpy(terminalView: terminalView)
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(terminalView.mouseInteractionSuppressionRects.count, 1)
        XCTAssertEqual(
            terminalView.mouseInteractionSuppressionRects[0],
            paneView.searchHUDFrameForTesting,
            "The live terminal should suppress mouse handling inside the visible HUD rect"
        )

        runtime.hideSearchHUD()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertTrue(terminalView.mouseInteractionSuppressionRects.isEmpty)
    }

    func test_search_hud_drag_updates_terminal_mouse_suppression_rects() {
        let terminalView = OverlayHostingTerminalView()
        let adapter = PaneContainerTerminalAdapterSpy(terminalView: terminalView)
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        let displacedOrigin = CGPoint(x: 24, y: 18)
        paneView.setSearchHUDOriginForTesting(displacedOrigin)

        XCTAssertEqual(terminalView.mouseInteractionSuppressionRects.count, 1)
        XCTAssertEqual(
            terminalView.mouseInteractionSuppressionRects[0].origin,
            displacedOrigin,
            "Dragging the HUD should keep the terminal suppression rect aligned with the live HUD frame"
        )
    }

    func test_search_hud_ignores_focus_transfer_blur_then_hides_on_real_blur() {
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

        runtime.showSearch()
        runtime.updateSearchNeedle("build")
        runtime.handleTerminalFocusChange(false)
        paneView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneView.isSearchHUDHiddenForTesting)
        XCTAssertTrue(runtime.snapshot.search.hasRememberedSearch)
        XCTAssertEqual(runtime.snapshot.search.needle, "build")

        runtime.handleTerminalFocusChange(false)
        paneView.layoutSubtreeIfNeeded()

        XCTAssertTrue(paneView.isSearchHUDHiddenForTesting)
    }

    func test_search_hud_formats_unselected_match_count_like_ghostty() {
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

        runtime.showSearch()
        adapter.searchDidChange?(.total(1))
        adapter.searchDidChange?(.selected(-1))
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneView.searchHUDCountTextForTesting, "-/1")
    }

    func test_mock_terminal_search_selects_first_match_only_after_navigation() {
        let adapter = MockTerminalAdapter()
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

        runtime.showSearch()
        runtime.updateSearchNeedle("ansible")
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneView.searchHUDCountTextForTesting, "-/1")

        runtime.findNext()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneView.searchHUDCountTextForTesting, "1/1")
    }

    func test_search_hud_navigation_buttons_trigger_runtime_search_navigation() {
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

        runtime.showSearch()
        runtime.updateSearchNeedle("ansible")
        paneView.layoutSubtreeIfNeeded()

        paneView.searchHUDNextButtonForTesting.performClick(paneView)
        paneView.searchHUDPreviousButtonForTesting.performClick(paneView)

        XCTAssertEqual(
            adapter.bindingActions,
            ["showSearch", "updateSearch:ansible", "navigate_search:next", "navigate_search:previous"]
        )
    }

    func test_search_hud_buttons_are_clickable_controls() {
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        XCTAssertTrue(paneView.searchHUDCloseButtonForTesting.acceptsFirstMouse(for: nil))
        XCTAssertFalse(paneView.searchHUDCloseButtonForTesting.mouseDownCanMoveWindow)
        XCTAssertTrue(paneView.searchHUDNextButtonForTesting.acceptsFirstMouse(for: nil))
        XCTAssertFalse(paneView.searchHUDNextButtonForTesting.mouseDownCanMoveWindow)
        XCTAssertTrue(paneView.searchHUDPreviousButtonForTesting.acceptsFirstMouse(for: nil))
        XCTAssertFalse(paneView.searchHUDPreviousButtonForTesting.mouseDownCanMoveWindow)
    }

    func test_search_hud_hit_testing_prefers_controls_over_drag_background() {
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        let closePoint = paneView.convert(
            CGPoint(
                x: paneView.searchHUDCloseButtonForTesting.bounds.midX,
                y: paneView.searchHUDCloseButtonForTesting.bounds.midY
            ),
            from: paneView.searchHUDCloseButtonForTesting
        )
        let fieldPoint = paneView.convert(
            CGPoint(
                x: paneView.searchHUDQueryFieldForTesting.bounds.midX,
                y: paneView.searchHUDQueryFieldForTesting.bounds.midY
            ),
            from: paneView.searchHUDQueryFieldForTesting
        )

        XCTAssertTrue(paneView.hitTest(closePoint) === paneView.searchHUDCloseButtonForTesting)
        XCTAssertTrue(paneView.hitTest(fieldPoint) === paneView.searchHUDQueryFieldForTesting)
    }

    func test_search_hud_release_animates_to_snapped_corner_before_committing_corner_state() {
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

        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        let displacedOrigin = CGPoint(x: 24, y: 18)
        var capturedTargetOrigin: CGPoint?
        var snapCompletion: (() -> Void)?
        paneView.configureSearchHUDSnapAnimationForTesting { targetOrigin, completion in
            capturedTargetOrigin = targetOrigin
            snapCompletion = completion
        }
        paneView.setSearchHUDOriginForTesting(displacedOrigin)

        paneView.snapSearchHUDToNearestCornerForTesting()

        XCTAssertEqual(capturedTargetOrigin, paneView.searchHUDFrame(for: .bottomLeading).origin)
        XCTAssertEqual(paneView.searchHUDFrameForTesting.origin, displacedOrigin)
        XCTAssertTrue(paneView.isSearchHUDSnapAnimationInFlightForTesting)
        XCTAssertEqual(runtime.snapshot.search.hudCorner, .topTrailing)

        snapCompletion?()

        XCTAssertEqual(paneView.searchHUDFrameForTesting.origin, capturedTargetOrigin)
        XCTAssertFalse(paneView.isSearchHUDSnapAnimationInFlightForTesting)
        XCTAssertEqual(runtime.snapshot.search.hudCorner, .bottomLeading)
    }

    func test_search_hud_close_button_receives_real_window_clicks() throws {
        let terminalView = MouseTrackingTerminalView()
        let adapter = PaneContainerTerminalAdapterSpy(terminalView: terminalView)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }

        window.contentView = paneView
        window.makeKeyAndOrderFront(nil)
        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let clickPoint = paneView.convert(
            CGPoint(
                x: paneView.searchHUDCloseButtonForTesting.bounds.midX,
                y: paneView.searchHUDCloseButtonForTesting.bounds.midY
            ),
            from: paneView.searchHUDCloseButtonForTesting
        )

        try sendMouseClick(at: clickPoint, in: paneView, window: window)

        XCTAssertEqual(adapter.bindingActions.last, "endSearch")
        XCTAssertEqual(terminalView.mouseDownCount, 0)
        XCTAssertEqual(terminalView.mouseDraggedCount, 0)
    }

}

private enum TestError: Error {
    case startupFailed
}

@MainActor
private final class PaneContainerTerminalAdapterSpy: TerminalAdapter, TerminalSearchControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private let terminalView: NSView
    private var startSessionFailures: [Error]
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity()
    private(set) var bindingActions: [String] = []

    init(startSessionFailures: [Error] = [], terminalView: NSView = NSView()) {
        self.startSessionFailures = startSessionFailures
        self.terminalView = terminalView
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

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }

    func showSearch() {
        bindingActions.append("showSearch")
        searchDidChange?(.started(needle: nil))
    }

    func useSelectionForFind() {
        bindingActions.append("useSelectionForFind")
        searchDidChange?(.started(needle: nil))
    }

    func updateSearch(needle: String) {
        bindingActions.append("updateSearch:\(needle)")
    }

    func findNext() {
        bindingActions.append("navigate_search:next")
    }

    func findPrevious() {
        bindingActions.append("navigate_search:previous")
    }

    func endSearch() {
        bindingActions.append("endSearch")
        searchDidChange?(.ended)
    }
}

@MainActor
private final class MouseTrackingTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var mouseDownCount = 0
    private(set) var mouseDraggedCount = 0

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

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDraggedCount += 1
    }
}

@MainActor
private final class OverlayHostingTerminalView: NSView, TerminalFocusReporting, TerminalOverlayHosting {
    let overlayHostView = NSView()
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var mouseInteractionSuppressionRects: [CGRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlayHostView.translatesAutoresizingMaskIntoConstraints = true
        overlayHostView.autoresizingMask = [.width, .height]
        overlayHostView.frame = bounds
        addSubview(overlayHostView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    var terminalOverlayHostView: NSView {
        overlayHostView
    }
}

extension OverlayHostingTerminalView: TerminalMouseInteractionSuppressionControlling {
    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        mouseInteractionSuppressionRects = rects
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

private func sendMouseClick(at point: CGPoint, in view: NSView, window: NSWindow) throws {
    let locationInWindow = view.convert(point, to: nil)
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )

    // NSButton enters a modal tracking loop on mouseDown and waits for the matching mouseUp.
    // Queue the release first so the tracking loop can consume it and return.
    NSApp.postEvent(mouseUp, atStart: false)
    window.sendEvent(mouseDown)
}
