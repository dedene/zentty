enum PaneHorizontalArrangement: Int, CaseIterable, Equatable, Sendable {
    case fullWidth = 1
    case halfWidth = 2
    case thirds = 3
    case quarters = 4

    var visibleColumnCount: Int { rawValue }
}

enum PaneVerticalArrangement: Int, CaseIterable, Equatable, Sendable {
    case fullHeight = 1
    case twoPerColumn = 2
    case threePerColumn = 3
    case fourPerColumn = 4

    var panesPerColumn: Int { rawValue }
}

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
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case arrangeHorizontally(PaneHorizontalArrangement)
    case arrangeVertically(PaneVerticalArrangement)
    case resetLayout
}
