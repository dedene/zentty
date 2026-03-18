import AppKit

enum KeyboardShortcutKey: Hashable, Sendable {
    case character(String)
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
}

enum KeyboardModifier: Hashable, Sendable {
    case command
    case option
    case shift
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
        if sanitizedFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if sanitizedFlags.contains(.shift) {
            modifiers.insert(.shift)
        }

        let key: KeyboardShortcutKey

        switch event.keyCode {
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
}
