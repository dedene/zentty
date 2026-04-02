import Carbon.HIToolbox

enum ShortcutPreset: String, CaseIterable, Sendable {
    case leftHand
    case rightHand

    var title: String {
        switch self {
        case .leftHand:
            "Left-Hand Preset"
        case .rightHand:
            "Right-Hand Preset"
        }
    }

    var menuTitle: String {
        "Apply \(title)"
    }

    var confirmationMessage: String {
        switch self {
        case .leftHand:
            "This will replace all current shortcut bindings with shortcuts optimized for left-hand use, based on your current keyboard layout."
        case .rightHand:
            "This will replace all current shortcut bindings with shortcuts optimized for right-hand use, based on your current keyboard layout."
        }
    }
}

struct ShortcutPresetResolver {
    private let sourceProvider: KeyboardPreviewSourceProviding

    init(sourceProvider: KeyboardPreviewSourceProviding = SystemKeyboardPreviewSourceProvider()) {
        self.sourceProvider = sourceProvider
    }

    func resolve(_ preset: ShortcutPreset) -> [ShortcutBindingOverride] {
        let entries = preset.entries
        let presetCommandIDs = Set(entries.map(\.commandID))
        var bindings: [ShortcutBindingOverride] = []

        for entry in entries {
            let shortcut = resolveShortcut(for: entry)
            bindings.append(ShortcutBindingOverride(commandID: entry.commandID, shortcut: shortcut))
        }

        for definition in AppCommandRegistry.definitions where definition.defaultShortcut != nil {
            if presetCommandIDs.contains(definition.id) == false {
                bindings.append(ShortcutBindingOverride(commandID: definition.id, shortcut: nil))
            }
        }

        let sanitized = ShortcutManager.sanitizedBindings(bindings)

        // sanitizedBindings drops entries that match the default (redundant) and entries
        // that conflict with an already-registered shortcut. For redundant entries, the
        // default kicks in — no action needed. For conflict-dropped entries, we must add
        // an explicit unbind so their default shortcut doesn't create a silent conflict.
        let sanitizedCommandIDs = Set(sanitized.map(\.commandID))
        var result = sanitized
        for entry in entries where sanitizedCommandIDs.contains(entry.commandID) == false {
            let resolved = resolveShortcut(for: entry)
            let definition = AppCommandRegistry.definition(for: entry.commandID)
            if resolved != definition.defaultShortcut {
                result.append(ShortcutBindingOverride(commandID: entry.commandID, shortcut: nil))
            }
        }

        return result
    }

    private func resolveShortcut(for entry: ShortcutPresetEntry) -> KeyboardShortcut? {
        let key = resolveKey(for: entry)
        let modifiers = resolveModifiers(for: entry)
        guard let key else { return nil }
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    private func resolveKey(for entry: ShortcutPresetEntry) -> KeyboardShortcutKey? {
        switch entry.keyKind {
        case .tab:
            return .tab
        case .leftArrow:
            return .leftArrow
        case .rightArrow:
            return .rightArrow
        case .upArrow:
            return .upArrow
        case .downArrow:
            return .downArrow
        case .character:
            if isNumberRowKeyCode(entry.keyCode) {
                return resolveNumberRowKey(for: entry)
            }
            guard let character = sourceProvider.output(for: entry.keyCode, modifiers: []) else {
                return nil
            }
            return .character(character.lowercased())
        }
    }

    private func resolveModifiers(for entry: ShortcutPresetEntry) -> Set<KeyboardModifier> {
        guard entry.keyKind == .character, isNumberRowKeyCode(entry.keyCode) else {
            return entry.modifiers
        }
        guard let unshifted = sourceProvider.output(for: entry.keyCode, modifiers: []) else {
            return entry.modifiers
        }
        let isDigitByDefault = unshifted.count == 1 && unshifted.first?.isNumber == true
        if isDigitByDefault {
            return entry.modifiers
        }
        return entry.modifiers.union([.shift])
    }

    private func resolveNumberRowKey(for entry: ShortcutPresetEntry) -> KeyboardShortcutKey? {
        if let unshifted = sourceProvider.output(for: entry.keyCode, modifiers: []),
           unshifted.count == 1, unshifted.first?.isNumber == true {
            return .character(unshifted)
        }
        if let shifted = sourceProvider.output(for: entry.keyCode, modifiers: [.shift]),
           shifted.count == 1, shifted.first?.isNumber == true {
            return .character(shifted)
        }
        return nil
    }

    private func isNumberRowKeyCode(_ keyCode: UInt16) -> Bool {
        let numberRowCodes: Set<UInt16> = [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
            UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
            UInt16(kVK_ANSI_0),
        ]
        return numberRowCodes.contains(keyCode)
    }
}

enum ShortcutPresetKeyKind {
    case character
    case tab
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
}

struct ShortcutPresetEntry {
    let commandID: AppCommandID
    let keyCode: UInt16
    let keyKind: ShortcutPresetKeyKind
    let modifiers: Set<KeyboardModifier>
}

extension ShortcutPreset {
    var entries: [ShortcutPresetEntry] {
        switch self {
        case .leftHand:
            Self.leftHandEntries
        case .rightHand:
            Self.rightHandEntries
        }
    }

