import AppKit
import GhosttyKit
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
        XCTAssertEqual(surface.refreshCallCount, 1)
    }

    func test_repeated_layout_with_same_viewport_does_not_reissue_refresh() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)

        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.viewportUpdates.count, 1)
        XCTAssertEqual(surface.refreshCallCount, 1)
    }

    func test_resize_reissues_viewport_update_and_refresh() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)

        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.viewportUpdates.count, 2)
        XCTAssertEqual(surface.refreshCallCount, 2)
    }

    func test_suspended_viewport_sync_skips_intermediate_updates_until_resumed() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)

        view.setViewportSyncSuspended(true)
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.viewportUpdates.count, 0)
        XCTAssertEqual(surface.refreshCallCount, 0)

        view.setViewportSyncSuspended(false)

        XCTAssertEqual(surface.viewportUpdates.count, 1)
        XCTAssertEqual(surface.refreshCallCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(surface.viewportUpdates.last).size.height,
            view.convertToBacking(view.bounds).height,
            accuracy: 0.001
        )
    }

    func test_suspended_viewport_sync_keeps_drawable_size_frozen_until_resumed() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)
        view.layoutSubtreeIfNeeded()

        let metalLayer = try XCTUnwrap(view.layer as? CAMetalLayer)
        let originalDrawableSize = metalLayer.drawableSize

        view.setViewportSyncSuspended(true)
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(metalLayer.drawableSize, originalDrawableSize)

        view.setViewportSyncSuspended(false)

        XCTAssertEqual(metalLayer.drawableSize.height, floor(view.convertToBacking(view.bounds).height))
        XCTAssertEqual(metalLayer.drawableSize.width, floor(view.convertToBacking(view.bounds).width))
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

    func test_right_arrow_forwards_navigation_event_without_text() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try makeArrowKeyEvent(keyCode: 124, functionKey: unichar(NSRightArrowFunctionKey))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].keyCode, 124)
        XCTAssertNil(surface.keyEvents[0].text)
    }

    func test_arrow_keys_forward_navigation_events_without_text() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let arrows: [(UInt16, unichar)] = [
            (123, unichar(NSLeftArrowFunctionKey)),
            (124, unichar(NSRightArrowFunctionKey)),
            (125, unichar(NSDownArrowFunctionKey)),
            (126, unichar(NSUpArrowFunctionKey)),
        ]

        for (keyCode, functionKey) in arrows {
            let event = try makeArrowKeyEvent(keyCode: keyCode, functionKey: functionKey)
            view.keyDown(with: event)
        }

        XCTAssertEqual(surface.keyEvents.map(\.keyCode), [123, 124, 125, 126])
        XCTAssertTrue(surface.keyEvents.allSatisfy { $0.text == nil })
    }

    func test_option_modified_navigation_preserves_option_modifier_without_text() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

            let event = try makeArrowKeyEvent(
            keyCode: 123,
            functionKey: unichar(NSLeftArrowFunctionKey),
            modifierFlags: [.option]
        )

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].keyCode, 123)
        XCTAssertNil(surface.keyEvents[0].text)
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

    func test_mouse_drag_forwards_pointer_updates_and_left_button_events_to_surface() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)
        window.contentView = view

        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 30),
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let mouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 80, y: 70),
            modifierFlags: [.shift],
            timestamp: 0.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 80, y: 70),
            modifierFlags: [.shift],
            timestamp: 0.2,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))

        view.mouseDown(with: mouseDown)
        view.mouseDragged(with: mouseDragged)
        view.mouseUp(with: mouseUp)

        let expectedDownY = view.bounds.height - 30
        let expectedDragY = view.bounds.height - 70

        XCTAssertEqual(surface.mouseRecords, [
            .position(CGPoint(x: 40, y: expectedDownY), [.shift]),
            .button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, [.shift]),
            .position(CGPoint(x: 80, y: expectedDragY), [.shift]),
            .position(CGPoint(x: 80, y: expectedDragY), [.shift]),
            .button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, [.shift]),
        ])
    }

    func test_vertical_scroll_forwards_mouse_scroll_event_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try makeScrollEvent(
            deltaX: 0,
            deltaY: 24,
            phase: .began,
            momentumPhase: .began,
            precise: true
        )

        view.scrollWheel(with: event)

        XCTAssertEqual(surface.scrollRecords, [
            .init(x: 0, y: 24, precision: true, momentum: .began),
        ])
    }

    func test_horizontal_scroll_is_not_forwarded_to_terminal_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try makeScrollEvent(deltaX: 48, deltaY: 6, precise: true)

        view.scrollWheel(with: event)

        XCTAssertTrue(surface.scrollRecords.isEmpty)
    }

    func test_shift_wheel_scroll_is_not_forwarded_to_terminal_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try makeScrollEvent(
            deltaX: 0,
            deltaY: 1,
            precise: false,
            modifierFlags: [.shift]
        )

        view.scrollWheel(with: event)

        XCTAssertTrue(surface.scrollRecords.isEmpty)
    }

    @objc func test_copy_action_dispatches_copy_to_clipboard_binding() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        view.perform(Selector(("copy:")), with: nil)

        XCTAssertEqual(surface.bindingActions, ["copy_to_clipboard"])
    }

    @objc func test_paste_action_dispatches_paste_from_clipboard_binding() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        view.perform(Selector(("paste:")), with: nil)

        XCTAssertEqual(surface.bindingActions, ["paste_from_clipboard"])
    }

    @objc func test_select_all_action_dispatches_select_all_binding() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        view.perform(Selector(("selectAll:")), with: nil)

        XCTAssertEqual(surface.bindingActions, ["select_all"])
    }

    @objc func test_copy_menu_item_validation_reflects_surface_selection_state() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        let copyItem = NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        view.bind(surfaceController: surface)

        let validator = view as? NSMenuItemValidation

        XCTAssertNotNil(validator)

        XCTAssertFalse(validator?.validateMenuItem(copyItem) ?? true)

        surface.selectionPresent = true

        XCTAssertTrue(validator?.validateMenuItem(copyItem) ?? false)
    }
}

private final class LibghosttySurfaceViewportSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
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

    struct ScrollRecord: Equatable {
        let x: Double
        let y: Double
        let precision: Bool
        let momentum: NSEvent.Phase
    }

    enum MouseRecord: Equatable {
        case position(CGPoint, NSEvent.ModifierFlags)
        case button(ghostty_input_mouse_state_e, ghostty_input_mouse_button_e, NSEvent.ModifierFlags)
    }

    private(set) var viewportUpdates: [ViewportUpdate] = []
    private(set) var focusUpdates: [Bool] = []
    private(set) var keyEvents: [KeyEventRecord] = []
    private(set) var mouseRecords: [MouseRecord] = []
    private(set) var scrollRecords: [ScrollRecord] = []
    private(set) var bindingActions: [String] = []
    private(set) var refreshCallCount = 0
    var selectionPresent = false

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {
        viewportUpdates.append(.init(size: size, scale: scale, displayID: displayID))
    }

    func setFocused(_ isFocused: Bool) {
        focusUpdates.append(isFocused)
    }

    func refresh() {
        refreshCallCount += 1
    }

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

    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {
        scrollRecords.append(.init(x: x, y: y, precision: precision, momentum: momentum))
    }

    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {
        mouseRecords.append(.position(position, modifiers))
    }

    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) {
        mouseRecords.append(.button(state, button, modifiers))
    }

    func sendText(_ text: String) {}

    func performBindingAction(_ action: String) -> Bool {
        bindingActions.append(action)
        return true
    }

    func hasSelection() -> Bool {
        selectionPresent
    }

    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        nil
    }
}

private func makeScrollEvent(
    deltaX: Int32 = 0,
    deltaY: Int32 = 0,
    phase: NSEvent.Phase = [],
    momentumPhase: NSEvent.Phase = [],
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
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))

    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
}

private func makeArrowKeyEvent(
    keyCode: UInt16,
    functionKey: unichar,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    let characters = String(UnicodeScalar(functionKey)!)
    return try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
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
