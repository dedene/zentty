import Foundation

/// A named key that is delivered to a pane as a real key press, so the
/// terminal's key encoder picks the right bytes for the current mode
/// (application cursor keys, keyboard protocol flags, ...).
enum PaneNamedKey: String, Equatable, Sendable, CaseIterable {
    case enter
    case tab
    case backTab
    case space
    case backspace
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    case delete
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// Plain-byte rendering, used where no key encoder is available.
    var legacyText: String {
        switch self {
        case .enter: "\r"
        case .tab: "\t"
        case .backTab: "\u{1b}[Z"
        case .space: " "
        case .backspace: "\u{7f}"
        case .escape: "\u{1b}"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .right: "\u{1b}[C"
        case .left: "\u{1b}[D"
        case .home: "\u{1b}[H"
        case .end: "\u{1b}[F"
        case .pageUp: "\u{1b}[5~"
        case .pageDown: "\u{1b}[6~"
        case .insert: "\u{1b}[2~"
        case .delete: "\u{1b}[3~"
        case .f1: "\u{1b}OP"
        case .f2: "\u{1b}OQ"
        case .f3: "\u{1b}OR"
        case .f4: "\u{1b}OS"
        case .f5: "\u{1b}[15~"
        case .f6: "\u{1b}[17~"
        case .f7: "\u{1b}[18~"
        case .f8: "\u{1b}[19~"
        case .f9: "\u{1b}[20~"
        case .f10: "\u{1b}[21~"
        case .f11: "\u{1b}[23~"
        case .f12: "\u{1b}[24~"
        }
    }
}

/// One unit of input produced from a key name.
enum PaneKeyStroke: Equatable, Sendable {
    /// A named key press, optionally with Shift.
    case key(PaneNamedKey, shift: Bool)
    /// Control plus a letter (`C-c`), delivered as a key press.
    case control(Character)
    /// Literal bytes written as typed text (single characters, `M-x`).
    case text(String)

    /// Plain-byte rendering, used where no key encoder is available.
    var legacyText: String {
        switch self {
        case .key(let key, _):
            return key.legacyText
        case .control(let letter):
            guard let ascii = letter.asciiValue else { return "" }
            return String(UnicodeScalar(ascii & 0x1f))
        case .text(let text):
            return text
        }
    }
}

enum PaneKeyNameError: LocalizedError, Equatable {
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .unknownKey(let name):
            "Unknown key name '\(name)'. Use names like Enter, Escape, Tab, Up, C-c, M-x, or a single character."
        }
    }
}

/// Key-name vocabulary shared by `zentty pane send-key` and the agent-teams
/// shim (`TmuxCompatIPCHandler`). Names are case-insensitive.
enum PaneKeyNames {
    /// Keys the agent-teams shim turns into raw bytes for `send-keys`.
    /// Kept as its own table so the shim's text output only changes on
    /// purpose while `send-key` grows richer keys.
    static func controlKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-u":
            return "\u{15}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        case "up":
            return "\u{1b}[A"
        case "down":
            return "\u{1b}[B"
        case "right":
            return "\u{1b}[C"
        case "left":
            return "\u{1b}[D"
        default:
            return nil
        }
    }

    /// Parses one key name. Single characters are sent literally; anything
    /// else must be a known name so a typo fails loudly instead of being
    /// typed into the pane.
    static func stroke(for token: String) throws -> PaneKeyStroke {
        if let named = namedKey(token.lowercased()) {
            return named
        }
        if token.count == 1 {
            return .text(token)
        }
        let lowered = token.lowercased()
        if lowered.hasPrefix("c-"), token.count == 3,
           let letter = token.last, letter.isASCII, letter.isLetter {
            return .control(Character(letter.lowercased()))
        }
        if lowered.hasPrefix("m-"), token.count >= 3 {
            let rest = String(token.dropFirst(2))
            let inner = try stroke(for: rest)
            if case .text(let text) = inner {
                return .text("\u{1b}" + text)
            }
            return .text("\u{1b}" + inner.legacyText)
        }
        throw PaneKeyNameError.unknownKey(token)
    }

    static func strokes(for tokens: [String]) throws -> [PaneKeyStroke] {
        try tokens.map(stroke(for:))
    }

    private static func namedKey(_ lowered: String) -> PaneKeyStroke? {
        switch lowered {
        case "enter", "return", "c-m", "kpenter":
            return .key(.enter, shift: false)
        case "tab", "c-i":
            return .key(.tab, shift: false)
        case "btab", "s-tab":
            return .key(.backTab, shift: true)
        case "space":
            return .key(.space, shift: false)
        case "bspace", "backspace":
            return .key(.backspace, shift: false)
        case "escape", "esc", "c-[":
            return .key(.escape, shift: false)
        case "up": return .key(.up, shift: false)
        case "down": return .key(.down, shift: false)
        case "left": return .key(.left, shift: false)
        case "right": return .key(.right, shift: false)
        case "s-up": return .key(.up, shift: true)
        case "s-down": return .key(.down, shift: true)
        case "s-left": return .key(.left, shift: true)
        case "s-right": return .key(.right, shift: true)
        case "home": return .key(.home, shift: false)
        case "end": return .key(.end, shift: false)
        case "pageup", "pgup", "ppage": return .key(.pageUp, shift: false)
        case "pagedown", "pgdn", "npage": return .key(.pageDown, shift: false)
        case "insert", "ic": return .key(.insert, shift: false)
        case "delete", "dc": return .key(.delete, shift: false)
        case "f1": return .key(.f1, shift: false)
        case "f2": return .key(.f2, shift: false)
        case "f3": return .key(.f3, shift: false)
        case "f4": return .key(.f4, shift: false)
        case "f5": return .key(.f5, shift: false)
        case "f6": return .key(.f6, shift: false)
        case "f7": return .key(.f7, shift: false)
        case "f8": return .key(.f8, shift: false)
        case "f9": return .key(.f9, shift: false)
        case "f10": return .key(.f10, shift: false)
        case "f11": return .key(.f11, shift: false)
        case "f12": return .key(.f12, shift: false)
        default: return nil
        }
    }
}
