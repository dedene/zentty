import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zentty

/// Regression tests for a bug where `LibghosttySurface`'s key-event helpers
/// called `-[NSEvent characters(byApplyingModifiers:)]` on `.flagsChanged`
/// events. AppKit asserts on that selector for non-key events and raises
/// `NSInvalidArgumentException`, which was caught and swallowed by AppKit's
/// internal exception handler in `NSWindow sendEvent:` — so the app survived,
/// but `ghostty_surface_key` was never reached for modifier events, leaving
/// Ghostty unaware of ⌘/⇧/⌥/⌃/CapsLock state changes.
@MainActor
final class LibghosttySurfaceKeyEventTests: XCTestCase {
    // MARK: - unshiftedCodepointFromEvent

    func test_unshiftedCodepointFromEvent_returns_zero_for_flagsChanged_event() throws {
        let event = try Self.makeFlagsChangedEvent(modifierFlags: .command, keyCode: UInt16(kVK_Command))

        XCTAssertEqual(LibghosttySurface.unshiftedCodepointFromEvent(event), 0)
    }

    func test_unshiftedCodepointFromEvent_returns_scalar_for_keyDown_event() throws {
        let event = try Self.makeKeyEvent(type: .keyDown, characters: "a", keyCode: UInt16(kVK_ANSI_A))

        XCTAssertEqual(LibghosttySurface.unshiftedCodepointFromEvent(event), UInt32(Character("a").asciiValue!))
    }

    // MARK: - textForKeyEvent

    func test_textForKeyEvent_returns_nil_for_flagsChanged_event() throws {
        let event = try Self.makeFlagsChangedEvent(modifierFlags: .shift, keyCode: UInt16(kVK_Shift))

        XCTAssertNil(LibghosttySurface.textForKeyEvent(event))
    }

    func test_textForKeyEvent_returns_characters_for_keyDown_event() throws {
        let event = try Self.makeKeyEvent(type: .keyDown, characters: "x", keyCode: UInt16(kVK_ANSI_X))

        XCTAssertEqual(LibghosttySurface.textForKeyEvent(event), "x")
    }

    // MARK: - translatedEvent

    func test_translatedEvent_returns_original_for_flagsChanged_event_when_flags_differ() throws {
        let event = try Self.makeFlagsChangedEvent(modifierFlags: .command, keyCode: UInt16(kVK_Command))

        // Pass a deliberately different modifier set so the early-return guard
        // on matching flags does not short-circuit. The helper must still
        // refuse to call NSEvent.keyEvent(with: .flagsChanged, ...) + the
        // character accessors and instead return the original event.
        let translated = LibghosttySurface.translatedEvent(from: event, modifierFlags: [])

        XCTAssertEqual(translated.type, .flagsChanged)
        XCTAssertEqual(translated.keyCode, UInt16(kVK_Command))
    }

    // MARK: - Helpers

    private static func makeFlagsChangedEvent(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private static func makeKeyEvent(
        type: NSEvent.EventType,
        characters: String,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
