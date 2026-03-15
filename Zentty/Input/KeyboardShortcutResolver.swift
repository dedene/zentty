enum KeyboardShortcutResolver {
    static func resolve(_ shortcut: KeyboardShortcut) -> PaneCommand? {
        switch (shortcut.key, shortcut.modifiers) {
        case (.character("d"), [.command]):
            return .splitAfterFocusedPane
        case (.character("d"), [.command, .shift]):
            return .splitBeforeFocusedPane
        case (.character("w"), [.command]):
            return .closeFocusedPane
        case (.leftArrow, [.command, .option]):
            return .focusLeft
        case (.rightArrow, [.command, .option]):
            return .focusRight
        case (.leftArrow, [.command, .option, .shift]):
            return .focusFirst
        case (.rightArrow, [.command, .option, .shift]):
            return .focusLast
        default:
            return nil
        }
    }
}
