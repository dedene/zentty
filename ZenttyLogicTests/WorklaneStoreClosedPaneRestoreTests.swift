import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreClosedPaneRestoreTests: XCTestCase {
    func test_user_close_pushes_entry_onto_per_window_stack() throws {
        let store = makeMultiPaneStore()
        let originalCount = store.activeWorklane?.paneStripState.panes.count ?? 0
        XCTAssertEqual(originalCount, 2)

        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.scrollbackProvider = { id in id == paneID ? "captured-scrollback" : nil }
        _ = store.closePane(id: paneID)

        XCTAssertEqual(store.closedPaneStack.count, 1)
        XCTAssertEqual(store.closedPaneStack.peek()?.scrollbackText, "captured-scrollback")
    }

    func test_last_pane_close_does_not_push_onto_stack() throws {
        // Single-pane / single-worklane window: closePane returns .closeWindow
        // without actually removing the pane (the view layer handles the
        // window prompt and may cancel). We must not leave a stale entry on
        // the stack, otherwise ⌘⇧T would duplicate the still-live pane.
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        let result = store.closePane(id: paneID)

        XCTAssertEqual(result, .closeWindow)
        XCTAssertEqual(store.closedPaneStack.count, 0)
    }

    func test_remote_pane_close_does_not_push_onto_stack() throws {
        // SSH/remote panes can't be meaningfully restored locally — the cwd,
        // agent session, and CLI all live on the remote host. Capture must
        // skip them so ⌘⇧T doesn't hand the user a confusing local shell at
        // a non-existent path.
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        mutateActivePane(in: store, paneID: paneID) { _, auxiliary in
            auxiliary.shellContext = PaneShellContext(
                scope: .remote,
                path: "/var/www",
                home: "/home/peter",
                user: "peter",
                host: "example.com"
            )
        }

        _ = store.closePane(id: paneID)

        XCTAssertEqual(store.closedPaneStack.count, 0)
    }

    func test_shell_exit_close_does_not_push_onto_stack() throws {
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        _ = store.closePaneFromShellExit(id: paneID)

        XCTAssertEqual(store.closedPaneStack.count, 0)
    }

    func test_restore_inserts_a_pane_back_into_active_worklane() throws {
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        _ = store.closePane(id: paneID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)

        let result = store.restoreClosedPane()

        XCTAssertNotNil(result)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)
        XCTAssertEqual(store.closedPaneStack.count, 0)
    }

    func test_restore_falls_back_to_focused_worklane_when_original_was_removed() throws {
        let store = makeMultiPaneStore(extraWorklane: true)

        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let originalWorklaneID = try XCTUnwrap(store.activeWorklaneID)

        _ = store.closePane(id: paneID)

        // Force-clear the original worklane to simulate it disappearing.
        store.replaceWorklanes(
            store.worklanes.filter { $0.id != originalWorklaneID },
            activeWorklaneID: store.worklanes.first(where: { $0.id != originalWorklaneID })?.id
        )

        let result = store.restoreClosedPane()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.restoredWorklaneID, store.activeWorklaneID)
    }

    func test_restore_returns_nil_when_stack_empty() {
        let store = WorklaneStore()
        XCTAssertNil(store.restoreClosedPane())
    }

    func test_restore_keeps_entry_on_stack_when_no_target_can_be_found() throws {
        // Push an entry, then strip the store down to zero worklanes so target
        // resolution can't succeed. Restore must leave the entry on the stack
        // so the user's next attempt (e.g. after creating a worklane) works.
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        _ = store.closePane(id: paneID)
        XCTAssertEqual(store.closedPaneStack.count, 1)

        store.replaceWorklanes([], activeWorklaneID: nil)

        XCTAssertNil(store.restoreClosedPane())
        XCTAssertEqual(store.closedPaneStack.count, 1)
    }

    func test_restored_pane_has_no_native_command_only_prefill_text() throws {
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Simulate a pane that was running an arbitrary command. Mutate the
        // session request so the captured entry carries a replay command.
        // Mutate worklanes directly (replaceWorklanes would re-normalize the
        // presentation state, which overrides our test setup).
        mutateActivePane(in: store, paneID: paneID) { pane, _ in
            pane.sessionRequest.nativeCommand = "vim README.md"
        }

        _ = store.closePane(id: paneID)
        let result = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(
            store.activeWorklane?.paneStripState.panes.first(where: { $0.id == result.restoredPaneID })
        )

        // Resume / replay commands MUST be delivered via prefillText (typed
        // into the live shell so its own PATH resolves the binary). Setting
        // nativeCommand would replace the shell with the binary at PID 1
        // using the launch-environment PATH — which is exactly the bug we hit.
        XCTAssertNil(restored.sessionRequest.nativeCommand)
        XCTAssertNil(restored.sessionRequest.command)
        let prefill = try XCTUnwrap(restored.sessionRequest.prefillText)
        XCTAssertTrue(prefill.contains("vim README.md"))
        XCTAssertTrue(prefill.hasSuffix("\n"), "prefillText must end with a newline so the shell auto-executes the command")
    }

    func test_restored_pane_resumes_agent_session_via_prefill_text() throws {
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        let agent = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            workingDirectory: "/tmp/project",
            sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c"
        )
        mutateActivePane(in: store, paneID: paneID) { _, auxiliary in
            auxiliary.agentStatus = agent
        }

        _ = store.closePane(id: paneID)
        let result = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(
            store.activeWorklane?.paneStripState.panes.first(where: { $0.id == result.restoredPaneID })
        )
        let prefill = try XCTUnwrap(restored.sessionRequest.prefillText)
        XCTAssertTrue(prefill.contains("claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c"))
        XCTAssertTrue(prefill.hasSuffix("\n"))
        XCTAssertTrue(result.toastMessage.contains("Claude Code"))
    }

    func test_restored_pane_recreates_column_at_its_original_width() throws {
        // Custom worklane with three columns of distinct widths.
        let mainWorklane = WorklaneState(
            id: WorklaneID("wl_main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                columns: [
                    PaneColumnState(
                        id: PaneColumnID("col_left"),
                        panes: [PaneState(id: PaneID("pn_left"), title: "left")],
                        width: 400,
                        focusedPaneID: PaneID("pn_left"),
                        lastFocusedPaneID: PaneID("pn_left")
                    ),
                    PaneColumnState(
                        id: PaneColumnID("col_middle"),
                        panes: [PaneState(id: PaneID("pn_middle"), title: "middle")],
                        width: 800,
                        focusedPaneID: PaneID("pn_middle"),
                        lastFocusedPaneID: PaneID("pn_middle")
                    ),
                    PaneColumnState(
                        id: PaneColumnID("col_right"),
                        panes: [PaneState(id: PaneID("pn_right"), title: "right")],
                        width: 500,
                        focusedPaneID: PaneID("pn_right"),
                        lastFocusedPaneID: PaneID("pn_right")
                    ),
                ],
                focusedColumnID: PaneColumnID("col_middle")
            ),
            nextPaneNumber: 4
        )
        let layoutContext = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 2_000,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
        let store = WorklaneStore(
            worklanes: [mainWorklane],
            layoutContext: layoutContext,
            activeWorklaneID: WorklaneID("wl_main")
        )

        // Closing the only pane in the middle column will remove that column;
        // restoring should bring it back at the original 800 width.
        _ = store.closePane(id: PaneID("pn_middle"))
        let result = try XCTUnwrap(store.restoreClosedPane())

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 3)
        let restoredColumn = try XCTUnwrap(
            columns.first { $0.panes.contains { $0.id == result.restoredPaneID } }
        )
        XCTAssertEqual(restoredColumn.width, 800, accuracy: 0.5)
    }

    func test_restored_pane_keeps_its_height_weight_within_existing_column() throws {
        // Single column with three panes; close the middle one (with a
        // distinctive height weight). Restoring should give it back roughly
        // its original weight rather than just landing on the equalized 1.
        let column = PaneColumnState(
            id: PaneColumnID("col_main"),
            panes: [
                PaneState(id: PaneID("pn_top"), title: "top"),
                PaneState(id: PaneID("pn_middle"), title: "middle"),
                PaneState(id: PaneID("pn_bottom"), title: "bottom"),
            ],
            width: 800,
            paneHeights: [1, 3, 1],
            focusedPaneID: PaneID("pn_middle"),
            lastFocusedPaneID: PaneID("pn_middle")
        )
        let worklane = WorklaneState(
            id: WorklaneID("wl_main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                columns: [column],
                focusedColumnID: PaneColumnID("col_main")
            ),
            nextPaneNumber: 4
        )
        let store = WorklaneStore(
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("wl_main")
        )

        _ = store.closePane(id: PaneID("pn_middle"))
        let result = try XCTUnwrap(store.restoreClosedPane())

        let restoredColumn = try XCTUnwrap(
            store.activeWorklane?.paneStripState.columns.first { col in
                col.panes.contains { $0.id == result.restoredPaneID }
            }
        )
        let restoredIndex = try XCTUnwrap(
            restoredColumn.panes.firstIndex { $0.id == result.restoredPaneID }
        )
        XCTAssertEqual(restoredColumn.paneHeights[restoredIndex], 3, accuracy: 0.001)
    }

    func test_restored_pane_uses_live_cwd_not_launch_directory() throws {
        let store = makeMultiPaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Different launch dir vs current navigation dir — the restore must
        // pick the navigation (live) dir.
        let liveCWD = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zentty-restore-live-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: liveCWD, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: liveCWD) }

        mutateActivePane(in: store, paneID: paneID) { pane, auxiliary in
            pane.sessionRequest.workingDirectory = "/tmp/launch-dir-not-current"
            auxiliary.presentation.cwd = liveCWD.path
        }

        _ = store.closePane(id: paneID)
        let result = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(
            store.activeWorklane?.paneStripState.panes.first(where: { $0.id == result.restoredPaneID })
        )
        XCTAssertEqual(restored.sessionRequest.workingDirectory, liveCWD.path)
    }

    /// Mutates the pane and its auxiliary state in place on the active worklane,
    /// without invoking `replaceWorklanes` (which would re-run presentation
    /// normalization and overwrite `presentation.cwd` etc.).
    private func mutateActivePane(
        in store: WorklaneStore,
        paneID: PaneID,
        _ mutation: (inout PaneState, inout PaneAuxiliaryState) -> Void
    ) {
        guard let worklaneIndex = store.worklanes.firstIndex(where: { $0.id == store.activeWorklaneID }) else {
            XCTFail("No active worklane")
            return
        }
        guard let columnIndex = store.worklanes[worklaneIndex].paneStripState.columns.firstIndex(where: { col in
            col.panes.contains(where: { $0.id == paneID })
        }) else {
            XCTFail("Pane \(paneID.rawValue) not found in active worklane")
            return
        }
        guard let paneIndex = store.worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes.firstIndex(where: { $0.id == paneID }) else {
            return
        }
        var pane = store.worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes[paneIndex]
        var aux = store.worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]
            ?? PaneAuxiliaryState(raw: PaneRawState(), presentation: PanePresentationState())
        mutation(&pane, &aux)
        store.worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes[paneIndex] = pane
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID] = aux
    }

    private func makeMultiPaneStore(extraWorklane: Bool = false) -> WorklaneStore {
        let mainWorklane = WorklaneState(
            id: WorklaneID("wl_main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                columns: [
                    PaneColumnState(
                        id: PaneColumnID("col_left"),
                        panes: [PaneState(id: PaneID("pn_left"), title: "left")],
                        width: 600,
                        focusedPaneID: PaneID("pn_left"),
                        lastFocusedPaneID: PaneID("pn_left")
                    ),
                    PaneColumnState(
                        id: PaneColumnID("col_right"),
                        panes: [PaneState(id: PaneID("pn_right"), title: "right")],
                        width: 600,
                        focusedPaneID: PaneID("pn_right"),
                        lastFocusedPaneID: PaneID("pn_right")
                    ),
                ],
                focusedColumnID: PaneColumnID("col_right")
            ),
            nextPaneNumber: 3
        )

        var worklanes = [mainWorklane]
        if extraWorklane {
            worklanes.append(
                WorklaneState(
                    id: WorklaneID("wl_other"),
                    title: "OTHER",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("pn_other"), title: "other")],
                        focusedPaneID: PaneID("pn_other")
                    ),
                    nextPaneNumber: 1
                )
            )
        }

        return WorklaneStore(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("wl_main")
        )
    }
}
