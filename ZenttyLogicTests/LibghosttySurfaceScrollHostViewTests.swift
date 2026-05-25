import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttySurfaceScrollHostViewTests: AppKitTestCase {
    func test_scrollbar_update_does_not_follow_when_user_scrolled_away_without_active_selection_drag() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 160))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 185, len: 10))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 160, accuracy: 0.01)
    }

    func test_scrollbar_update_follows_when_user_scrolled_away_during_active_selection_drag() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surfaceView = harness.surfaceView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 160))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        surfaceView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 120, y: 159)))
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 185, len: 10))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 80, accuracy: 0.01)
    }

    func test_bottom_reflect_notification_does_not_mark_user_scrolled_away() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        let hostView = harness.hostView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: hostView)

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 180, len: 10))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 160, accuracy: 0.01)
    }

    func test_fractional_scrollbar_update_maps_to_fractional_scroll_origin_when_enabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        let hostView = harness.hostView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))

        let scrollView = try scrollView(from: hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
    }

    func test_retina_fractional_scrollbar_update_uses_point_row_height() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 2,
            cellHeight: 32
        )
        let hostView = harness.hostView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))

        let scrollView = try scrollView(from: hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 172, accuracy: 0.01)
    }

    func test_fractional_scrollbar_update_snaps_to_row_when_disabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: false)
        let hostView = harness.hostView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))

        let scrollView = try scrollView(from: hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 176, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 176, accuracy: 0.01)
    }

    func test_live_scroll_sends_fractional_scroll_offset() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        let hostView = harness.hostView
        let surface = harness.surface
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 172))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        XCTAssertEqual(surface.sentScrollOffsets, [179.25])
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
        XCTAssertEqual(surface.bindingActions, [])
    }

    func test_live_scroll_sends_integral_scroll_offset_by_default() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surface = harness.surface
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 172))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        XCTAssertEqual(surface.sentScrollOffsets, [179])
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 176, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 176, accuracy: 0.01)
        XCTAssertEqual(surface.bindingActions, [])
    }

    func test_live_scroll_bounds_snap_to_row_by_default() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 172))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 176, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 176, accuracy: 0.01)
    }

    func test_live_scroll_bounds_stay_fractional_when_enabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        let hostView = harness.hostView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 172))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 172, accuracy: 0.01)
    }

    func test_disabling_smooth_scrolling_snaps_current_fractional_scroll_to_row() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        let hostView = harness.hostView
        let surface = harness.surface
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 172))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        hostView.smoothScrollingEnabled = false

        XCTAssertEqual(surface.sentScrollOffsets, [179.25, 179])
        XCTAssertEqual(
            surface.events.suffix(2),
            [.scrollToOffset(179), .setSmoothScrollingEnabled(false)]
        )
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 176, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 176, accuracy: 0.01)
    }

    func test_live_scroll_snaps_tiny_bottom_gap_to_scrollbar_bottom() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surface = harness.surface
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 189, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 4))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        XCTAssertEqual(surface.sentScrollOffsets, [190])
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(surface.bindingActions, [])
    }

    func test_scrollbar_update_resends_top_edge_position_in_ghostty_coordinates() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surface = harness.surface
        let surfaceView = harness.surfaceView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        surfaceView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 120, y: 159)))

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 180, len: 10))

        XCTAssertEqual(surface.sentMousePositions.last?.position, CGPoint(x: 120, y: 1))
    }

    func test_scrollbar_update_resends_bottom_edge_position_in_ghostty_coordinates() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surface = harness.surface
        let surfaceView = harness.surfaceView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 100, len: 10))
        surfaceView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 120, y: 1)))

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 110, len: 10))

        XCTAssertEqual(surface.sentMousePositions.last?.position, CGPoint(x: 120, y: 159))
    }

    func test_scrollbar_update_resends_last_real_drag_position_when_pointer_has_left_edge_zone() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surface = harness.surface
        let surfaceView = harness.surfaceView

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        surfaceView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 120, y: 159)))
        surfaceView.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, location: CGPoint(x: 120, y: 80)))

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 180, len: 10))

        XCTAssertEqual(surface.sentMousePositions.last?.position, CGPoint(x: 120, y: 80))
    }

    func test_scroll_view_right_click_forwards_to_surface_context_menu() throws {
        let harness = makeScrollHostHarness()
        let scrollView = try scrollView(from: harness.hostView)
        var builderCallCount = 0
        var presentationCount = 0
        harness.surfaceView.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            let menu = NSMenu(title: "")
            menu.addItem(withTitle: "Add Pane Up", action: nil, keyEquivalent: "")
            return menu
        }
        harness.surfaceView.contextMenuPresenter = { _, _, _ in
            presentationCount += 1
        }

        let event = try makeMouseEvent(type: .rightMouseDown, location: CGPoint(x: 120, y: 80))

        scrollView.rightMouseDown(with: event)

        XCTAssertEqual(harness.surface.mouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(harness.surface.mouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(presentationCount, 1)
    }

    func test_scroll_host_right_click_forwards_to_surface_context_menu() throws {
        let harness = makeScrollHostHarness()
        var builderCallCount = 0
        var presentationCount = 0
        harness.surfaceView.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            let menu = NSMenu(title: "")
            menu.addItem(withTitle: "Add Pane Up", action: nil, keyEquivalent: "")
            return menu
        }
        harness.surfaceView.contextMenuPresenter = { _, _, _ in
            presentationCount += 1
        }

        let event = try makeMouseEvent(type: .rightMouseDown, location: CGPoint(x: 120, y: 80))

        harness.hostView.rightMouseDown(with: event)

        XCTAssertEqual(harness.surface.mouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(harness.surface.mouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(presentationCount, 1)
    }

    func test_scroll_view_right_click_does_not_present_context_menu_when_surface_consumes_event() throws {
        let harness = makeScrollHostHarness()
        let scrollView = try scrollView(from: harness.hostView)
        var builderCallCount = 0
        var presentationCount = 0
        harness.surface.mouseButtonResults[GHOSTTY_MOUSE_RIGHT] = true
        harness.surfaceView.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            return NSMenu(title: "")
        }
        harness.surfaceView.contextMenuPresenter = { _, _, _ in
            presentationCount += 1
        }

        let event = try makeMouseEvent(type: .rightMouseDown, location: CGPoint(x: 120, y: 80))

        scrollView.rightMouseDown(with: event)

        XCTAssertEqual(harness.surface.mouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(harness.surface.mouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertEqual(builderCallCount, 0)
        XCTAssertEqual(presentationCount, 0)
    }

    func test_scroll_view_control_secondary_drag_forwards_to_surface() throws {
        let harness = makeScrollHostHarness()
        let scrollView = try scrollView(from: harness.hostView)
        harness.surface.mouseButtonResults[GHOSTTY_MOUSE_LEFT] = true

        scrollView.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 80),
            modifierFlags: [.control]
        ))
        scrollView.rightMouseDragged(with: try makeMouseEvent(
            type: .rightMouseDragged,
            location: CGPoint(x: 150, y: 90),
            modifierFlags: [.control]
        ))

        XCTAssertEqual(harness.surface.mouseButtons.last?.button, GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(harness.surface.sentMousePositions.last?.position, CGPoint(x: 150, y: 70))
    }

    func test_overlay_host_hit_testing_passes_through_to_terminal_when_empty() throws {
        let harness = makeScrollHostHarness()

        let hitView = try XCTUnwrap(harness.hostView.hitTest(CGPoint(x: 120, y: 80)))

        XCTAssertFalse(hitView === harness.hostView.terminalOverlayHostView)
        XCTAssertTrue(hitView === harness.surfaceView || hitView.isDescendant(of: harness.surfaceView))
    }

    func test_overlay_host_hit_testing_preserves_interactive_overlay_subviews() throws {
        let harness = makeScrollHostHarness()
        let overlayControl = HitTestableOverlayView(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
        harness.hostView.terminalOverlayHostView.addSubview(overlayControl)

        let hitView = harness.hostView.hitTest(CGPoint(x: 30, y: 30))

        XCTAssertTrue(hitView === overlayControl)
    }

    func test_overlay_host_hit_testing_preserves_standard_controls_using_appkit_coordinates() throws {
        let harness = makeScrollHostHarness()
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
        harness.hostView.terminalOverlayHostView.addSubview(button)

        let hitView = harness.hostView.hitTest(CGPoint(x: 30, y: 30))

        XCTAssertTrue(hitView === button || hitView?.isDescendant(of: button) == true)
    }

    func test_context_menu_builder_set_on_scroll_host_reaches_surface_view() {
        let harness = makeScrollHostHarness()
        var builderCalled = false

        (harness.hostView as TerminalContextMenuConfiguring).contextMenuBuilder = { _, _ in
            builderCalled = true
            return NSMenu(title: "")
        }

        XCTAssertNotNil(harness.surfaceView.contextMenuBuilder)

        _ = harness.surfaceView.contextMenuBuilder?(
            NSEvent(),
            nil
        )
        XCTAssertTrue(builderCalled)
    }

    func test_smooth_scrolling_setting_is_forwarded_to_surface() {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: false)

        XCTAssertEqual(harness.surface.smoothScrollingEnabledUpdates, [false])

        harness.hostView.smoothScrollingEnabled = true
        harness.hostView.smoothScrollingEnabled = false

        XCTAssertEqual(harness.surface.smoothScrollingEnabledUpdates, [false, true, false])
    }

    func test_smooth_scrolling_enables_native_vertical_elasticity() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: false)
        let scrollView = try scrollView(from: harness.hostView)

        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)

        harness.hostView.smoothScrollingEnabled = true

        XCTAssertEqual(scrollView.verticalScrollElasticity, .allowed)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    }

    func test_surface_scroll_falls_through_to_native_scroll_when_smooth_enabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))

        harness.surfaceView.scrollWheel(with: try makeScrollEvent(deltaY: 8, precise: true))

        XCTAssertTrue(harness.surface.sentScrollOffsets.isEmpty)
        XCTAssertEqual(harness.surface.sentScrollEvents.count, 0)
    }

    func test_terminal_input_scroll_is_sent_to_surface_even_when_smooth_enabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.surface.mouseScrollIsTerminalInput = true
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))

        harness.surfaceView.scrollWheel(with: try makeScrollEvent(deltaY: 8, precise: true))

        XCTAssertTrue(harness.surface.sentScrollOffsets.isEmpty)
        XCTAssertEqual(harness.surface.sentScrollEvents.count, 1)
    }

    func test_scroll_is_sent_to_surface_when_smooth_scrolling_is_disabled() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: false)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))

        harness.surfaceView.scrollWheel(with: try makeScrollEvent(deltaY: 8, precise: true))

        XCTAssertTrue(harness.surface.sentScrollOffsets.isEmpty)
        XCTAssertEqual(harness.surface.sentScrollEvents.count, 1)
    }

    func test_smooth_live_scroll_sends_negative_top_elastic_offset() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        let topOrigin = scrollView.contentView.bounds.origin.y

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: topOrigin + 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        XCTAssertEqual(try XCTUnwrap(harness.surface.sentScrollOffsets.last), -0.575, accuracy: 0.001)
    }

    func test_smooth_live_scroll_sends_above_bottom_elastic_offset() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: -8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        XCTAssertEqual(try XCTUnwrap(harness.surface.sentScrollOffsets.last), 190.575, accuracy: 0.001)
    }

    func test_smooth_backing_metrics_change_reanchors_bottom_from_scrollbar() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        harness.surfaceView.viewDidChangeBackingProperties()
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 800))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        harness.surfaceView.applyCellSizeUpdate(width: 10, height: 20)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 0, accuracy: 0.01)
    }

    func test_smooth_backing_metrics_change_preserves_fractional_scrollbar_offset() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        harness.surfaceView.viewDidChangeBackingProperties()
        harness.surfaceView.applyCellSizeUpdate(width: 10, height: 20)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 215, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 215, accuracy: 0.01)
    }

    func test_smooth_backing_scale_change_preserves_point_space_scroll_origin() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)

        harness.surfaceView.layer?.contentsScale = 2
        harness.surface.cellHeight = 32
        harness.surfaceView.viewDidChangeBackingProperties()
        waitForMainQueue()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 172, accuracy: 0.01)
    }

    func test_smooth_backing_scale_change_uses_previous_point_cell_height_until_metrics_refresh() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 2,
            cellHeight: 32
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 179.25, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)

        harness.surfaceView.layer?.contentsScale = 1
        harness.surfaceView.viewDidChangeBackingProperties()
        waitForMainQueue()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 172, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 172, accuracy: 0.01)
    }

    func test_smooth_backing_cell_size_update_preserves_bottom_pin() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 2,
            cellHeight: 32
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        harness.surfaceView.layer?.contentsScale = 1
        harness.surfaceView.viewDidChangeBackingProperties()
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 160))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        harness.surfaceView.applyCellSizeUpdate(width: 8, height: 16)
        harness.hostView.applyScrollbarUpdate(.init(total: 210, offset: 200, len: 10))

        XCTAssertTrue(harness.surface.bindingActions.contains("scroll_to_bottom"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
    }

    func test_smooth_backing_cell_size_cycle_preserves_bottom_pin() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 1,
            cellHeight: 16
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        harness.surfaceView.layer?.contentsScale = 2
        harness.surfaceView.viewDidChangeBackingProperties()
        harness.surfaceView.applyCellSizeUpdate(width: 16, height: 32)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        harness.surfaceView.layer?.contentsScale = 1
        harness.surfaceView.viewDidChangeBackingProperties()
        harness.surfaceView.applyCellSizeUpdate(width: 8, height: 16)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        XCTAssertTrue(harness.surface.bindingActions.contains("scroll_to_bottom"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 0, accuracy: 0.01)
    }

    func test_smooth_backing_change_preserves_bottom_pin_after_appkit_prepositions_clip_view() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 1,
            cellHeight: 16
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 800))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        harness.surfaceView.layer?.contentsScale = 2
        harness.surfaceView.viewDidChangeBackingProperties()
        harness.surfaceView.applyCellSizeUpdate(width: 16, height: 32)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        XCTAssertTrue(harness.surface.bindingActions.contains("scroll_to_bottom"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(harness.surfaceView.frame.origin.y, 0, accuracy: 0.01)
    }

    func test_smooth_backing_cell_size_update_does_not_force_bottom_when_scrolled_away() throws {
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            backingScale: 2,
            cellHeight: 32
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 160))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)

        harness.surfaceView.layer?.contentsScale = 1
        harness.surfaceView.viewDidChangeBackingProperties()
        harness.surfaceView.applyCellSizeUpdate(width: 8, height: 16)
        harness.hostView.applyScrollbarUpdate(.init(total: 210, offset: 200, len: 10))

        XCTAssertFalse(harness.surface.bindingActions.contains("scroll_to_bottom"))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 160, accuracy: 0.01)
    }

    func test_smooth_backing_metrics_change_stops_live_scroll_sampler() throws {
        let sampler = ScrollFrameSamplerSpy()
        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            scrollFrameSampler: sampler,
            frameMeterSampler: frameMeterSampler
        )
        let scrollView = try scrollView(from: harness.hostView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)

        harness.surfaceView.viewDidChangeBackingProperties()
        waitForMainQueue()

        XCTAssertEqual(sampler.stopCallCount, 1)
    }

    func test_smooth_live_scroll_starts_display_synced_sampler() throws {
        let sampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true, scrollFrameSampler: sampler)
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)

        XCTAssertEqual(sampler.startCalls.count, 1)
        XCTAssertTrue(sampler.startCalls[0].view === harness.surfaceView)
        XCTAssertGreaterThan(sampler.startCalls[0].preferredFramesPerSecond, 0)
    }

    func test_row_snapped_live_scroll_does_not_start_sampler() throws {
        let sampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(smoothScrollingEnabled: false, scrollFrameSampler: sampler)
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)

        XCTAssertTrue(sampler.startCalls.isEmpty)
    }

    func test_smooth_sampler_continues_until_scroll_settles_in_bounds() throws {
        let sampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true, scrollFrameSampler: sampler)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        sampler.triggerFrame()
        sampler.triggerFrame()
        sampler.triggerFrame()

        XCTAssertEqual(sampler.stopCallCount, 1)
    }

    func test_smooth_sampler_dedupes_identical_offsets() throws {
        let sampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true, scrollFrameSampler: sampler)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        let topOrigin = scrollView.contentView.bounds.origin.y
        let startCount = harness.surface.sentScrollOffsets.count

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: topOrigin + 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sampler.triggerFrame()
        sampler.triggerFrame()

        XCTAssertEqual(harness.surface.sentScrollOffsets.count - startCount, 1)
    }

    func test_smooth_sampler_sends_renderable_subpixel_offset_changes() throws {
        let sampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true, scrollFrameSampler: sampler)
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))
        let scrollView = try scrollView(from: harness.hostView)
        let topOrigin = scrollView.contentView.bounds.origin.y
        let startCount = harness.surface.sentScrollOffsets.count

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: topOrigin + 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sampler.triggerFrame()
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: topOrigin + 8.5))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sampler.triggerFrame()

        XCTAssertEqual(harness.surface.sentScrollOffsets.count - startCount, 2)
    }

    func test_smooth_sampler_records_terminal_frame_meter_sample_when_enabled() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let sampler = ScrollFrameSamplerSpy()
        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            scrollFrameSampler: sampler,
            frameMeterSampler: frameMeterSampler
        )
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollView.contentView.bounds.origin.y + 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sampler.triggerFrame()

        let samples = TerminalFrameMeter.shared.samplesForTesting()
        XCTAssertEqual(samples.map(\.sampleKind), [.offset, .sent])
        XCTAssertEqual(samples.last?.paneID, PaneID("test-pane"))
        XCTAssertEqual(samples.last?.rowOffset ?? 0, 189.5, accuracy: 0.001)
        XCTAssertGreaterThan(samples.last?.preferredFramesPerSecond ?? 0, 0)
    }

    func test_terminal_frame_meter_tracks_tick_offset_and_sent_frame_rates_separately() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let paneID = PaneID("meter-pane")
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10.25,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .offset,
            pacingMode: .appKitDisplayLink
        )
        let snapshot = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10.25,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .sent,
            pacingMode: .appKitDisplayLink
        )

        let tickFPS = try XCTUnwrap(snapshot?.tickFramesPerSecond)
        let offsetFPS = try XCTUnwrap(snapshot?.offsetFramesPerSecond)
        let sentFPS = try XCTUnwrap(snapshot?.sentFramesPerSecond)
        XCTAssertGreaterThan(tickFPS, sentFPS)
        XCTAssertEqual(offsetFPS, sentFPS, accuracy: 0.001)
        XCTAssertEqual(snapshot?.pacingMode, .appKitDisplayLink)
    }

    func test_terminal_frame_meter_records_tick_history_and_dip_markers() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.clearNowForTesting()
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let paneID = PaneID("history-pane")
        TerminalFrameMeter.shared.setNowForTesting(0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(1.0 / 120.0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting((1.0 / 120.0) + (1.0 / 30.0))
        let snapshot = try XCTUnwrap(TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        ))

        XCTAssertEqual(snapshot.historyPoints.count, 3)
        XCTAssertNil(snapshot.historyPoints[0].framesPerSecond)
        XCTAssertEqual(try XCTUnwrap(snapshot.historyPoints[1].framesPerSecond), 120, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.historyPoints[2].framesPerSecond), 30, accuracy: 0.001)
        XCTAssertFalse(snapshot.historyPoints[1].isDip)
        XCTAssertTrue(snapshot.historyPoints[2].isDip)
    }

    func test_terminal_frame_meter_treats_minor_high_refresh_jitter_as_stable() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.clearNowForTesting()
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let paneID = PaneID("stable-history-pane")
        TerminalFrameMeter.shared.setNowForTesting(0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(1.0 / 113.0)
        let snapshot = try XCTUnwrap(TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        ))

        XCTAssertEqual(snapshot.historyPoints.count, 2)
        XCTAssertEqual(try XCTUnwrap(snapshot.historyPoints[1].framesPerSecond), 113, accuracy: 0.001)
        XCTAssertEqual(snapshot.historyPoints[1].severity, .stable)
        XCTAssertFalse(snapshot.historyPoints[1].isDip)
    }

    func test_terminal_frame_meter_marks_orange_below_half_and_red_below_thirty_percent() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.clearNowForTesting()
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let paneID = PaneID("severity-history-pane")
        TerminalFrameMeter.shared.setNowForTesting(0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(1.0 / 90.0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting((1.0 / 90.0) + (1.0 / 59.0))
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting((1.0 / 90.0) + (1.0 / 59.0) + (1.0 / 35.0))
        let snapshot = try XCTUnwrap(TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        ))

        XCTAssertEqual(snapshot.historyPoints.map(\.severity), [.stable, .stable, .warning, .critical])
        XCTAssertEqual(snapshot.historyPoints.filter(\.isDip).count, 2)
    }

    func test_terminal_frame_meter_hud_marks_orange_below_half_and_red_below_thirty_percent() throws {
        let hudView = TerminalFrameMeterHUDView(frame: NSRect(x: 0, y: 0, width: 128, height: 48))
        hudView.update(with: TerminalFrameMeter.Snapshot(
            paneID: PaneID("hud-severity-pane"),
            tickFramesPerSecond: 90,
            offsetFramesPerSecond: nil,
            sentFramesPerSecond: nil,
            preferredFramesPerSecond: 120,
            lateFrameRatio: 0,
            maxDeltaMilliseconds: nil,
            rowOffset: 0,
            displayID: nil,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink,
            historyPoints: []
        ))
        XCTAssertEqual(hudView.snapshotForTesting.severity, .stable)

        hudView.update(with: TerminalFrameMeter.Snapshot(
            paneID: PaneID("hud-severity-pane"),
            tickFramesPerSecond: 59,
            offsetFramesPerSecond: nil,
            sentFramesPerSecond: nil,
            preferredFramesPerSecond: 120,
            lateFrameRatio: 0,
            maxDeltaMilliseconds: nil,
            rowOffset: 0,
            displayID: nil,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink,
            historyPoints: []
        ))
        XCTAssertEqual(hudView.snapshotForTesting.severity, .warning)

        hudView.update(with: TerminalFrameMeter.Snapshot(
            paneID: PaneID("hud-severity-pane"),
            tickFramesPerSecond: 35,
            offsetFramesPerSecond: nil,
            sentFramesPerSecond: nil,
            preferredFramesPerSecond: 120,
            lateFrameRatio: 0,
            maxDeltaMilliseconds: nil,
            rowOffset: 0,
            displayID: nil,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink,
            historyPoints: []
        ))
        XCTAssertEqual(hudView.snapshotForTesting.severity, .critical)
    }

    func test_terminal_frame_meter_hud_graph_smooths_single_frame_warning_spikes() throws {
        let hudView = TerminalFrameMeterHUDView(frame: NSRect(x: 0, y: 0, width: 128, height: 48))
        hudView.update(with: TerminalFrameMeter.Snapshot(
            paneID: PaneID("hud-smoothed-history-pane"),
            tickFramesPerSecond: 92,
            offsetFramesPerSecond: nil,
            sentFramesPerSecond: nil,
            preferredFramesPerSecond: 120,
            lateFrameRatio: 0.37,
            maxDeltaMilliseconds: nil,
            rowOffset: 0,
            displayID: nil,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink,
            historyPoints: [
                .init(timestamp: 0, framesPerSecond: nil, severity: .stable),
                .init(timestamp: 1.0 / 120.0, framesPerSecond: 120, severity: .stable),
                .init(timestamp: 1.0 / 120.0 + 1.0 / 45.0, framesPerSecond: 45, severity: .warning)
            ]
        ))

        let snapshot = hudView.snapshotForTesting
        XCTAssertEqual(snapshot.severity, .stable)
        XCTAssertEqual(snapshot.graphWarningCount, 0)
        XCTAssertEqual(snapshot.graphCriticalCount, 0)
    }

    func test_terminal_frame_meter_history_ignores_non_tick_samples_and_prunes_to_recent_window() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.clearNowForTesting()
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let paneID = PaneID("pruned-history-pane")
        TerminalFrameMeter.shared.setNowForTesting(0)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(1)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(1.5)
        _ = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10.25,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: true,
            sampleKind: .sent,
            pacingMode: .appKitDisplayLink
        )
        TerminalFrameMeter.shared.setNowForTesting(6.25)
        let snapshot = try XCTUnwrap(TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: 10.5,
            preferredFramesPerSecond: 120,
            displayID: 42,
            isLiveScrolling: false,
            sampleKind: .tick,
            pacingMode: .appKitDisplayLink
        ))

        XCTAssertEqual(snapshot.historyPoints.map(\.timestamp), [6.25])
        XCTAssertEqual(TerminalFrameMeter.shared.samplesForTesting().map(\.sampleKind), [.tick, .tick, .sent, .tick])
    }

    func test_terminal_frame_meter_hud_is_small_and_updates_when_enabled() throws {
        TerminalFrameMeter.shared.resetForTesting()
        TerminalFrameMeter.shared.isEnabled = true
        addTeardownBlock {
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let sampler = ScrollFrameSamplerSpy()
        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            scrollFrameSampler: sampler,
            frameMeterSampler: frameMeterSampler
        )
        harness.hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        harness.hostView.layoutSubtreeIfNeeded()
        XCTAssertFalse(harness.hostView.debugFrameMeterHUDSnapshotForTesting.isHidden)

        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        let scrollView = try scrollView(from: harness.hostView)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollView.contentView.bounds.origin.y + 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sampler.triggerFrame()

        let snapshot = harness.hostView.debugFrameMeterHUDSnapshotForTesting
        XCTAssertFalse(snapshot.isHidden)
        XCTAssertEqual(snapshot.frame.width, 128)
        XCTAssertEqual(snapshot.frame.height, 48)
        XCTAssertGreaterThan(snapshot.frame.minX, 660)
        XCTAssertGreaterThan(snapshot.frame.minY, 430)
        XCTAssertTrue(snapshot.primaryText.hasPrefix("FPS"))
        XCTAssertTrue(snapshot.primaryText.contains("/"))
        XCTAssertTrue(snapshot.secondaryText.contains("sent"))
        XCTAssertTrue(snapshot.secondaryText.contains("late"))
    }

    func test_terminal_frame_meter_hud_shows_when_enabled_before_scrolling() throws {
        TerminalFrameMeter.shared.resetForTesting()
        addTeardownBlock {
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            frameMeterSampler: frameMeterSampler
        )
        XCTAssertTrue(harness.hostView.debugFrameMeterHUDSnapshotForTesting.isHidden)

        TerminalFrameMeter.shared.isEnabled = true

        let snapshot = harness.hostView.debugFrameMeterHUDSnapshotForTesting
        XCTAssertFalse(snapshot.isHidden)
        XCTAssertEqual(snapshot.primaryText, "FPS --")
        XCTAssertEqual(snapshot.severity, .stable)
        XCTAssertEqual(frameMeterSampler.startCalls.count, 1)
        XCTAssertTrue(frameMeterSampler.startCalls[0].view === harness.surfaceView)
    }

    func test_terminal_frame_meter_records_display_ticks_without_scrolling() throws {
        TerminalFrameMeter.shared.resetForTesting()
        addTeardownBlock {
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            frameMeterSampler: frameMeterSampler
        )

        TerminalFrameMeter.shared.isEnabled = true
        frameMeterSampler.triggerFrame()

        let samples = TerminalFrameMeter.shared.samplesForTesting()
        XCTAssertEqual(samples.map(\.sampleKind), [.tick])
        XCTAssertEqual(samples[0].pacingMode, .appKitDisplayLink)
        XCTAssertTrue(harness.hostView.debugFrameMeterHUDSnapshotForTesting.primaryText.hasPrefix("FPS"))
    }

    func test_terminal_frame_meter_hud_graph_receives_history_after_display_ticks() throws {
        TerminalFrameMeter.shared.resetForTesting()
        addTeardownBlock {
            TerminalFrameMeter.shared.clearNowForTesting()
            TerminalFrameMeter.shared.isEnabled = false
            TerminalFrameMeter.shared.resetForTesting()
        }

        let frameMeterSampler = ScrollFrameSamplerSpy()
        let harness = makeScrollHostHarness(
            smoothScrollingEnabled: true,
            frameMeterSampler: frameMeterSampler
        )

        TerminalFrameMeter.shared.setNowForTesting(0)
        TerminalFrameMeter.shared.isEnabled = true
        frameMeterSampler.triggerFrame()
        TerminalFrameMeter.shared.setNowForTesting(1.0 / 120.0)
        frameMeterSampler.triggerFrame()
        TerminalFrameMeter.shared.setNowForTesting((1.0 / 120.0) + (1.0 / 30.0))
        frameMeterSampler.triggerFrame()
        TerminalFrameMeter.shared.setNowForTesting((1.0 / 120.0) + (1.0 / 30.0) + (1.0 / 30.0))
        frameMeterSampler.triggerFrame()

        let snapshot = harness.hostView.debugFrameMeterHUDSnapshotForTesting
        XCTAssertEqual(snapshot.graphPointCount, 4)
        XCTAssertEqual(snapshot.graphWarningCount, 0)
        XCTAssertEqual(snapshot.graphCriticalCount, 1)
        XCTAssertEqual(snapshot.severity, .warning)
    }

    func test_pane_scroll_routing_wins_before_native_scroll() throws {
        let harness = makeScrollHostHarness(smoothScrollingEnabled: true)
        var routedCount = 0
        harness.hostView.onScrollWheel = { _ in
            routedCount += 1
            return true
        }
        harness.hostView.applyScrollbarUpdate(.init(total: 200, offset: 0, len: 10))

        harness.surfaceView.scrollWheel(with: try makeScrollEvent(deltaY: 8, precise: true))

        XCTAssertEqual(routedCount, 1)
        XCTAssertTrue(harness.surface.sentScrollOffsets.isEmpty)
        XCTAssertEqual(harness.surface.sentScrollEvents.count, 0)
    }
}

