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
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        hostView.applyScrollbarUpdate(.init(total: 200, offset: 180, len: 10))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)
    }

    func test_scrollbar_update_follows_when_user_scrolled_away_during_active_selection_drag() throws {
        let harness = makeScrollHostHarness()
        let hostView = harness.hostView
        let surfaceView = harness.surfaceView
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 190, len: 10))

        let scrollView = try scrollView(from: hostView)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        surfaceView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, location: CGPoint(x: 120, y: 159)))
        hostView.applyScrollbarUpdate(.init(total: 200, offset: 180, len: 10))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 160, accuracy: 0.01)
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
}

@MainActor
private func makeScrollHostHarness() -> (
    surfaceView: LibghosttyView,
    surface: ScrollHostSurfaceSpy,
    hostView: LibghosttySurfaceScrollHostView
) {
    let surfaceView = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
    let surface = ScrollHostSurfaceSpy()
    surfaceView.bind(surfaceController: surface)
    let hostView = LibghosttySurfaceScrollHostView(
        surfaceView: surfaceView,
        paneID: PaneID("test-pane"),
        diagnostics: .shared
    )
    hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
    hostView.layoutSubtreeIfNeeded()
    return (surfaceView, surface, hostView)
}

private final class ScrollHostSurfaceSpy: LibghosttySurfaceControlling {
    struct MouseButtonEvent: Equatable {
        let state: ghostty_input_mouse_state_e
        let button: ghostty_input_mouse_button_e
        let modifiers: NSEvent.ModifierFlags
    }

    var hasScrollback = true
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var mouseButtons: [MouseButtonEvent] = []
    private(set) var sentMousePositions: [(position: CGPoint, modifiers: NSEvent.ModifierFlags)] = []
    var mouseButtonResults: [ghostty_input_mouse_button_e: Bool] = [:]

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
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
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}

@MainActor
private final class HitTestableOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
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
