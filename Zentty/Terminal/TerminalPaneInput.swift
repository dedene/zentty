import AppKit
import Carbon.HIToolbox
import GhosttyKit

struct TerminalGridSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
}

/// Scripted input for a pane (`zentty pane send` / `send-key`), beyond the
/// paste-style `sendText` every adapter has.
@MainActor
protocol TerminalPaneInputDriving: AnyObject {
    /// False while the terminal has no live surface (not started yet, or
    /// already closed): nothing sent now would arrive.
    var acceptsInput: Bool { get }
    /// Writes `text` to the terminal as typed bytes, without paste wrapping.
    /// Returns false when the terminal could not take it.
    func typeText(_ text: String) -> Bool
    /// Presses one key through the terminal's key encoder.
    func sendKeyStroke(_ stroke: PaneKeyStroke) -> Bool
    var terminalGridSize: TerminalGridSize? { get }
}

@MainActor
protocol LibghosttySurfaceGridReporting: AnyObject {
    var terminalGridSize: TerminalGridSize? { get }
}

extension LibghosttySurface: LibghosttySurfaceGridReporting {
    var terminalGridSize: TerminalGridSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
    }
}

enum TerminalPaneInputEncoding {
    /// The `text:` binding action parses its parameter as a Zig string
    /// literal, so only backslashes need escaping; every other byte,
    /// control characters included, is written as-is.
    static func ghosttyTextAction(_ text: String) -> String {
        "text:" + text.replacingOccurrences(of: "\\", with: "\\\\")
    }

    /// A synthetic key-down for `stroke`, or nil for strokes that are plain
    /// text and should be typed instead.
    static func keyEvent(for stroke: PaneKeyStroke) -> NSEvent? {
        let spec: (keyCode: Int, characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags)
        switch stroke {
        case .text:
            return nil
        case .key(let key, let shift):
            let base = namedKeySpec(key)
            spec = (base.keyCode, base.characters, base.characters, shift ? [.shift] : [])
        case .control(let letter):
            guard let keyCode = letterKeyCodes[letter], let ascii = letter.asciiValue else {
                return nil
            }
            spec = (keyCode, String(UnicodeScalar(ascii & 0x1f)), String(letter), [.control])
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: spec.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: spec.characters,
            charactersIgnoringModifiers: spec.ignoringModifiers,
            isARepeat: false,
            keyCode: UInt16(spec.keyCode)
        )
    }

    private static func namedKeySpec(_ key: PaneNamedKey) -> (keyCode: Int, characters: String) {
        func function(_ value: Int) -> String {
            String(UnicodeScalar(UInt32(value)).map(Character.init) ?? " ")
        }
        switch key {
        case .enter: return (kVK_Return, "\r")
        case .tab: return (kVK_Tab, "\t")
        case .backTab: return (kVK_Tab, "\u{19}")
        case .space: return (kVK_Space, " ")
        case .backspace: return (kVK_Delete, "\u{7f}")
        case .escape: return (kVK_Escape, "\u{1b}")
        case .up: return (kVK_UpArrow, function(NSUpArrowFunctionKey))
        case .down: return (kVK_DownArrow, function(NSDownArrowFunctionKey))
        case .left: return (kVK_LeftArrow, function(NSLeftArrowFunctionKey))
        case .right: return (kVK_RightArrow, function(NSRightArrowFunctionKey))
        case .home: return (kVK_Home, function(NSHomeFunctionKey))
        case .end: return (kVK_End, function(NSEndFunctionKey))
        case .pageUp: return (kVK_PageUp, function(NSPageUpFunctionKey))
        case .pageDown: return (kVK_PageDown, function(NSPageDownFunctionKey))
        case .insert: return (kVK_Help, function(NSInsertFunctionKey))
        case .delete: return (kVK_ForwardDelete, function(NSDeleteFunctionKey))
        case .f1: return (kVK_F1, function(NSF1FunctionKey))
        case .f2: return (kVK_F2, function(NSF2FunctionKey))
        case .f3: return (kVK_F3, function(NSF3FunctionKey))
        case .f4: return (kVK_F4, function(NSF4FunctionKey))
        case .f5: return (kVK_F5, function(NSF5FunctionKey))
        case .f6: return (kVK_F6, function(NSF6FunctionKey))
        case .f7: return (kVK_F7, function(NSF7FunctionKey))
        case .f8: return (kVK_F8, function(NSF8FunctionKey))
        case .f9: return (kVK_F9, function(NSF9FunctionKey))
        case .f10: return (kVK_F10, function(NSF10FunctionKey))
        case .f11: return (kVK_F11, function(NSF11FunctionKey))
        case .f12: return (kVK_F12, function(NSF12FunctionKey))
        }
    }

    private static let letterKeyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]
}