@MainActor
private func waitForMainQueue(
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let settled = XCTestExpectation(description: "main queue settled")
    DispatchQueue.main.async {
        settled.fulfill()
    }
    let result = XCTWaiter.wait(for: [settled], timeout: 1)
    XCTAssertEqual(result, .completed, file: file, line: line)
}

@MainActor
private func makeScrollHostHarness(
    smoothScrollingEnabled: Bool = AppConfig.Panes.default.smoothScrollingEnabled,
    scrollFrameSampler: any TerminalScrollFrameSampling = ScrollFrameSamplerSpy(),
    frameMeterSampler: (any TerminalScrollFrameSampling)? = nil,
    backingScale: CGFloat = 1,
    cellHeight: CGFloat = 16
) -> (
    surfaceView: LibghosttyView,
    surface: ScrollHostSurfaceSpy,
    hostView: LibghosttySurfaceScrollHostView
) {
    let surfaceView = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
    surfaceView.layer?.contentsScale = backingScale
    let surface = ScrollHostSurfaceSpy()
    surface.cellHeight = cellHeight
    surfaceView.bind(surfaceController: surface)
    let hostView = LibghosttySurfaceScrollHostView(
        surfaceView: surfaceView,
        paneID: PaneID("test-pane"),
        diagnostics: .shared,
        scrollFrameSampler: scrollFrameSampler,
        frameMeterSampler: frameMeterSampler
    )
    hostView.smoothScrollingEnabled = smoothScrollingEnabled
    hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
    hostView.layoutSubtreeIfNeeded()
    return (surfaceView, surface, hostView)
}

