import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewScrollRoutingTests: AppKitTestCase {
    private var view: LibghosttyView!
    private var surface: ScrollRoutingSurfaceSpy!

    override func setUp() {
        super.setUp()
        view = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        surface = ScrollRoutingSurfaceSpy()
        view.bind(surfaceController: surface)
    }

    override func tearDown() {
        view = nil
        surface = nil
        super.tearDown()
    }

    func test_handled_scroll_is_routed_outward_without_reaching_surface() throws {
        var routedEvents: [NSEvent] = []
        view.onScrollWheel = { event in
            routedEvents.append(event)
            return true
        }

        view.scrollWheel(with: try makeScrollEvent(deltaX: 60, precise: true))

        XCTAssertEqual(routedEvents.count, 1)
        XCTAssertTrue(surface.sentScrollEvents.isEmpty)
    }

    func test_unhandled_scroll_reaches_surface_controller() throws {
        view.onScrollWheel = { _ in false }

        let event = try makeScrollEvent(deltaY: 18, precise: true)
        view.scrollWheel(with: event)

        XCTAssertEqual(surface.sentScrollEvents.count, 1)
        XCTAssertEqual(surface.sentScrollEvents.first?.x, event.scrollingDeltaX)
        XCTAssertEqual(surface.sentScrollEvents.first?.y, event.scrollingDeltaY)
    }

    func test_tracking_area_is_active_always() {
        view.updateTrackingAreas()

        XCTAssertTrue(view.trackingAreas.contains { $0.options.contains(.activeAlways) })
    }

    func test_detached_view_does_not_push_viewport_size() {
        view.frame = NSRect(x: 0, y: 0, width: 3200, height: 900)

        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(surface.viewportUpdates.isEmpty)
    }

    func test_fractional_backing_jitter_does_not_push_viewport_resize() throws {
        view.frame = NSRect(x: 0, y: 0, width: 1429.5, height: 1028)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        let contentView = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1600, height: 1200))
        window.contentView = contentView
        contentView.addSubview(view)
        window.makeKeyAndOrderFrontForAppKitTesting(nil)
        view.layoutSubtreeIfNeeded()

        let scale = window.backingScaleFactor
        let stableViewport = try XCTUnwrap(surface.viewportUpdates.last?.size)

        surface.clearViewportUpdates()

        view.frame.size = NSSize(width: 1429.500004550596, height: 1028.0000008206673)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(surface.viewportUpdates.isEmpty, "Unexpected tiny jitter updates: \(surface.viewportUpdates.map(\.size))")

        view.frame.size = NSSize(width: 1429.55297, height: 1028.03809)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(surface.viewportUpdates.isEmpty, "Unexpected larger jitter updates: \(surface.viewportUpdates.map(\.size))")

        view.frame.size = NSSize(width: (stableViewport.width + 1) / scale, height: stableViewport.height / scale)
        view.layoutSubtreeIfNeeded()

        let latestViewport = try XCTUnwrap(surface.viewportUpdates.last?.size)
        XCTAssertEqual(latestViewport.width, stableViewport.width + 1, accuracy: 0.001)
        XCTAssertEqual(latestViewport.height, stableViewport.height, accuracy: 0.001)
    }

    func test_mouse_entered_forwards_local_position() throws {
        let event = try makeMouseEvent(type: .mouseEntered, location: CGPoint(x: 120, y: 180))

        view.mouseEntered(with: event)

        let position = try XCTUnwrap(surface.sentMousePositions.last?.position)
        XCTAssertEqual(position.x, 120, accuracy: 0.01)
        XCTAssertEqual(position.y, 420, accuracy: 0.01)
    }

    func test_mouse_exited_forwards_negative_position() throws {
        let event = try makeMouseEvent(type: .mouseExited, location: CGPoint(x: 120, y: 180))

        view.mouseExited(with: event)

        let position = try XCTUnwrap(surface.sentMousePositions.last?.position)
        XCTAssertEqual(position, CGPoint(x: -1, y: -1))
    }

    func test_unconsumed_right_click_requests_context_menu_presentation() throws {
        var builderCallCount = 0
        var presentedMenuTitles: [String] = []
        surface.mouseButtonResults[GHOSTTY_MOUSE_RIGHT] = false
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            let menu = NSMenu(title: "")
            menu.addItem(withTitle: "Add Pane Up", action: nil, keyEquivalent: "")
            return menu
        }
        view.contextMenuPresenter = { menu, _, _ in
            presentedMenuTitles = menu.items.map(\.title)
        }

        view.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: CGPoint(x: 120, y: 180)))

        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(presentedMenuTitles, ["Add Pane Up"])
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
    }

    func test_consumed_right_click_does_not_request_context_menu_presentation() throws {
        var builderCallCount = 0
        var presentationCount = 0
        surface.mouseButtonResults[GHOSTTY_MOUSE_RIGHT] = true
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            return NSMenu(title: "")
        }
        view.contextMenuPresenter = { _, _, _ in
            presentationCount += 1
        }

        view.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, location: CGPoint(x: 120, y: 180)))

        XCTAssertEqual(builderCallCount, 0)
        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
    }

    func test_control_secondary_click_forwards_as_left_click_before_context_menu_fallback() throws {
        var builderCallCount = 0
        var presentedMenuTitles: [String] = []
        var selectionDragStates: [Bool] = []
        surface.mouseButtonResults[GHOSTTY_MOUSE_LEFT] = false
        view.onSelectionDragStateDidChange = { selectionDragStates.append($0) }
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            let menu = NSMenu(title: "")
            menu.addItem(withTitle: "Add Pane Up", action: nil, keyEquivalent: "")
            return menu
        }
        view.contextMenuPresenter = { menu, _, _ in
            presentedMenuTitles = menu.items.map(\.title)
        }

        view.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(presentedMenuTitles, ["Add Pane Up"])
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertTrue(surface.sentMouseButtons.last?.modifiers.contains(.control) == true)
        XCTAssertEqual(selectionDragStates, [])
    }

    func test_unconsumed_control_secondary_click_does_not_forward_drag_or_selection_release() throws {
        var selectionDragStates: [Bool] = []
        surface.mouseButtonResults[GHOSTTY_MOUSE_LEFT] = false
        view.contextMenuBuilder = { _, _ in NSMenu(title: "") }
        view.contextMenuPresenter = { _, _, _ in }
        view.onSelectionDragStateDidChange = { selectionDragStates.append($0) }

        view.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))
        view.rightMouseDragged(with: try makeMouseEvent(
            type: .rightMouseDragged,
            location: CGPoint(x: 150, y: 210),
            modifierFlags: [.control]
        ))
        XCTAssertEqual(surface.sentMousePositions.count, 1)
        XCTAssertEqual(surface.sentMousePositions.last?.position.x, 120)

        view.rightMouseUp(with: try makeMouseEvent(
            type: .rightMouseUp,
            location: CGPoint(x: 150, y: 210)
        ))

        XCTAssertEqual(selectionDragStates, [])
    }

    func test_consumed_control_secondary_click_does_not_request_context_menu_presentation() throws {
        var builderCallCount = 0
        var presentationCount = 0
        var selectionDragStates: [Bool] = []
        surface.mouseButtonResults[GHOSTTY_MOUSE_LEFT] = true
        view.onSelectionDragStateDidChange = { selectionDragStates.append($0) }
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            return NSMenu(title: "")
        }
        view.contextMenuPresenter = { _, _, _ in
            presentationCount += 1
        }

        view.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        XCTAssertEqual(builderCallCount, 0)
        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertTrue(surface.sentMouseButtons.last?.modifiers.contains(.control) == true)
        XCTAssertEqual(selectionDragStates, [true])
    }

    func test_control_secondary_click_release_matches_left_click_press() throws {
        view.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        view.rightMouseUp(with: try makeMouseEvent(
            type: .rightMouseUp,
            location: CGPoint(x: 120, y: 180)
        ))

        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_RELEASE)
    }

    func test_control_secondary_click_drag_forwards_mouse_position() throws {
        surface.mouseButtonResults[GHOSTTY_MOUSE_LEFT] = true

        view.rightMouseDown(with: try makeMouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        view.rightMouseDragged(with: try makeMouseEvent(
            type: .rightMouseDragged,
            location: CGPoint(x: 150, y: 210),
            modifierFlags: [.control]
        ))

        let position = try XCTUnwrap(surface.sentMousePositions.last?.position)
        XCTAssertEqual(position.x, 150, accuracy: 0.01)
        XCTAssertEqual(position.y, 390, accuracy: 0.01)
    }

    func test_control_left_click_menu_is_suppressed_when_terminal_has_captured_mouse() throws {
        var builderCallCount = 0
        surface.mouseCaptured = true
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            return NSMenu(title: "")
        }

        let menu = view.menu(for: try makeMouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        XCTAssertNil(menu)
        XCTAssertEqual(builderCallCount, 0)
        XCTAssertTrue(surface.sentMouseButtons.isEmpty)
    }

    func test_control_left_click_menu_synthesizes_right_press_when_mouse_is_not_captured() throws {
        var builderCallCount = 0
        surface.mouseCaptured = false
        view.contextMenuBuilder = { _, _ in
            builderCallCount += 1
            let menu = NSMenu(title: "")
            menu.addItem(withTitle: "Add Pane Up", action: nil, keyEquivalent: "")
            return menu
        }

        let menu = view.menu(for: try makeMouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))

        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(menu?.items.map(\.title), ["Add Pane Up"])
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertTrue(surface.sentMouseButtons.last?.modifiers.contains(.control) == true)
    }

    func test_control_left_drag_reaches_terminal_after_captured_menu_is_suppressed() throws {
        surface.mouseCaptured = true

        _ = view.menu(for: try makeMouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))
        view.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 120, y: 180),
            modifierFlags: [.control]
        ))
        view.mouseDragged(with: try makeMouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 150, y: 210),
            modifierFlags: [.control]
        ))

        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertTrue(surface.sentMouseButtons.last?.modifiers.contains(.control) == true)
        let position = try XCTUnwrap(surface.sentMousePositions.last?.position)
        XCTAssertEqual(position.x, 150, accuracy: 0.01)
        XCTAssertEqual(position.y, 390, accuracy: 0.01)
    }
}

