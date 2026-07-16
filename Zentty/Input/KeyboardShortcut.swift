import AppKit
import Carbon.HIToolbox

enum KeyboardShortcutKey: Hashable, Sendable {
    case character(String)
    case space
    case delete
    case `return`
    case tab
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow

    fileprivate var storageToken: String {
        switch self {
        case .character(let value):
            value.lowercased()
        case .space:
            "space"
        case .delete:
            "delete"
        case .return:
            "return"
        case .tab:
            "tab"
        case .leftArrow:
            "left"
        case .rightArrow:
            "right"
        case .upArrow:
            "up"
        case .downArrow:
            "down"
        }
    }

    fileprivate static func from(storageToken: String) -> KeyboardShortcutKey? {
        switch storageToken {
        case "space":
            return .space
        case "delete":
            return .delete
        case "return", "enter":
            return .return
        case "tab":
            return .tab
        case "left":
            return .leftArrow
        case "right":
            return .rightArrow
        case "up":
            return .upArrow
        case "down":
            return .downArrow
        default:
            guard storageToken.count == 1,
                  let scalar = storageToken.unicodeScalars.first else {
                return nil
            }

            switch scalar {
            case "\u{0003}": // legacy keypad Enter stored via charactersIgnoringModifiers
                return .return
            case "\u{007F}": // legacy Delete stored via charactersIgnoringModifiers
                return .delete
            default:
                return .character(storageToken.lowercased())
            }
        }
    }

    static func from(keyCode: UInt16) -> KeyboardShortcutKey? {
        switch keyCode {
        case UInt16(kVK_Space):
            return .space
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            return .delete
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return .return
        case UInt16(kVK_Tab):
            return .tab
        case UInt16(kVK_LeftArrow):
            return .leftArrow
        case UInt16(kVK_RightArrow):
            return .rightArrow
        case UInt16(kVK_UpArrow):
            return .upArrow
        case UInt16(kVK_DownArrow):
            return .downArrow
        default:
            return nil
        }
    }

    fileprivate var menuKeyEquivalent: String {
        switch self {
        case .character(let value):
            value.lowercased()
        case .space:
            " "
        case .delete:
            String(UnicodeScalar(NSDeleteCharacter)!)
        case .return:
            "\r"
        case .tab:
            "\t"
        case .leftArrow:
            String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .rightArrow:
            String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .upArrow:
            String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow:
            String(UnicodeScalar(NSDownArrowFunctionKey)!)
        }
    }

    fileprivate var displayToken: String {
        switch self {
        case .character(let value):
            value.uppercased()
        case .space:
            "Space"
        case .delete:
            "Delete"
        case .return:
            "Return"
        case .tab:
            "Tab"
        case .leftArrow:
            "Left"
        case .rightArrow:
            "Right"
        case .upArrow:
            "Up"
        case .downArrow:
            "Down"
        }
    }

    var primaryKeyCode: UInt16? {
        switch self {
        case .space:
            return UInt16(kVK_Space)
        case .delete:
            return UInt16(kVK_Delete)
        case .return:
            return UInt16(kVK_Return)
        case .tab:
            return UInt16(kVK_Tab)
        case .leftArrow:
            return UInt16(kVK_LeftArrow)
        case .rightArrow:
            return UInt16(kVK_RightArrow)
        case .upArrow:
            return UInt16(kVK_UpArrow)
        case .downArrow:
            return UInt16(kVK_DownArrow)
        case .character:
            return nil
        }
    }
}

enum KeyboardModifier: Hashable, Sendable, CaseIterable {
    case command
    case control
    case option
    case shift

    fileprivate static let storageOrder: [KeyboardModifier] = [
        .command,
        .control,
        .option,
        .shift,
    ]

    fileprivate var storageToken: String {
        switch self {
        case .command:
            "command"
        case .control:
            "control"
        case .option:
            "option"
        case .shift:
            "shift"
        }
    }

    fileprivate static func from(storageToken: String) -> KeyboardModifier? {
        switch storageToken {
        case "command":
            .command
        case "control":
            .control
        case "option":
            .option
        case "shift":
            .shift
        default:
            nil
        }
    }

    static func from(flags: NSEvent.ModifierFlags) -> Set<KeyboardModifier> {
        let sanitizedFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<KeyboardModifier>()

        if sanitizedFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if sanitizedFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if sanitizedFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if sanitizedFlags.contains(.shift) {
            modifiers.insert(.shift)
        }

        return modifiers
    }

    fileprivate var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:
            .command
        case .control:
            .control
        case .option:
            .option
        case .shift:
            .shift
        }
    }

    fileprivate var displaySymbol: String {
        switch self {
        case .command:
            "⌘"
        case .control:
            "⌃"
        case .option:
            "⌥"
        case .shift:
            "⇧"
        }
    }
}

struct KeyboardShortcut: Hashable, Sendable {
    let key: KeyboardShortcutKey
    let modifiers: Set<KeyboardModifier>

    init(key: KeyboardShortcutKey, modifiers: Set<KeyboardModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let sanitizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Arrow keys and Forward Delete always carry .function in their modifier
        // flags; only unsupported function-type keys (Home, End, F-keys, …) are
        // rejected here.
        let allowsFunctionModifier = KeyboardShortcutKey.from(keyCode: event.keyCode) != nil
        guard sanitizedFlags.contains(.function) == false || allowsFunctionModifier else {
            return nil
        }

        let key: KeyboardShortcutKey

        if let specialKey = KeyboardShortcutKey.from(keyCode: event.keyCode) {
            key = specialKey
        } else {
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else {
                return nil
            }

            key = .character(characters)
        }

        self.init(key: key, modifiers: KeyboardModifier.from(flags: sanitizedFlags))
    }

    init?(storageString: String) {
        let trimmed = storageString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let tokens = trimmed
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let keyToken = tokens.last,
              let key = KeyboardShortcutKey.from(storageToken: keyToken) else {
            return nil
        }

        var modifiers = Set<KeyboardModifier>()
        for token in tokens.dropLast() {
            guard let modifier = KeyboardModifier.from(storageToken: token) else {
                return nil
            }

            modifiers.insert(modifier)
        }

        self.init(key: key, modifiers: modifiers)
    }

    var storageString: String {
        let modifierTokens = KeyboardModifier.storageOrder
            .filter { modifiers.contains($0) }
            .map(\.storageToken)
        return (modifierTokens + [key.storageToken]).joined(separator: "+")
    }

    var isEligibleCommandBinding: Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    var displayString: String {
        let modifierSymbols = KeyboardModifier.storageOrder
            .filter { modifiers.contains($0) }
            .map(\.displaySymbol)
            .joined()
        return modifierSymbols + key.displayToken
    }

    var menuKeyEquivalent: String {
        key.menuKeyEquivalent
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { partialResult, modifier in
            partialResult.insert(modifier.modifierFlag)
        }
    }
}
