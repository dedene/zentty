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
    ) {
        mouseButtons.append(MouseButtonEvent(state: state, button: button, modifiers: modifiers))
    }
    func sendText(_ text: String) {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
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
