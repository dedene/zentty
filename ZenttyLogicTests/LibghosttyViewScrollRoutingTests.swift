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

    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var sentScrollEvents: [ScrollEvent] = []
    private(set) var sentMousePositions: [MousePositionEvent] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
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
    ) {}
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
