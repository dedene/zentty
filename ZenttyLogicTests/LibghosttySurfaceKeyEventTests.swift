import AppKit
import Carbon.HIToolbox
import GhosttyKit
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

    func test_modsFromFlags_records_right_option_side_bit() {
        let rightOptionFlag = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK))
        let flags = NSEvent.ModifierFlags.option.union(rightOptionFlag)

        let mods = LibghosttySurface.modsFromFlags(flags)

        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0)
    }

    func test_translatedModifierFlags_preserves_hidden_right_option_bit_when_removing_option() {
        let rightOptionFlag = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK))
        let flags = NSEvent.ModifierFlags.option.union(rightOptionFlag)

        let translated = LibghosttySurface.translatedModifierFlags(
            from: flags,
            ghosttyModifiers: GHOSTTY_MODS_NONE
        )

        XCTAssertFalse(translated.contains(.option))
        XCTAssertNotEqual(translated.rawValue & rightOptionFlag.rawValue, 0)
    }

    func test_translatedEvent_keeps_hidden_right_option_without_reintroducing_option() throws {
        let rightOptionFlag = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK))
        let event = try Self.makeKeyEvent(
            type: .keyDown,
            characters: "~",
            charactersIgnoringModifiers: "n",
            keyCode: UInt16(kVK_ANSI_N),
            modifierFlags: .option.union(rightOptionFlag)
        )

        let translated = LibghosttySurface.translatedEvent(from: event, modifierFlags: rightOptionFlag)

        XCTAssertFalse(translated.modifierFlags.contains(.option))
        XCTAssertNotEqual(translated.modifierFlags.rawValue & rightOptionFlag.rawValue, 0)
        XCTAssertEqual(translated.characters, "n")
    }

    // MARK: - normalizedSurfaceEnvironment

    func test_normalizedSurfaceEnvironment_adds_truecolor_when_missing() {
        let environment = LibghosttySurface.normalizedSurfaceEnvironment(
            ["ZENTTY_PANE_ID": "pane"],
            processEnvironment: [:]
        )

        XCTAssertEqual(environment["COLORTERM"], "truecolor")
    }

    func test_normalizedSurfaceEnvironment_preserves_existing_colorterm() {
        let environment = LibghosttySurface.normalizedSurfaceEnvironment(
            ["COLORTERM": "24bit"],
            processEnvironment: ["COLORTERM": "truecolor"]
        )

        XCTAssertEqual(environment["COLORTERM"], "24bit")
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
        charactersIgnoringModifiers: String? = nil,
        keyCode: UInt16
    ) throws -> NSEvent {
        try Self.makeKeyEvent(
            type: type,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            keyCode: keyCode,
            modifierFlags: []
        )
    }

    private static func makeKeyEvent(
        type: NSEvent.EventType,
        characters: String,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
