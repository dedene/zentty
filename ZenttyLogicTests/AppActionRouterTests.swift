import XCTest
@testable import Zentty

@MainActor
final class AppActionRouterTests: XCTestCase {

    // Exhaustive routing table: every `AppAction` must dispatch to exactly one
    // environment method. Adding an `AppAction` case without wiring it here (and
    // in `AppActionRouter`) is a compile error, keeping the table in lockstep.
    func test_routing_table_dispatches_each_action_to_its_environment_method() {
        let cases: [(AppAction, String)] = [
            (.toggleSidebar, "routeToggleSidebar"),
            (.newWorklane, "routeNewWorklane"),
            (.renameCurrentWorklane, "routeRenameCurrentWorklane"),
            (.renameCurrentPane, "routeRenameCurrentPane"),
            (.nextWorklane, "routeNextWorklane"),
            (.previousWorklane, "routePreviousWorklane"),
            (.moveWorklaneUp, "routeMoveWorklaneUp"),
            (.moveWorklaneDown, "routeMoveWorklaneDown"),
            (.find, "routeFind"),
            (.globalFind, "routeGlobalFind"),
            (.useSelectionForFind, "routeUseSelectionForFind"),
            (.findNext, "routeFindNext"),
            (.findPrevious, "routeFindPrevious"),
            (.copyFocusedPanePath, "routeCopyFocusedPanePath"),
            (.cleanCopy, "routeCleanCopy"),
            (.copyRaw, "routeCopyRaw"),
            (.copyMarkdown, "routeCopyMarkdown"),
            (.jumpToLatestNotification, "routeJumpToLatestNotification"),
            (.pane(.resetLayout), "routePaneCommand"),
            (.moveFocusedPaneToNewWindow, "routeMoveFocusedPaneToNewWindow"),
            (.navigateBack, "routeNavigateBack"),
            (.navigateForward, "routeNavigateForward"),
            (.showCommandPalette, "routeShowCommandPalette"),
            (.showTaskManager, "routeShowTaskManager"),
            (.openWithSelectedApp, "routeOpenWithSelectedApp"),
            (.openSelectedServer, "routeOpenSelectedServer"),
            (.openBranchOnRemote, "routeOpenBranchOnRemote"),
            (.refreshPullRequestStatus, "routeRefreshPullRequestStatus"),
            (.themeMode(.toggle), "routeThemeMode"),
            (.openSettings, "routeOpenSettings"),
            (.newWindow, "routeNewWindow"),
            (.closeWindow, "routeCloseWindow"),
            (.reloadConfig, "routeReloadConfig"),
            (.openBookmarksPopover, "routeOpenBookmarksPopover"),
        ]

        for (action, expected) in cases {
            let env = MockEnvironment()
            let router = AppActionRouter(environment: env)

            router.route(action)

            XCTAssertEqual(env.calls, [expected], "unexpected routing for \(action)")
        }
    }

    func test_pane_command_is_funneled_verbatim() {
        let env = MockEnvironment()
        let router = AppActionRouter(environment: env)

        router.route(.pane(.resizeRight))

        XCTAssertEqual(env.calls, ["routePaneCommand"])
        XCTAssertEqual(env.lastPaneCommand, .resizeRight)
    }

    func test_theme_mode_command_is_funneled_verbatim() {
        let env = MockEnvironment()
        let router = AppActionRouter(environment: env)

        router.route(.themeMode(.dark))

        XCTAssertEqual(env.calls, ["routeThemeMode"])
        XCTAssertEqual(env.lastThemeMode, .dark)
    }
}

@MainActor
private final class MockEnvironment: AppActionRouterEnvironment {
    private(set) var calls: [String] = []
    private(set) var lastPaneCommand: PaneCommand?
    private(set) var lastThemeMode: AppearanceThemeModeCommand?

    func routeToggleSidebar() { calls.append("routeToggleSidebar") }
    func routeNewWorklane() { calls.append("routeNewWorklane") }
    func routeRenameCurrentWorklane() { calls.append("routeRenameCurrentWorklane") }
    func routeRenameCurrentPane() { calls.append("routeRenameCurrentPane") }
    func routeNextWorklane() { calls.append("routeNextWorklane") }
    func routePreviousWorklane() { calls.append("routePreviousWorklane") }
    func routeMoveWorklaneUp() { calls.append("routeMoveWorklaneUp") }
    func routeMoveWorklaneDown() { calls.append("routeMoveWorklaneDown") }
    func routeFind() { calls.append("routeFind") }
    func routeGlobalFind() { calls.append("routeGlobalFind") }
    func routeUseSelectionForFind() { calls.append("routeUseSelectionForFind") }
    func routeFindNext() { calls.append("routeFindNext") }
    func routeFindPrevious() { calls.append("routeFindPrevious") }
    func routeCopyFocusedPanePath() { calls.append("routeCopyFocusedPanePath") }
    func routeCleanCopy() { calls.append("routeCleanCopy") }
    func routeCopyRaw() { calls.append("routeCopyRaw") }
    func routeCopyMarkdown() { calls.append("routeCopyMarkdown") }
    func routeJumpToLatestNotification() { calls.append("routeJumpToLatestNotification") }
    func routePaneCommand(_ command: PaneCommand) {
        calls.append("routePaneCommand")
        lastPaneCommand = command
    }
    func routeMoveFocusedPaneToNewWindow() { calls.append("routeMoveFocusedPaneToNewWindow") }
    func routeNavigateBack() { calls.append("routeNavigateBack") }
    func routeNavigateForward() { calls.append("routeNavigateForward") }
    func routeShowCommandPalette() { calls.append("routeShowCommandPalette") }
    func routeShowTaskManager() { calls.append("routeShowTaskManager") }
    func routeOpenWithSelectedApp() { calls.append("routeOpenWithSelectedApp") }
    func routeOpenSelectedServer() { calls.append("routeOpenSelectedServer") }
    func routeOpenBranchOnRemote() { calls.append("routeOpenBranchOnRemote") }
    func routeRefreshPullRequestStatus() { calls.append("routeRefreshPullRequestStatus") }
    func routeThemeMode(_ command: AppearanceThemeModeCommand) {
        calls.append("routeThemeMode")
        lastThemeMode = command
    }
    func routeOpenSettings() { calls.append("routeOpenSettings") }
    func routeNewWindow() { calls.append("routeNewWindow") }
    func routeCloseWindow() { calls.append("routeCloseWindow") }
    func routeReloadConfig() { calls.append("routeReloadConfig") }
    func routeOpenBookmarksPopover() { calls.append("routeOpenBookmarksPopover") }
}
