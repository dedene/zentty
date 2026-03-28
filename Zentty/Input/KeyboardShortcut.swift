import AppKit

enum KeyboardShortcutKey: Hashable, Sendable {
    case character(String)
    case tab
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow

    fileprivate var storageToken: String {
        switch self {
        case .character(let value):
            value.lowercased()
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
            guard storageToken.count == 1 else {
                return nil
            }

            return .character(storageToken.lowercased())
        }
    }

    fileprivate var menuKeyEquivalent: String {
        switch self {
        case .character(let value):
            value.lowercased()
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
}

enum KeyboardModifier: Hashable, Sendable {
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

        let key: KeyboardShortcutKey

        switch event.keyCode {
        case 48:
            key = .tab
        case 123:
            key = .leftArrow
        case 124:
            key = .rightArrow
        case 125:
            key = .downArrow
        case 126:
            key = .upArrow
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else {
                return nil
            }

            key = .character(characters)
        }

        self.init(key: key, modifiers: modifiers)
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
