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

    func test_shell_exit_reexpands_remaining_columns_to_fill_readable_width() {
        let layoutContext = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1500,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
        let worklaneID = WorklaneID("main")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("left"), title: "left")],
                                width: 300,
                                focusedPaneID: PaneID("left"),
                                lastFocusedPaneID: PaneID("left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("middle"),
                                panes: [PaneState(id: PaneID("middle"), title: "middle")],
                                width: 500,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("right"), title: "right")],
                                width: 700,
                                focusedPaneID: PaneID("right"),
                                lastFocusedPaneID: PaneID("right")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("middle")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: worklaneID
        )

        let result = store.closePaneFromShellExit(id: PaneID("middle"))

        XCTAssertEqual(result, .closed)
        let widths = store.activeWorklane?.paneStripState.columns.map(\.width) ?? []
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0] / widths[1], 3 / 7, accuracy: 0.001)
        XCTAssertEqual(widths.reduce(0, +) + layoutContext.sizing.interPaneSpacing, layoutContext.availableWidth, accuracy: 0.001)
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
        let ws1ID = try XCTUnwrap(store.worklanes.last?.id)
        let mainID = try XCTUnwrap(store.worklanes.first?.id)

        store.selectWorklane(id: ws1ID)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        let result = store.closePaneFromShellExit(id: paneID)

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.map(\.title), [nil])
        XCTAssertEqual(store.activeWorklaneID, mainID)
    }

    func test_shell_exit_closes_non_active_worklane_when_last_pane() throws {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: nil,
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
                    title: nil,
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

        XCTAssertEqual(store.paneCloseConfirmationContext(paneID)?.reason, .runningProcess)
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

    // MARK: - Quit confirmation / command history (#97)

    func test_fresh_pane_does_not_require_quit_confirmation() {
        let store = WorklaneStore()

        XCTAssertFalse(store.anyPaneRequiresQuitConfirmation)
        XCTAssertFalse(store.anyPaneHasRunningProcessForQuitConfirmation)
        XCTAssertNil(store.paneCloseConfirmationContext(store.activeWorklane!.paneStripState.focusedPaneID!))
    }

    func test_internal_shell_bootstrap_command_does_not_mark_history() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.applyAgentStatusPayload(
            shellStatePayload(
                worklaneID: worklaneID,
                paneID: paneID,
                activity: .commandRunning,
                command: "_zentty_ensure_wrapper_path"
            )
        )
        store.applyAgentStatusPayload(
            shellStatePayload(worklaneID: worklaneID, paneID: paneID, activity: .promptIdle)
        )

        let auxiliary = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNotEqual(auxiliary.shellActivityState, .commandRunning)
        XCTAssertFalse(auxiliary.hasCommandHistory)
        XCTAssertNil(auxiliary.raw.lastRunCommand)
        XCTAssertNil(store.paneCloseConfirmationContext(paneID))
        XCTAssertFalse(store.anyPaneRequiresQuitConfirmation)
    }

    func test_real_shell_command_marks_history_after_returning_to_prompt() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.applyAgentStatusPayload(
            shellStatePayload(
                worklaneID: worklaneID,
                paneID: paneID,
                activity: .commandRunning,
                command: "git status"
            )
        )
        store.applyAgentStatusPayload(
            shellStatePayload(worklaneID: worklaneID, paneID: paneID, activity: .promptIdle)
        )

        let auxiliary = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertTrue(auxiliary.hasCommandHistory)
        XCTAssertEqual(auxiliary.raw.lastRunCommand, "git status")
        XCTAssertEqual(store.paneCloseConfirmationContext(paneID)?.reason, .sessionHistory)
        XCTAssertTrue(store.anyPaneRequiresQuitConfirmation)
        XCTAssertFalse(store.anyPaneHasRunningProcessForQuitConfirmation)
    }

    func test_running_process_still_blocks_even_without_history() {
        let paneID = PaneID("main-shell")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: paneID, title: "shell")],
                        focusedPaneID: paneID
                    ),
                    auxiliaryStateByPaneID: [
                        paneID: PaneAuxiliaryState(
                            raw: PaneRawState(shellActivityState: .commandRunning),
                            presentation: PanePresentationState()
                        )
                    ]
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        XCTAssertEqual(store.paneCloseConfirmationContext(paneID)?.reason, .runningProcess)
        XCTAssertTrue(store.anyPaneRequiresQuitConfirmation)
        XCTAssertTrue(store.anyPaneHasRunningProcessForQuitConfirmation)
    }

    func test_should_record_history_filters_internal_helpers() {
        let worklaneID = WorklaneID("main")
        let paneID = PaneID("pane")

        XCTAssertFalse(
            WorklaneStore.shouldRecordShellCommandHistory(
                shellStatePayload(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    activity: .commandRunning,
                    command: "_zentty_bind_leaked_key_events"
                )
            )
        )
        XCTAssertTrue(
            WorklaneStore.shouldRecordShellCommandHistory(
                shellStatePayload(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    activity: .commandRunning,
                    command: "pnpm test"
                )
            )
        )
        XCTAssertTrue(
            WorklaneStore.shouldRecordShellCommandHistory(
                shellStatePayload(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    activity: .commandRunning,
                    toolName: "Codex"
                )
            )
        )
    }

    func test_bash_integration_installs_debug_trap_after_bootstrap() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources/shell-integration/zentty-bash-integration.bash")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let bootstrapIndex = try XCTUnwrap(
            script.range(of: "_zentty_bash_prompt_hook \"$_zentty_bash_first_prompt_command\"\n")?.upperBound
        )
        let trapIndex = try XCTUnwrap(
            script.range(of: "trap '_zentty_bash_preexec_hook' DEBUG")?.lowerBound
        )
        XCTAssertLessThan(bootstrapIndex, trapIndex)
    }

    func test_external_quit_bypass_policy() {
        XCTAssertTrue(
            QuitConfirmationPolicy.shouldBypassPromptForExternalQuit(
                isExternalQuitRequest: true,
                anyPaneHasRunningProcess: false
            )
        )
        XCTAssertFalse(
            QuitConfirmationPolicy.shouldBypassPromptForExternalQuit(
                isExternalQuitRequest: true,
                anyPaneHasRunningProcess: true
            )
        )
        XCTAssertFalse(
            QuitConfirmationPolicy.shouldBypassPromptForExternalQuit(
                isExternalQuitRequest: false,
                anyPaneHasRunningProcess: false
            )
        )
    }

    func test_external_quit_detection_compares_sender_pid() {
        XCTAssertTrue(QuitConfirmationPolicy.isExternalSender(senderPID: 42_424, currentPID: 1))
        XCTAssertFalse(QuitConfirmationPolicy.isExternalSender(senderPID: 42_424, currentPID: 42_424))
        XCTAssertFalse(QuitConfirmationPolicy.isExternalSender(senderPID: 0, currentPID: 1))
        XCTAssertFalse(
            QuitConfirmationPolicy.isExternalApplicationQuitRequest(
                appleEvent: nil,
                currentPID: 1
            )
        )
    }

    private func shellStatePayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        activity: PaneShellActivityState,
        command: String? = nil,
        toolName: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .shellState,
            state: nil,
            shellActivityState: activity,
            shellCommand: command,
            origin: .shell,
            toolName: toolName,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}
