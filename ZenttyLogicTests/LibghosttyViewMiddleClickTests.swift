import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

/// Verifies that `LibghosttyView` forwards `otherMouse*` button events to the surface.
///
/// The actual middle-click *paste* happens inside libghostty (a middle-button press
/// makes the core paste the selection clipboard). The contract Zentty owns is simply
/// forwarding the right button to the surface; that is what these tests pin down.
@MainActor
final class LibghosttyViewMiddleClickTests: AppKitTestCase {
    private var view: LibghosttyView!
    private var surface: MiddleClickSurfaceSpy!

    override func setUp() {
        super.setUp()
        view = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        surface = MiddleClickSurfaceSpy()
        view.bind(surfaceController: surface)
    }

    override func tearDown() {
        view = nil
        surface = nil
        super.tearDown()
    }

    func test_middle_click_forwards_press_and_release_as_middle() throws {
        view.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 2))
        view.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 2))

        XCTAssertEqual(surface.sentMouseButtons.count, 2)
        XCTAssertEqual(surface.sentMouseButtons.first?.state, GHOSTTY_MOUSE_PRESS)
        XCTAssertEqual(surface.sentMouseButtons.first?.button, GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(surface.sentMouseButtons.last?.state, GHOSTTY_MOUSE_RELEASE)
        XCTAssertEqual(surface.sentMouseButtons.last?.button, GHOSTTY_MOUSE_MIDDLE)
    }

    func test_back_button_maps_to_ghostty_eight() throws {
        view.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3))

        XCTAssertEqual(surface.sentMouseButtons.count, 1)
        XCTAssertEqual(surface.sentMouseButtons.first?.button, GHOSTTY_MOUSE_EIGHT)
    }

    func test_forward_button_maps_to_ghostty_nine() throws {
        view.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4))

        XCTAssertEqual(surface.sentMouseButtons.count, 1)
        XCTAssertEqual(surface.sentMouseButtons.first?.button, GHOSTTY_MOUSE_NINE)
    }

    func test_unmapped_other_button_is_ignored() throws {
        view.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 7))
        view.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 7))

        XCTAssertTrue(surface.sentMouseButtons.isEmpty)
    }

    func test_modifiers_are_passed_through() throws {
        view.otherMouseDown(
            with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 2, flags: .maskShift)
        )

        XCTAssertEqual(surface.sentMouseButtons.count, 1)
        XCTAssertTrue(surface.sentMouseButtons.first?.modifiers.contains(.shift) ?? false)
    }
}

// MARK: - Test Doubles

@MainActor
private func makeOtherMouseEvent(
    type: CGEventType,
    buttonNumber: Int,
    flags: CGEventFlags = []
) throws -> NSEvent {
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let cgEvent = try XCTUnwrap(
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: .zero,
            mouseButton: .center
        )
    )
    // CGMouseButton only names left/right/center, so set the button number explicitly
    // for back/forward (3/4) and any other button we want to simulate.
    cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
    cgEvent.flags = flags
    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
}

private final class MiddleClickSurfaceSpy: LibghosttySurfaceControlling {
    struct MouseButtonEvent: Equatable {
        let state: ghostty_input_mouse_state_e
        let button: ghostty_input_mouse_button_e
        let modifiers: NSEvent.ModifierFlags
    }

    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var sentMouseButtons: [MouseButtonEvent] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        sentMouseButtons.append(MouseButtonEvent(state: state, button: button, modifiers: modifiers))
        return false
    }
    func sendText(_ text: String) {}
    func submitReturn() {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}
