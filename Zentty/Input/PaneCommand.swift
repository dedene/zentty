import CoreGraphics

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

enum GoldenRatioPreset: Equatable, Sendable {
    case focusWide
    case focusNarrow
    case focusTall
    case focusShort
}

enum SplitLayoutAction: Equatable, Sendable {
    case none
    case equal
    case golden
    case ratio(CGFloat)
}

enum PaneCommand: Equatable, Sendable {
    case duplicateFocusedPane
    case split
    case splitHorizontally
    case splitVertically
    case splitVerticallyBefore
    case splitAfterFocusedPane
    case splitBeforeFocusedPane
    case closeFocusedPane
    case focusPreviousPaneBySidebarOrder
    case focusNextPaneBySidebarOrder
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
    case arrangeGoldenRatio(GoldenRatioPreset)
    case resetLayout
    case toggleZoomOut
}
