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
            return .pane(.splitHorizontally)
        case (.character("d"), [.command, .shift]):
            return .pane(.splitVertically)
        case (.character("w"), [.command]):
            return .pane(.closeFocusedPane)
        case (.leftArrow, [.command, .option]):
            return .pane(.focusLeft)
        case (.rightArrow, [.command, .option]):
            return .pane(.focusRight)
        case (.upArrow, [.command, .option]):
            return .pane(.focusUp)
        case (.downArrow, [.command, .option]):
            return .pane(.focusDown)
        case (.leftArrow, [.command, .option, .shift]):
            return .pane(.focusFirstColumn)
        case (.rightArrow, [.command, .option, .shift]):
            return .pane(.focusLastColumn)
        case (.leftArrow, [.command, .control, .option]):
            return .pane(.resizeLeft)
        case (.rightArrow, [.command, .control, .option]):
            return .pane(.resizeRight)
        case (.upArrow, [.command, .control, .option]):
            return .pane(.resizeUp)
        case (.downArrow, [.command, .control, .option]):
            return .pane(.resizeDown)
        default:
            return nil
        }
    }
}
