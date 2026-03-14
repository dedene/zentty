import AppKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewTests: XCTestCase {
    func test_layout_updates_surface_viewport_using_view_bounds() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)

        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.viewportUpdates.count, 1)
        let update = try XCTUnwrap(surface.viewportUpdates.last)
        let expectedBackingSize = view.convertToBacking(view.bounds).size
        XCTAssertEqual(update.size.width, expectedBackingSize.width, accuracy: 0.001)
        XCTAssertEqual(update.size.height, expectedBackingSize.height, accuracy: 0.001)
        XCTAssertGreaterThan(update.scale, 0)
    }

    func test_focus_changes_are_forwarded_to_surface() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())

        XCTAssertEqual(surface.focusUpdates, [true, false])
    }

    func test_key_down_forwards_text_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].text, "a")
        XCTAssertEqual(surface.keyEvents[0].action, .press)
    }

    func test_key_up_forwards_release_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        ))

        view.keyUp(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].action, .release)
    }

    func test_ctrl_c_forwards_terminal_control_text_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].action, .press)
        XCTAssertEqual(surface.keyEvents[0].text, "c")
        XCTAssertTrue(surface.keyEvents[0].modifierFlags.contains(.control))
    }

    func test_ctrl_d_forwards_terminal_control_text_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].action, .press)
        XCTAssertEqual(surface.keyEvents[0].text, "d")
        XCTAssertTrue(surface.keyEvents[0].modifierFlags.contains(.control))
    }

    func test_arrow_keys_forward_navigation_events_without_text() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 124
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].keyCode, 124)
        XCTAssertEqual(surface.keyEvents[0].text, String(UnicodeScalar(NSRightArrowFunctionKey)!))
    }

    func test_option_modified_navigation_preserves_option_modifier() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 123
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].keyCode, 123)
        XCTAssertTrue(surface.keyEvents[0].modifierFlags.contains(.option))
    }

    func test_text_for_key_event_restores_control_character_source_text() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertEqual(LibghosttySurface.textForKeyEvent(event), "c")
    }

    func test_text_for_key_event_suppresses_function_key_glyphs() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 124
        ))

        XCTAssertNil(LibghosttySurface.textForKeyEvent(event))
    }

    func test_unshifted_codepoint_uses_unmodified_character() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "A",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertEqual(LibghosttySurface.unshiftedCodepointFromEvent(event), Character("a").unicodeScalars.first?.value)
    }
}

private final class LibghosttySurfaceViewportSpy: LibghosttySurfaceControlling {
    struct ViewportUpdate: Equatable {
        let size: CGSize
        let scale: CGFloat
        let displayID: UInt32?
    }

    struct KeyEventRecord: Equatable {
        let action: TerminalKeyAction
        let text: String?
        let composing: Bool
        let modifierFlags: NSEvent.ModifierFlags
        let keyCode: UInt16
    }

    private(set) var viewportUpdates: [ViewportUpdate] = []
    private(set) var focusUpdates: [Bool] = []
    private(set) var keyEvents: [KeyEventRecord] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {
        viewportUpdates.append(.init(size: size, scale: scale, displayID: displayID))
    }

    func setFocused(_ isFocused: Bool) {
        focusUpdates.append(isFocused)
    }

    func refresh() {}

    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool {
        keyEvents.append(.init(
            action: action,
            text: text,
            composing: composing,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            keyCode: event.keyCode
        ))
        return true
    }

    func sendText(_ text: String) {}
}
