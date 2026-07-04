import Foundation

struct CommandAvailabilityContext: Equatable {
    let worklaneCount: Int
    let activePaneCount: Int
    let totalPaneCount: Int
    let activeColumnCount: Int
    let focusedColumnPaneCount: Int
    let focusedPaneHasRememberedSearch: Bool
    let globalSearchHasRememberedSearch: Bool
    let activeWorklaneHasBranchURL: Bool
    let focusedPaneCanOpenWithPrimary: Bool
    let activeWorklaneHasPrimaryServer: Bool

    init(
        worklaneCount: Int,
        activePaneCount: Int,
        totalPaneCount: Int,
        activeColumnCount: Int,
        focusedColumnPaneCount: Int,
        focusedPaneHasRememberedSearch: Bool,
        globalSearchHasRememberedSearch: Bool,
        activeWorklaneHasBranchURL: Bool,
        focusedPaneCanOpenWithPrimary: Bool = false,
        activeWorklaneHasPrimaryServer: Bool = false
    ) {
        self.worklaneCount = worklaneCount
        self.activePaneCount = activePaneCount
        self.totalPaneCount = totalPaneCount
        self.activeColumnCount = activeColumnCount
        self.focusedColumnPaneCount = focusedColumnPaneCount
        self.focusedPaneHasRememberedSearch = focusedPaneHasRememberedSearch
        self.globalSearchHasRememberedSearch = globalSearchHasRememberedSearch
        self.activeWorklaneHasBranchURL = activeWorklaneHasBranchURL
        self.focusedPaneCanOpenWithPrimary = focusedPaneCanOpenWithPrimary
        self.activeWorklaneHasPrimaryServer = activeWorklaneHasPrimaryServer
    }
}

enum CommandAvailabilityResolver {
    static func availableCommandIDs(
        worklaneCount: Int,
        activePaneCount: Int,
        totalPaneCount: Int,
        activeColumnCount: Int? = nil,
        focusedColumnPaneCount: Int? = nil,
        focusedPaneHasRememberedSearch: Bool = false,
        activeWorklaneHasBranchURL: Bool = false,
        focusedPaneCanOpenWithPrimary: Bool = false,
        activeWorklaneHasPrimaryServer: Bool = false
    ) -> Set<AppCommandID> {
        availableCommandIDs(
            worklaneCount: worklaneCount,
            activePaneCount: activePaneCount,
            totalPaneCount: totalPaneCount,
            activeColumnCount: activeColumnCount,
            focusedColumnPaneCount: focusedColumnPaneCount,
            focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
            globalSearchHasRememberedSearch: false,
            activeWorklaneHasBranchURL: activeWorklaneHasBranchURL,
            focusedPaneCanOpenWithPrimary: focusedPaneCanOpenWithPrimary,
            activeWorklaneHasPrimaryServer: activeWorklaneHasPrimaryServer
        )
    }

    static func availableCommandIDs(
        worklaneCount: Int,
        activePaneCount: Int,
        totalPaneCount: Int,
        activeColumnCount: Int? = nil,
        focusedColumnPaneCount: Int? = nil,
        focusedPaneHasRememberedSearch: Bool = false,
        globalSearchHasRememberedSearch: Bool = false,
        activeWorklaneHasBranchURL: Bool = false,
        focusedPaneCanOpenWithPrimary: Bool = false,
        activeWorklaneHasPrimaryServer: Bool = false
    ) -> Set<AppCommandID> {
        availableCommandIDs(
            for: CommandAvailabilityContext(
                worklaneCount: worklaneCount,
                activePaneCount: activePaneCount,
                totalPaneCount: totalPaneCount,
                activeColumnCount: activeColumnCount ?? activePaneCount,
                focusedColumnPaneCount: focusedColumnPaneCount ?? activePaneCount,
                focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
                globalSearchHasRememberedSearch: globalSearchHasRememberedSearch,
                activeWorklaneHasBranchURL: activeWorklaneHasBranchURL,
                focusedPaneCanOpenWithPrimary: focusedPaneCanOpenWithPrimary,
                activeWorklaneHasPrimaryServer: activeWorklaneHasPrimaryServer
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
        case .openWithSelectedApp:
            return context.focusedPaneCanOpenWithPrimary
        case .openSelectedServer:
            return context.activeWorklaneHasPrimaryServer
        case .openBranchOnRemote:
            return context.activeWorklaneHasBranchURL
        case .findNext, .findPrevious:
            return context.focusedPaneHasRememberedSearch || context.globalSearchHasRememberedSearch
        case .focusPreviousPane, .focusNextPane:
            return context.totalPaneCount > 1
        case .closeFocusedPane:
            // Available whenever there's a pane to close — closing the last
            // pane in the last worklane closes the window.
            return context.activePaneCount >= 1
        case .duplicateFocusedPane:
            return context.activePaneCount >= 1
        case .movePaneToNewWindow:
            return context.activePaneCount >= 1
                && !(context.worklaneCount == 1 && context.activePaneCount == 1)
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
        case .arrangeWidthFull:
            return context.activePaneCount >= 2
        case .arrangeWidthHalves:
            return context.activeColumnCount >= 2
        case .arrangeWidthThirds:
            return context.activeColumnCount >= 3
        case .arrangeWidthQuarters:
            return context.activeColumnCount >= 4
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
        case .worklaneMoveUp, .worklaneMoveDown:
            return context.worklaneCount > 1
        case .renameCurrentWorklane:
            return context.worklaneCount >= 1
        case .renameCurrentPane:
            return context.activePaneCount >= 1
        case .nextWorklane, .previousWorklane:
            // The Worklane Peek handles the single-worklane case (hold opens
            // peek for in-lane pane picking), so keep these available
            // regardless of worklane count. The controller's instant-switch
            // path is a no-op when there's nothing to switch to.
            return true
        default:
            return true
        }
    }
}
