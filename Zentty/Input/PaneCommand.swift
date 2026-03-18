enum PaneCommand: Equatable, Sendable {
    case split
    case splitHorizontally
    case splitVertically
    case splitAfterFocusedPane
    case splitBeforeFocusedPane
    case closeFocusedPane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case focusFirst
    case focusLast
    case focusFirstColumn
    case focusLastColumn
}
