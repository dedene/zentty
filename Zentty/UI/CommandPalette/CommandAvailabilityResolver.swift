import Foundation

struct CommandAvailabilityContext: Equatable {
    let worklaneCount: Int
    let activePaneCount: Int
    let totalPaneCount: Int
    let activeColumnCount: Int
    let focusedColumnPaneCount: Int
    let focusedPaneHasRememberedSearch: Bool
    let globalSearchHasRememberedSearch: Bool
}

enum CommandAvailabilityResolver {
    static func availableCommandIDs(
        worklaneCount: Int,
        activePaneCount: Int,
        totalPaneCount: Int,
        activeColumnCount: Int? = nil,
        focusedColumnPaneCount: Int? = nil,
        focusedPaneHasRememberedSearch: Bool = false
    ) -> Set<AppCommandID> {
        availableCommandIDs(
            worklaneCount: worklaneCount,
            activePaneCount: activePaneCount,
            totalPaneCount: totalPaneCount,
            activeColumnCount: activeColumnCount,
            focusedColumnPaneCount: focusedColumnPaneCount,
            focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
            globalSearchHasRememberedSearch: false
        )
    }

    static func availableCommandIDs(
        worklaneCount: Int,
        activePaneCount: Int,
        totalPaneCount: Int,
        activeColumnCount: Int? = nil,
        focusedColumnPaneCount: Int? = nil,
        focusedPaneHasRememberedSearch: Bool = false,
        globalSearchHasRememberedSearch: Bool = false
    ) -> Set<AppCommandID> {
        availableCommandIDs(
            for: CommandAvailabilityContext(
                worklaneCount: worklaneCount,
                activePaneCount: activePaneCount,
                totalPaneCount: totalPaneCount,
                activeColumnCount: activeColumnCount ?? activePaneCount,
                focusedColumnPaneCount: focusedColumnPaneCount ?? activePaneCount,
                focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
                globalSearchHasRememberedSearch: globalSearchHasRememberedSearch
            )
        )
    }

    static func availableCommandIDs(for context: CommandAvailabilityContext) -> Set<AppCommandID> {
        var available = Set(AppCommandID.allCases.filter { isCommandAvailable($0, for: context) })
        available.remove(.showCommandPalette)
        return available
    }

    static func isCommandAvailable(_ commandID: AppCommandID, for context: CommandAvailabilityContext) -> Bool {
        switch commandID {
        case .findNext, .findPrevious:
            return context.focusedPaneHasRememberedSearch || context.globalSearchHasRememberedSearch
        case .focusPreviousPane, .focusNextPane:
            return context.totalPaneCount > 1
        case .closeFocusedPane:
            // Available whenever there's a pane to close — closing the last
            // pane in the last worklane closes the window.
            return context.activePaneCount >= 1
        case .focusLeftPane,
             .focusRightPane,
             .resizePaneLeft,
             .resizePaneRight,
             .resizePaneUp,
             .resizePaneDown,
             .resetPaneLayout:
            return context.activePaneCount > 1
        case .focusUpInColumn, .focusDownInColumn:
            return context.activePaneCount > 1 || context.worklaneCount > 1
        case .arrangeWidthFull, .arrangeWidthHalves:
            return context.activePaneCount >= 2
        case .arrangeWidthThirds:
            return context.activePaneCount >= 3
        case .arrangeWidthQuarters:
            return context.activePaneCount >= 4
        case .arrangeHeightFull, .arrangeHeightTwoPerColumn:
            return context.activePaneCount >= 2
        case .arrangeHeightThreePerColumn:
            return context.activePaneCount >= 3
        case .arrangeHeightFourPerColumn:
            return context.activePaneCount >= 4
        case .arrangeWidthGoldenFocusWide, .arrangeWidthGoldenFocusNarrow:
            return context.activeColumnCount >= 2
        case .arrangeHeightGoldenFocusTall, .arrangeHeightGoldenFocusShort:
            return context.focusedColumnPaneCount >= 2
        case .nextWorklane, .previousWorklane:
            return context.worklaneCount > 1
        default:
            return true
        }
    }
}