private final class ScrollRoutingSurfaceSpy: LibghosttySurfaceControlling {
    struct ScrollEvent: Equatable {
        let x: Double
        let y: Double
        let precision: Bool
        let momentum: NSEvent.Phase
    }

    struct MousePositionEvent: Equatable {
        let position: CGPoint
        let modifiers: NSEvent.ModifierFlags
    }

    struct MouseButtonEvent: Equatable {
        let state: ghostty_input_mouse_state_e
        let button: ghostty_input_mouse_button_e
        let modifiers: NSEvent.ModifierFlags
    }

    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var viewportUpdates: [(size: CGSize, scale: CGFloat, displayID: UInt32?)] = []
    private(set) var sentScrollEvents: [ScrollEvent] = []
    private(set) var sentMousePositions: [MousePositionEvent] = []
    private(set) var sentMouseButtons: [MouseButtonEvent] = []
    var mouseButtonResults: [ghostty_input_mouse_button_e: Bool] = [:]
    var mouseCaptured = false

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {
        viewportUpdates.append((size: size, scale: scale, displayID: displayID))
    }
    func clearViewportUpdates() {
        viewportUpdates.removeAll()
    }
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {
        sentScrollEvents.append(ScrollEvent(x: x, y: y, precision: precision, momentum: momentum))
    }
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {
        sentMousePositions.append(MousePositionEvent(position: position, modifiers: modifiers))
    }
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        sentMouseButtons.append(MouseButtonEvent(state: state, button: button, modifiers: modifiers))
        return mouseButtonResults[button] ?? false
    }
    func sendText(_ text: String) {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}

private func makeScrollEvent(
    deltaX: Int32 = 0,
    deltaY: Int32 = 0,
    precise: Bool,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let units: CGScrollEventUnit = precise ? .pixel : .line
    let cgEvent = try XCTUnwrap(
        CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )
    )

    cgEvent.flags = makeCGEventFlags(from: modifierFlags)
    if precise {
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(deltaX))
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    }

    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    location: CGPoint,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    switch type {
    case .mouseEntered, .mouseExited:
        return try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
    default:
        return try XCTUnwrap(
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
}

private func makeCGEventFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []

    if modifierFlags.contains(.shift) {
        flags.insert(.maskShift)
    }
    if modifierFlags.contains(.control) {
        flags.insert(.maskControl)
    }
    if modifierFlags.contains(.option) {
        flags.insert(.maskAlternate)
    }
    if modifierFlags.contains(.command) {
        flags.insert(.maskCommand)
    }

    return flags
}