    // MARK: - Left-Hand Preset
    // Thumb on left Cmd, pinky on left Shift. WASD for directional.

    private static let leftHandEntries: [ShortcutPresetEntry] = [
        // Directional — Cmd+WASD
        .init(commandID: .focusUpInColumn, keyCode: UInt16(kVK_ANSI_W), keyKind: .character, modifiers: [.command]),
        .init(commandID: .focusLeftPane, keyCode: UInt16(kVK_ANSI_A), keyKind: .character, modifiers: [.command]),
        .init(commandID: .focusDownInColumn, keyCode: UInt16(kVK_ANSI_S), keyKind: .character, modifiers: [.command]),
        .init(commandID: .focusRightPane, keyCode: UInt16(kVK_ANSI_D), keyKind: .character, modifiers: [.command]),

        // Resize — Cmd+Shift+WASD
        .init(commandID: .resizePaneUp, keyCode: UInt16(kVK_ANSI_W), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneLeft, keyCode: UInt16(kVK_ANSI_A), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneDown, keyCode: UInt16(kVK_ANSI_S), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneRight, keyCode: UInt16(kVK_ANSI_D), keyKind: .character, modifiers: [.command, .shift]),

        // Panes
        .init(commandID: .splitHorizontally, keyCode: UInt16(kVK_ANSI_E), keyKind: .character, modifiers: [.command]),
        .init(commandID: .splitVertically, keyCode: UInt16(kVK_ANSI_R), keyKind: .character, modifiers: [.command]),
        .init(commandID: .closeFocusedPane, keyCode: UInt16(kVK_ANSI_C), keyKind: .character, modifiers: [.command]),
        .init(commandID: .copyFocusedPanePath, keyCode: UInt16(kVK_ANSI_C), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .toggleZoomOut, keyCode: UInt16(kVK_ANSI_V), keyKind: .character, modifiers: [.command, .shift]),

        // Arrange Width — Cmd+1/2/3/4
        .init(commandID: .arrangeWidthFull, keyCode: UInt16(kVK_ANSI_1), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthHalves, keyCode: UInt16(kVK_ANSI_2), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthThirds, keyCode: UInt16(kVK_ANSI_3), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthQuarters, keyCode: UInt16(kVK_ANSI_4), keyKind: .character, modifiers: [.command]),

        // Arrange Height — Cmd+Option+1/2/3/4 (Option avoids AZERTY Shift conflict)
        .init(commandID: .arrangeHeightFull, keyCode: UInt16(kVK_ANSI_1), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightTwoPerColumn, keyCode: UInt16(kVK_ANSI_2), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightThreePerColumn, keyCode: UInt16(kVK_ANSI_3), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightFourPerColumn, keyCode: UInt16(kVK_ANSI_4), keyKind: .character, modifiers: [.command, .option]),

        // Worklanes
        .init(commandID: .newWorklane, keyCode: UInt16(kVK_ANSI_T), keyKind: .character, modifiers: [.command]),
        .init(commandID: .newWorklane, keyCode: UInt16(kVK_ANSI_N), keyKind: .character, modifiers: [.command]),
        .init(commandID: .nextWorklane, keyCode: UInt16(kVK_Tab), keyKind: .tab, modifiers: [.control]),
        .init(commandID: .previousWorklane, keyCode: UInt16(kVK_Tab), keyKind: .tab, modifiers: [.control, .shift]),

        // Windows
        .init(commandID: .newWindow, keyCode: UInt16(kVK_ANSI_N), keyKind: .character, modifiers: [.command, .shift]),

        // General
        .init(commandID: .showCommandPalette, keyCode: UInt16(kVK_ANSI_F), keyKind: .character, modifiers: [.command]),
        .init(commandID: .toggleSidebar, keyCode: UInt16(kVK_ANSI_G), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateBack, keyCode: UInt16(kVK_ANSI_Z), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateForward, keyCode: UInt16(kVK_ANSI_X), keyKind: .character, modifiers: [.command]),
        .init(commandID: .jumpToLatestNotification, keyCode: UInt16(kVK_ANSI_J), keyKind: .character, modifiers: [.command]),
        .init(commandID: .openSettings, keyCode: UInt16(kVK_ANSI_Comma), keyKind: .character, modifiers: [.command]),
    ]