private final class ScrollHostSurfaceSpy: LibghosttySurfaceControlling {
    enum Event: Equatable {
        case setSmoothScrollingEnabled(Bool)
        case scrollToOffset(Double)
    }

    struct MouseButtonEvent: Equatable {
        let state: ghostty_input_mouse_state_e
        let button: ghostty_input_mouse_button_e
        let modifiers: NSEvent.ModifierFlags
    }

    var hasScrollback = true
    var mouseScrollIsTerminalInput = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var mouseButtons: [MouseButtonEvent] = []
    private(set) var sentMousePositions: [(position: CGPoint, modifiers: NSEvent.ModifierFlags)] = []
    private(set) var sentScrollEvents: [(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase)] = []
    private(set) var sentScrollOffsets: [Double] = []
    private(set) var smoothScrollingEnabledUpdates: [Bool] = []
    private(set) var bindingActions: [String] = []
    private(set) var events: [Event] = []
    var mouseButtonResults: [ghostty_input_mouse_button_e: Bool] = [:]

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {
        sentScrollEvents.append((x, y, precision, momentum))
    }
    func setSmoothScrollingEnabled(_ enabled: Bool) {
        smoothScrollingEnabledUpdates.append(enabled)
        events.append(.setSmoothScrollingEnabled(enabled))
    }
    func scroll(toOffset offset: Double) {
        sentScrollOffsets.append(offset)
        events.append(.scrollToOffset(offset))
    }
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {
        sentMousePositions.append((position, modifiers))
    }
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        mouseButtons.append(MouseButtonEvent(state: state, button: button, modifiers: modifiers))
        return mouseButtonResults[button] ?? false
    }
    func sendText(_ text: String) {}
    func submitReturn() {}
    func performBindingAction(_ action: String) -> Bool {
        bindingActions.append(action)
        return true
    }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}

