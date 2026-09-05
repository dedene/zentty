import Carbon.HIToolbox

enum ShortcutPreset: String, CaseIterable, Sendable {
    case leftHand
    case rightHand
    case ghosttyCompatible

    var title: String {
        switch self {
        case .leftHand:
            "Left-Hand Preset"
        case .rightHand:
            "Right-Hand Preset"
        case .ghosttyCompatible:
            "Ghostty-Compatible Preset"
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
        case .ghosttyCompatible:
            "This replaces your current shortcut bindings with Ghostty-compatible macOS shortcuts while keeping non-conflicting Zentty shortcuts."
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
        switch entry.key {
        case .logical(let key):
            return key
        case .physical(let keyCode, let keyKind):
            return resolvePhysicalKey(keyCode: keyCode, keyKind: keyKind)
        }
    }

    private func resolvePhysicalKey(
        keyCode: UInt16,
        keyKind: ShortcutPresetKeyKind
    ) -> KeyboardShortcutKey? {
        switch keyKind {
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
            if isNumberRowKeyCode(keyCode) {
                return resolveNumberRowKey(keyCode: keyCode)
            }
            guard let character = sourceProvider.output(for: keyCode, modifiers: []) else {
                return nil
            }
            return .character(character.lowercased())
        }
    }

    private func resolveModifiers(for entry: ShortcutPresetEntry) -> Set<KeyboardModifier> {
        guard case .physical(let keyCode, .character) = entry.key,
              isNumberRowKeyCode(keyCode) else {
            return entry.modifiers
        }
        guard let unshifted = sourceProvider.output(for: keyCode, modifiers: []) else {
            return entry.modifiers
        }
        let isDigitByDefault = unshifted.count == 1 && unshifted.first?.isNumber == true
        if isDigitByDefault {
            return entry.modifiers
        }
        return entry.modifiers.union([.shift])
    }

    private func resolveNumberRowKey(keyCode: UInt16) -> KeyboardShortcutKey? {
        if let unshifted = sourceProvider.output(for: keyCode, modifiers: []),
           unshifted.count == 1, unshifted.first?.isNumber == true {
            return .character(unshifted)
        }
        if let shifted = sourceProvider.output(for: keyCode, modifiers: [.shift]),
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

enum ShortcutPresetEntryKey {
    case physical(keyCode: UInt16, kind: ShortcutPresetKeyKind)
    case logical(KeyboardShortcutKey)
}

struct ShortcutPresetEntry {
    let commandID: AppCommandID
    let key: ShortcutPresetEntryKey
    let modifiers: Set<KeyboardModifier>

    init(
        commandID: AppCommandID,
        keyCode: UInt16,
        keyKind: ShortcutPresetKeyKind,
        modifiers: Set<KeyboardModifier>
    ) {
        self.commandID = commandID
        key = .physical(keyCode: keyCode, kind: keyKind)
        self.modifiers = modifiers
    }

    init(
        commandID: AppCommandID,
        key: KeyboardShortcutKey,
        modifiers: Set<KeyboardModifier>
    ) {
        self.commandID = commandID
        self.key = .logical(key)
        self.modifiers = modifiers
    }
}

extension ShortcutPreset {
    var entries: [ShortcutPresetEntry] {
        switch self {
        case .leftHand:
            Self.leftHandEntries
        case .rightHand:
            Self.rightHandEntries
        case .ghosttyCompatible:
            Self.ghosttyCompatibleEntries
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
        .init(commandID: .useSelectionForFind, keyCode: UInt16(kVK_ANSI_E), keyKind: .character, modifiers: [.command]),
        .init(commandID: .find, keyCode: UInt16(kVK_ANSI_F), keyKind: .character, modifiers: [.command]),
        .init(commandID: .findNext, keyCode: UInt16(kVK_ANSI_G), keyKind: .character, modifiers: [.command]),
        .init(commandID: .findPrevious, keyCode: UInt16(kVK_ANSI_G), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .splitHorizontally, keyCode: UInt16(kVK_ANSI_R), keyKind: .character, modifiers: [.command]),
        .init(commandID: .splitVertically, keyCode: UInt16(kVK_ANSI_R), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .closeFocusedPane, keyCode: UInt16(kVK_ANSI_C), keyKind: .character, modifiers: [.command]),
        .init(commandID: .copyFocusedPanePath, keyCode: UInt16(kVK_ANSI_C), keyKind: .character, modifiers: [.command, .shift]),

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
        .init(commandID: .nextWorklane, keyCode: UInt16(kVK_Tab), keyKind: .tab, modifiers: [.control]),
        .init(commandID: .previousWorklane, keyCode: UInt16(kVK_Tab), keyKind: .tab, modifiers: [.control, .shift]),

        // Windows
        .init(commandID: .newWindow, keyCode: UInt16(kVK_ANSI_N), keyKind: .character, modifiers: [.command, .shift]),

        // General
        .init(commandID: .showCommandPalette, keyCode: UInt16(kVK_ANSI_X), keyKind: .character, modifiers: [.command]),
        .init(commandID: .toggleSidebar, keyCode: UInt16(kVK_ANSI_B), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateBack, keyCode: UInt16(kVK_ANSI_LeftBracket), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateForward, keyCode: UInt16(kVK_ANSI_RightBracket), keyKind: .character, modifiers: [.command]),
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
        .init(commandID: .useSelectionForFind, keyCode: UInt16(kVK_ANSI_E), keyKind: .character, modifiers: [.command]),
        .init(commandID: .find, keyCode: UInt16(kVK_ANSI_F), keyKind: .character, modifiers: [.command]),
        .init(commandID: .findNext, keyCode: UInt16(kVK_ANSI_G), keyKind: .character, modifiers: [.command]),
        .init(commandID: .findPrevious, keyCode: UInt16(kVK_ANSI_G), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .showCommandPalette, keyCode: UInt16(kVK_ANSI_Semicolon), keyKind: .character, modifiers: [.command]),
        .init(commandID: .toggleSidebar, keyCode: UInt16(kVK_ANSI_H), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateBack, keyCode: UInt16(kVK_ANSI_Comma), keyKind: .character, modifiers: [.command]),
        .init(commandID: .navigateForward, keyCode: UInt16(kVK_ANSI_Period), keyKind: .character, modifiers: [.command]),
        .init(commandID: .copyFocusedPanePath, keyCode: UInt16(kVK_ANSI_L), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .jumpToLatestNotification, keyCode: UInt16(kVK_ANSI_Semicolon), keyKind: .character, modifiers: [.command, .shift]),
        .init(commandID: .openSettings, keyCode: UInt16(kVK_ANSI_O), keyKind: .character, modifiers: [.command]),
    ]

    // MARK: - Ghostty-Compatible Preset
    // Curated against Ghostty's macOS defaults at scripts/ghosttykit.lock.
    // Logical keys match Ghostty's character-based bindings on non-US layouts.

    private static let ghosttyCompatibleEntries: [ShortcutPresetEntry] = [
        // Windows and worklanes (Ghostty windows and tabs)
        .init(commandID: .newWindow, key: .character("n"), modifiers: [.command]),
        .init(commandID: .closeWindow, key: .character("w"), modifiers: [.command, .shift]),
        .init(commandID: .newWorklane, key: .character("t"), modifiers: [.command]),
        .init(commandID: .nextWorklane, key: .tab, modifiers: [.control]),
        .init(commandID: .previousWorklane, key: .tab, modifiers: [.control, .shift]),

        // Ghostty binds ⌘1–⌘8 to goto_tab and ⌘9 to last_tab; worklanes are Zentty's tabs.
        // ⌘9 maps to worklane 9 (not "last") so every digit means the same thing.
        .init(commandID: .selectWorklane1, key: .character("1"), modifiers: [.command]),
        .init(commandID: .selectWorklane2, key: .character("2"), modifiers: [.command]),
        .init(commandID: .selectWorklane3, key: .character("3"), modifiers: [.command]),
        .init(commandID: .selectWorklane4, key: .character("4"), modifiers: [.command]),
        .init(commandID: .selectWorklane5, key: .character("5"), modifiers: [.command]),
        .init(commandID: .selectWorklane6, key: .character("6"), modifiers: [.command]),
        .init(commandID: .selectWorklane7, key: .character("7"), modifiers: [.command]),
        .init(commandID: .selectWorklane8, key: .character("8"), modifiers: [.command]),
        .init(commandID: .selectWorklane9, key: .character("9"), modifiers: [.command]),

        // Panes (Ghostty surfaces and splits)
        .init(commandID: .closeFocusedPane, key: .character("w"), modifiers: [.command]),
        .init(commandID: .restoreClosedPane, key: .character("t"), modifiers: [.command, .shift]),
        .init(commandID: .splitHorizontally, key: .character("d"), modifiers: [.command]),
        .init(commandID: .splitVertically, key: .character("d"), modifiers: [.command, .shift]),
        .init(commandID: .focusPreviousPane, key: .character("["), modifiers: [.command]),
        .init(commandID: .focusNextPane, key: .character("]"), modifiers: [.command]),
        .init(commandID: .focusLeftPane, key: .leftArrow, modifiers: [.command, .option]),
        .init(commandID: .focusRightPane, key: .rightArrow, modifiers: [.command, .option]),
        .init(commandID: .focusUpInColumn, key: .upArrow, modifiers: [.command, .option]),
        .init(commandID: .focusDownInColumn, key: .downArrow, modifiers: [.command, .option]),
        .init(commandID: .resizePaneLeft, key: .leftArrow, modifiers: [.command, .control]),
        .init(commandID: .resizePaneRight, key: .rightArrow, modifiers: [.command, .control]),
        .init(commandID: .resizePaneUp, key: .upArrow, modifiers: [.command, .control]),
        .init(commandID: .resizePaneDown, key: .downArrow, modifiers: [.command, .control]),

        // Search and configuration
        .init(commandID: .find, key: .character("f"), modifiers: [.command]),
        .init(commandID: .useSelectionForFind, key: .character("e"), modifiers: [.command]),
        .init(commandID: .findNext, key: .character("g"), modifiers: [.command]),
        .init(commandID: .findPrevious, key: .character("g"), modifiers: [.command, .shift]),
        .init(commandID: .showCommandPalette, key: .character("p"), modifiers: [.command, .shift]),
        .init(commandID: .openSettings, key: .character(","), modifiers: [.command]),
        .init(commandID: .reloadConfig, key: .character(","), modifiers: [.command, .shift]),

        // Non-conflicting Zentty shortcuts
        .init(commandID: .toggleSidebar, key: .character("s"), modifiers: [.command]),
        .init(commandID: .copyFocusedPanePath, key: .character("c"), modifiers: [.command, .shift]),
        .init(commandID: .cleanCopy, key: .character("c"), modifiers: [.command, .control]),
        .init(commandID: .jumpToLatestNotification, key: .character("u"), modifiers: [.command, .shift]),
        .init(commandID: .arrangeHeightFull, key: .character("1"), modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightTwoPerColumn, key: .character("2"), modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightThreePerColumn, key: .character("3"), modifiers: [.command, .option]),
        .init(commandID: .arrangeHeightFourPerColumn, key: .character("4"), modifiers: [.command, .option]),
        .init(commandID: .arrangeWidthGoldenFocusWide, key: .character("g"), modifiers: [.command, .control]),
        .init(commandID: .arrangeWidthGoldenFocusNarrow, key: .character("g"), modifiers: [.command, .control, .option]),
        .init(commandID: .arrangeHeightGoldenFocusTall, key: .character("g"), modifiers: [.command, .control, .shift]),
        .init(commandID: .arrangeHeightGoldenFocusShort, key: .character("g"), modifiers: [.command, .control, .option, .shift]),
        .init(commandID: .movePaneLeft, key: .leftArrow, modifiers: [.command, .control, .option]),
        .init(commandID: .movePaneRight, key: .rightArrow, modifiers: [.command, .control, .option]),
        .init(commandID: .movePaneUp, key: .upArrow, modifiers: [.command, .control, .option]),
        .init(commandID: .movePaneDown, key: .downArrow, modifiers: [.command, .control, .option]),
        .init(commandID: .resetPaneLayout, key: .character("0"), modifiers: [.command, .control, .option]),
        .init(commandID: .openBookmarksPopover, key: .character("b"), modifiers: [.command, .shift]),
    ]
}
