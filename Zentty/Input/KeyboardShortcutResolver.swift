enum AppAction: Equatable, Sendable {
    case newWorkspace
    case pane(PaneCommand)
}

enum KeyboardShortcutResolver {
    static func resolve(_ shortcut: KeyboardShortcut) -> AppAction? {
        switch (shortcut.key, shortcut.modifiers) {
        case (.character("t"), [.command]):
            return .newWorkspace
        case (.character("d"), [.command]):
            return .pane(.splitAfterFocusedPane)
        case (.character("d"), [.command, .shift]):
            return .pane(.splitBeforeFocusedPane)
        case (.character("w"), [.command]):
            return .pane(.closeFocusedPane)
        case (.leftArrow, [.command, .option]):
            return .pane(.focusLeft)
        case (.rightArrow, [.command, .option]):
            return .pane(.focusRight)
        case (.leftArrow, [.command, .option, .shift]):
            return .pane(.focusFirst)
        case (.rightArrow, [.command, .option, .shift]):
            return .pane(.focusLast)
        default:
            return nil
        }
    }
}