private final class ScrollFrameSamplerSpy: TerminalScrollFrameSampling, @unchecked Sendable {
    struct StartCall: Equatable {
        weak var view: NSView?
        let preferredFramesPerSecond: Int

        static func == (lhs: StartCall, rhs: StartCall) -> Bool {
            lhs.view === rhs.view &&
                lhs.preferredFramesPerSecond == rhs.preferredFramesPerSecond
        }
    }

    var onFrame: (() -> Void)?
    private(set) var pacingMode: TerminalScrollFramePacingMode = .stopped
    private(set) var startCalls: [StartCall] = []
    private(set) var stopCallCount = 0

    func start(attachedTo view: NSView, preferredFramesPerSecond: Int) {
        pacingMode = .appKitDisplayLink
        startCalls.append(StartCall(
            view: view,
            preferredFramesPerSecond: preferredFramesPerSecond
        ))
    }

    func stop() {
        pacingMode = .stopped
        stopCallCount += 1
    }

    func triggerFrame() {
        onFrame?()
    }
}

@MainActor
private final class HitTestableOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(localPoint) ? self : nil
    }
}

private func scrollView(from hostView: LibghosttySurfaceScrollHostView) throws -> NSScrollView {
    try XCTUnwrap(hostView.subviews.compactMap { $0 as? NSScrollView }.first)
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    location: CGPoint,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try XCTUnwrap(
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
}

private func makeScrollEvent(
    deltaX: CGFloat = 0,
    deltaY: CGFloat = 0,
    precise: Bool,
    phase: NSEvent.Phase = .changed,
    momentumPhase: NSEvent.Phase = []
) throws -> NSEvent {
    MockScrollEvent(
        scrollingDeltaX: deltaX,
        scrollingDeltaY: deltaY,
        hasPreciseScrollingDeltas: precise,
        phase: phase,
        momentumPhase: momentumPhase
    )
}

private final class MockScrollEvent: NSEvent {
    private let mockedScrollingDeltaX: CGFloat
    private let mockedScrollingDeltaY: CGFloat
    private let mockedHasPreciseScrollingDeltas: Bool
    private let mockedPhase: NSEvent.Phase
    private let mockedMomentumPhase: NSEvent.Phase

    init(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) {
        self.mockedScrollingDeltaX = scrollingDeltaX
        self.mockedScrollingDeltaY = scrollingDeltaY
        self.mockedHasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.mockedPhase = phase
        self.mockedMomentumPhase = momentumPhase
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { mockedScrollingDeltaX }
    override var scrollingDeltaY: CGFloat { mockedScrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { mockedHasPreciseScrollingDeltas }
    override var phase: NSEvent.Phase { mockedPhase }
    override var momentumPhase: NSEvent.Phase { mockedMomentumPhase }
}
