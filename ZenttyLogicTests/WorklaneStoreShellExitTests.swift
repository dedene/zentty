import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreShellExitTests: XCTestCase {

    // MARK: - Multi-pane worklane

    func test_shell_exit_removes_pane_from_multi_pane_worklane() throws {
        let store = WorklaneStore()
        store.send(.splitAfterFocusedPane)
        let paneToClose = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)

        let result = store.closePaneFromShellExit(id: paneToClose)

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertFalse(store.activeWorklane?.paneStripState.panes.contains(where: { $0.id == paneToClose }) ?? true)
    }

    // MARK: - Non-active worklane

    func test_shell_exit_removes_pane_from_non_active_worklane() throws {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("api"),
                    title: "API",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("api-shell"), title: "shell"),
                            PaneState(id: PaneID("api-logs"), title: "logs"),
                        ],
                        focusedPaneID: PaneID("api-shell")
                    ),
                    nextPaneNumber: 1
                ),
                WorklaneState(
                    id: WorklaneID("web"),
                    title: "WEB",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("web-shell"), title: "shell")],
                        focusedPaneID: PaneID("web-shell")
                    ),
                    nextPaneNumber: 1
                ),
            ],
            activeWorklaneID: WorklaneID("web")
        )

        let result = store.closePaneFromShellExit(id: PaneID("api-logs"))

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("web"))
        let apiWorklane = try XCTUnwrap(store.worklanes.first(where: { $0.id == WorklaneID("api") }))
        XCTAssertEqual(apiWorklane.paneStripState.panes.map(\.id), [PaneID("api-shell")])
    }

    // MARK: - Last pane removes worklane

    func test_shell_exit_closes_worklane_when_last_pane_and_other_worklanes_exist() throws {
        let store = WorklaneStore()
        store.createWorklane()
        let ws1ID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "WS 1" })?.id)
        let mainID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "MAIN" })?.id)

        store.selectWorklane(id: ws1ID)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        let result = store.closePaneFromShellExit(id: paneID)

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorklaneID, mainID)
    }

    func test_shell_exit_closes_non_active_worklane_when_last_pane() throws {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("main-shell"), title: "shell")],
                        focusedPaneID: PaneID("main-shell")
                    ),
                    nextPaneNumber: 1
                ),
                WorklaneState(
                    id: WorklaneID("scratch"),
                    title: "SCRATCH",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("scratch-shell"), title: "shell")],
                        focusedPaneID: PaneID("scratch-shell")
                    ),
                    nextPaneNumber: 1
                ),
            ],
            activeWorklaneID: WorklaneID("main")
        )

        let result = store.closePaneFromShellExit(id: PaneID("scratch-shell"))

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.map(\.id), [WorklaneID("main")])
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("main"))
    }

    // MARK: - Last worklane signals quit

    func test_shell_exit_requests_window_close_when_last_pane_in_last_worklane() {
        let store = WorklaneStore()
        let paneID = store.activeWorklane!.paneStripState.focusedPaneID!

        let result = store.closePaneFromShellExit(id: paneID)

        XCTAssertEqual(result, .closeWindow)
    }

    func test_shell_exit_clears_auxiliary_state_before_window_close() {
        let store = WorklaneStore()
        let paneID = store.activeWorklane!.paneStripState.focusedPaneID!

        store.handleTerminalEvent(paneID: paneID, event: .userSubmittedInput)

        let result = store.closePaneFromShellExit(id: paneID)

        XCTAssertEqual(result, .closeWindow)
        XCTAssertFalse(store.anyPaneRequiresQuitConfirmation)
    }

    func test_terminal_progress_requires_quit_confirmation() {
        let paneID = PaneID("main-shell")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: paneID, title: "shell")],
                        focusedPaneID: paneID
                    ),
                    terminalProgressByPaneID: [
                        paneID: TerminalProgressReport(state: .indeterminate, progress: nil)
                    ]
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        XCTAssertEqual(store.paneCloseConfirmationReason(paneID), .runningProcess)
        XCTAssertTrue(store.anyPaneRequiresQuitConfirmation)
    }

    // MARK: - Not found

    func test_shell_exit_returns_not_found_for_unknown_pane() {
        let store = WorklaneStore()

        let result = store.closePaneFromShellExit(id: PaneID("does-not-exist"))

        XCTAssertEqual(result, .notFound)
    }

    // MARK: - Active worklane switching

    func test_shell_exit_switches_active_to_adjacent_worklane_when_middle_removed() throws {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("w1"),
                    title: "W1",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("p1"), title: "shell")],
                        focusedPaneID: PaneID("p1")
                    ),
                    nextPaneNumber: 1
                ),
                WorklaneState(
                    id: WorklaneID("w2"),
                    title: "W2",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("p2"), title: "shell")],
                        focusedPaneID: PaneID("p2")
                    ),
                    nextPaneNumber: 1
                ),
                WorklaneState(
                    id: WorklaneID("w3"),
                    title: "W3",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("p3"), title: "shell")],
                        focusedPaneID: PaneID("p3")
                    ),
                    nextPaneNumber: 1
                ),
            ],
            activeWorklaneID: WorklaneID("w2")
        )

        let result = store.closePaneFromShellExit(id: PaneID("p2"))

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.map(\.id), [WorklaneID("w1"), WorklaneID("w3")])
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("w1"))
    }
}
