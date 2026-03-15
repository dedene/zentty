enum PaneCommand: Equatable, Sendable {
    case split
    case splitAfterFocusedPane
    case splitBeforeFocusedPane
    case closeFocusedPane
    case focusLeft
    case focusRight
    case focusFirst
    case focusLast
}