    // MARK: - Right-Hand Preset
    // Thumb on left/right Cmd, pinky on right Shift. Arrow keys for directional.

    private static let rightHandEntries: [ShortcutPresetEntry] = [
        // Directional — Cmd+Arrows
        .init(commandID: .focusUpInColumn, keyCode: UInt16(kVK_UpArrow), keyKind: .upArrow, modifiers: [.command]),
        .init(commandID: .focusLeftPane, keyCode: UInt16(kVK_LeftArrow), keyKind: .leftArrow, modifiers: [.command]),
        .init(commandID: .focusDownInColumn, keyCode: UInt16(kVK_DownArrow), keyKind: .downArrow, modifiers: [.command]),
        .init(commandID: .focusRightPane, keyCode: UInt16(kVK_RightArrow), keyKind: .rightArrow, modifiers: [.command]),

        // Resize — Cmd+Shift+Arrows
        .init(commandID: .resizePaneUp, keyCode: UInt16(kVK_UpArrow), keyKind: .upArrow, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneLeft, keyCode: UInt16(kVK_LeftArrow), keyKind: .leftArrow, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneDown, keyCode: UInt16(kVK_DownArrow), keyKind: .downArrow, modifiers: [.command, .shift]),
        .init(commandID: .resizePaneRight, keyCode: UInt16(kVK_RightArrow), keyKind: .rightArrow, modifiers: [.command, .shift]),

        // Panes
        .init(commandID: .splitHorizontally, keyCode: UInt16(kVK_ANSI_J), keyKind: .character, modifiers: [.command]),
        .init(commandID: .splitVertically, keyCode: UInt16(kVK_ANSI_K), keyKind: .character, modifiers: [.command]),
        .init(commandID: .closeFocusedPane, keyCode: UInt16(kVK_ANSI_L), keyKind: .character, modifiers: [.command]),
        .init(commandID: .toggleZoomOut, keyCode: UInt16(kVK_ANSI_M), keyKind: .character, modifiers: [.command]),

        // Arrange Width — Cmd+1/2/3/4
        .init(commandID: .arrangeWidthFull, keyCode: UInt16(kVK_ANSI_1), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthHalves, keyCode: UInt16(kVK_ANSI_2), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthThirds, keyCode: UInt16(kVK_ANSI_3), keyKind: .character, modifiers: [.command]),
        .init(commandID: .arrangeWidthQuarters, keyCode: UInt16(kVK_ANSI_4), keyKind: .character, modifiers: [.command]),

        // Arrange Height — Cmd+Option+1/2/3/4 (Option avoids AZERTY Shift conflict)
        .init(commandID: .arrangeHeightFull, keyCode: UInt16(kVK_ANSI_1), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightTwoPerColumn, keyCode: UInt16(kVK_ANSI_2), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightThreePerColumn, keyCode: UInt16(kVK_ANSI_3), keyKind: .character, modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightFourPerColumn, keyCode: UInt16(kVK_ANSI_4), keyKind: .character, modifiers: [.command, .option]),

        // Worklanes
        .init(commandID: .newWorklane, keyCode: UInt16(kVK_ANSI_N), keyKind: .character, modifiers: [.command]),
        .init(commandID: .nextWorklane, keyCode: UInt16(kVK_ANSI_RightBracket), keyKind: .character, modifiers: [.command]),
        .init(commandID: .previousWorklane, keyCode: UInt16(kVK_ANSI_LeftBracket), keyKind: .character, modifiers: [.command]),

        // Windows
        .init(commandID: .newWindow, keyCode: UInt16(kVK_ANSI_N), keyKind: .character, modifiers: [.command, .shift]),

        // General
        .init(commandID: .showCommandPalette, keyCode: UInt16(kVK_ANSI_Semicolon), keyKind: .character, modifiers: [.command]),
        .init(commandID: .toggleSidebar, keyCode: UInt16(kVK_ANSI_H), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateBack, keyCode: UInt16(kVK_ANSI_Comma), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateForward, keyCode: UInt16(kVK_ANSI_Period), keyKind: .character, modifiers: [.command]),
        .init(commandID: .copyFocusedPanePath, keyCode: UInt16(kVK_ANSI_L), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .jumpToLatestNotification, keyCode: UInt16(kVK_ANSI_Semicolon), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .openSettings, keyCode: UInt16(kVK_ANSI_O), keyKind: .character, modifiers: [.command]),
    ]
}
