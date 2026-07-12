import AppKit

/// The surface `AppActionRouter` dispatches into: one intent method per
/// `AppAction` case. `RootViewController` conforms in a same-file extension so
/// the verbatim case bodies keep reaching its private members.
@MainActor
protocol AppActionRouterEnvironment: AnyObject {
    func routeToggleSidebar()
    func routeNewWorklane()
    func routeRenameCurrentWorklane()
    func routeRenameCurrentPane()
    func routeNextWorklane()
    func routePreviousWorklane()
    func routeMoveWorklaneUp()
    func routeMoveWorklaneDown()
    func routeFind()
    func routeGlobalFind()
    func routeUseSelectionForFind()
    func routeFindNext()
    func routeFindPrevious()
    func routeCopyFocusedPanePath()
    func routeCleanCopy()
    func routeCopyRaw()
    func routeCopyMarkdown()
    func routeJumpToLatestNotification()
    func routePaneCommand(_ command: PaneCommand)
    func routeMoveFocusedPaneToNewWindow()
    func routeNavigateBack()
    func routeNavigateForward()
    func routeShowCommandPalette()
    func routeShowTaskManager()
    func routeOpenWithSelectedApp()
    func routeOpenSelectedServer()
    func routeOpenBranchOnRemote()
    func routeRefreshPullRequestStatus()
    func routeThemeMode(_ command: AppearanceThemeModeCommand)
    func routeOpenSettings()
    func routeNewWindow()
    func routeCloseWindow()
    func routeReloadConfig()
    func routeOpenBookmarksPopover()
}

/// Translates an `AppAction` into the matching environment call. Pure routing:
/// the pre-switch guards (focus sync, gesture cancel, availability gate) stay in
/// `RootViewController.handle(_:syncingFocusWith:)`.
@MainActor
struct AppActionRouter {
    unowned let environment: AppActionRouterEnvironment

    func route(_ action: AppAction) {
        switch action {
        case .toggleSidebar:
            environment.routeToggleSidebar()
        case .newWorklane:
            environment.routeNewWorklane()
        case .renameCurrentWorklane:
            environment.routeRenameCurrentWorklane()
        case .renameCurrentPane:
            environment.routeRenameCurrentPane()
        case .nextWorklane:
            environment.routeNextWorklane()
        case .previousWorklane:
            environment.routePreviousWorklane()
        case .moveWorklaneUp:
            environment.routeMoveWorklaneUp()
        case .moveWorklaneDown:
            environment.routeMoveWorklaneDown()
        case .find:
            environment.routeFind()
        case .globalFind:
            environment.routeGlobalFind()
        case .useSelectionForFind:
            environment.routeUseSelectionForFind()
        case .findNext:
            environment.routeFindNext()
        case .findPrevious:
            environment.routeFindPrevious()
        case .copyFocusedPanePath:
            environment.routeCopyFocusedPanePath()
        case .cleanCopy:
            environment.routeCleanCopy()
        case .copyRaw:
            environment.routeCopyRaw()
        case .copyMarkdown:
            environment.routeCopyMarkdown()
        case .jumpToLatestNotification:
            environment.routeJumpToLatestNotification()
        case .pane(let command):
            environment.routePaneCommand(command)
        case .moveFocusedPaneToNewWindow:
            environment.routeMoveFocusedPaneToNewWindow()
        case .navigateBack:
            environment.routeNavigateBack()
        case .navigateForward:
            environment.routeNavigateForward()
        case .showCommandPalette:
            environment.routeShowCommandPalette()
        case .showTaskManager:
            environment.routeShowTaskManager()
        case .openWithSelectedApp:
            environment.routeOpenWithSelectedApp()
        case .openSelectedServer:
            environment.routeOpenSelectedServer()
        case .openBranchOnRemote:
            environment.routeOpenBranchOnRemote()
        case .refreshPullRequestStatus:
            environment.routeRefreshPullRequestStatus()
        case .themeMode(let command):
            environment.routeThemeMode(command)
        case .openSettings:
            environment.routeOpenSettings()
        case .newWindow:
            environment.routeNewWindow()
        case .closeWindow:
            environment.routeCloseWindow()
        case .reloadConfig:
            environment.routeReloadConfig()
        case .openBookmarksPopover:
            environment.routeOpenBookmarksPopover()
        }
    }
}
