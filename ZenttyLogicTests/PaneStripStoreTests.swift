import XCTest
@testable import Zentty

@MainActor
final class PaneStripStoreTests: XCTestCase {
    func test_store_starts_with_single_main_worklane_and_first_active() {
        let store = WorklaneStore()

        XCTAssertEqual(store.worklanes.count, 1)
        XCTAssertNotNil(store.activeWorklane)
        XCTAssertEqual(store.activeWorklane?.id, store.worklanes.first?.id)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.panes.first?.sessionRequest.workingDirectory,
            NSHomeDirectory()
        )
    }

    func test_default_worklane_shell_session_uses_opaque_runtime_ids_in_environment() throws {
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)
        let pane = try XCTUnwrap(worklane.paneStripState.focusedPane)
        let request = pane.sessionRequest

        XCTAssertTrue(worklane.id.rawValue.hasPrefix("wl_"))
        XCTAssertTrue(pane.id.rawValue.hasPrefix("pn_"))
        XCTAssertEqual(request.environmentVariables["ZENTTY_WORKLANE_ID"], worklane.id.rawValue)
        XCTAssertEqual(request.environmentVariables["ZENTTY_PANE_ID"], pane.id.rawValue)
    }

    func test_separate_default_stores_generate_distinct_runtime_ids() throws {
        let firstStore = WorklaneStore()
        let secondStore = WorklaneStore()

        let firstWorklaneID = try XCTUnwrap(firstStore.activeWorklane?.id)
        let secondWorklaneID = try XCTUnwrap(secondStore.activeWorklane?.id)
        let firstPaneID = try XCTUnwrap(firstStore.activeWorklane?.paneStripState.focusedPaneID)
        let secondPaneID = try XCTUnwrap(secondStore.activeWorklane?.paneStripState.focusedPaneID)

        XCTAssertNotEqual(firstWorklaneID, secondWorklaneID)
        XCTAssertNotEqual(firstPaneID, secondPaneID)
    }

    func test_payload_for_another_store_does_not_update_this_store() throws {
        let sourceStore = WorklaneStore()
        let targetStore = WorklaneStore()

        let sourceWorklaneID = try XCTUnwrap(sourceStore.activeWorklane?.id)
        let sourcePaneID = try XCTUnwrap(sourceStore.activeWorklane?.paneStripState.focusedPaneID)
        let targetPaneID = try XCTUnwrap(targetStore.activeWorklane?.paneStripState.focusedPaneID)
        let originalPath = targetStore.activeWorklane?.auxiliaryStateByPaneID[targetPaneID]?.shellContext?.path

        targetStore.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: sourceWorklaneID,
                paneID: sourcePaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/foreign-store",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(targetStore.activeWorklane?.auxiliaryStateByPaneID[targetPaneID]?.shellContext?.path, originalPath)
    }

    func test_select_worklane_switches_active_worklane_without_resetting_other_worklane_state() throws {
        let store = WorklaneStore()
        store.createWorklane()

        let worklane2ID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "WS 1" })?.id)
        let mainID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "MAIN" })?.id)
        store.selectWorklane(id: worklane2ID)
        store.send(.splitAfterFocusedPane)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell", "pane 1"])

        store.selectWorklane(id: mainID)
        XCTAssertEqual(store.activeWorklane?.title, "MAIN")
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])

        store.selectWorklane(id: worklane2ID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell", "pane 1"])
    }

    func test_create_worklane_adds_new_worklane_with_single_shell_pane_and_focuses_it() {
        let store = WorklaneStore()

        store.createWorklane()

        XCTAssertEqual(store.worklanes.map(\.title), ["MAIN", "WS 1"])
        XCTAssertEqual(store.activeWorklane?.title, "WS 1")
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.surfaceContext,
            .tab
        )
    }

    func test_default_worklane_uses_window_surface_context() throws {
        let store = WorklaneStore()

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.surfaceContext, .window)
    }

    func test_duplicate_pane_as_column_replays_non_shell_process_name() throws {
        let store = WorklaneStore()
        let sourcePaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let sourceWorklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: sourceWorklaneID,
                paneID: sourcePaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.updateMetadata(
            paneID: sourcePaneID,
            metadata: TerminalMetadata(
                title: "drift --showcase",
                currentWorkingDirectory: "/tmp/project",
                processName: "drift"
            )
        )

        store.duplicatePaneAsColumn(
            paneID: sourcePaneID,
            toColumnIndex: 1,
            singleColumnWidth: store.layoutContext.singlePaneWidth
        )

        let duplicatedPane = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane)
        XCTAssertNotEqual(duplicatedPane.id, sourcePaneID)
        XCTAssertEqual(duplicatedPane.sessionRequest.workingDirectory, "/tmp/project")
        XCTAssertEqual(duplicatedPane.sessionRequest.command, "drift --showcase")
    }

    func test_split_after_inserts_adjacent_pane_and_inherits_focused_working_directory() throws {
        let store = WorklaneStore()
        let focusedPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: focusedPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project")
        )

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "pane 1")
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/project"
        )
        XCTAssertNil(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            focusedPaneID
        )
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.surfaceContext, .split)
    }

    func test_split_after_falls_back_to_home_when_focused_working_directory_is_missing() throws {
        let store = WorklaneStore()
        _ = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "pane 1")
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            NSHomeDirectory()
        )
        XCTAssertNil(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
    }

    func test_split_after_uses_focused_local_pane_context_when_metadata_is_missing() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertNil(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_split_after_prefers_focused_local_pane_context_over_seed_metadata() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let seededWorkingDirectory = try XCTUnwrap(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory
        )

        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: seededWorkingDirectory)
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.workingDirectory, "/tmp/local-project")
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
        XCTAssertNil(request.inheritFromPaneID)
        XCTAssertEqual(request.configInheritanceSourcePaneID, shellPaneID)
    }

    func test_split_after_uses_focused_remote_pane_context_when_metadata_is_missing() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/remote-project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod-box"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/srv/remote-project"
        )
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID,
            shellPaneID
        )
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_create_worklane_uses_last_focused_local_pane_context() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.createWorklane()

        XCTAssertEqual(store.activeWorklane?.title, "WS 1")
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_create_worklane_prefers_last_focused_local_pane_context_over_seed_metadata() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let seededWorkingDirectory = try XCTUnwrap(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory
        )

        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: seededWorkingDirectory)
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.createWorklane()

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.workingDirectory, "/tmp/local-project")
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
        XCTAssertEqual(request.configInheritanceSourcePaneID, shellPaneID)
    }

    func test_review_state_does_not_override_canonical_git_branch_in_presentation() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "feature/stale-pr-branch",
                pullRequest: WorklanePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: []
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.branch, "main")
        XCTAssertEqual(presentation.pullRequest?.number, 42)
    }

    func test_create_worklane_keeps_last_focused_local_directory_when_current_focus_is_remote() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)
        let remotePaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: remotePaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/remote-project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod-box"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.createWorklane()

        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            remotePaneID
        )
    }

    func test_split_horizontally_reuses_source_column_width_for_laptop_context() throws {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: layoutContext)

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.map(\.width), [910, 910])
    }

    func test_split_horizontally_keeps_first_column_width_for_laptop_context() throws {
        let layoutContext = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced,
            ultrawidePreset: .roomy
        ).makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("shell"), title: "shell", width: 1200)
                        ],
                        focusedPaneID: PaneID("shell")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.map(\.width), [1200, 1200])
    }

    func test_split_horizontally_keeps_first_column_width_for_large_display_context() throws {
        let layoutContext = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced,
            ultrawidePreset: .roomy
        ).makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1720,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("shell"), title: "shell", width: 1600)
                        ],
                        focusedPaneID: PaneID("shell")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.map(\.width), [1600, 1600])
    }

    func test_split_horizontally_equalizes_first_column_on_ultrawide_context() throws {
        let layoutContext = PaneLayoutPreferences(
            laptopPreset: .compact,
            largeDisplayPreset: .balanced,
            ultrawidePreset: .roomy
        ).makeLayoutContext(
            displayClass: .ultrawide,
            viewportWidth: 3440,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: layoutContext)

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.map(\.width), [1572, 1572])
    }

    func test_updating_layout_context_resizes_existing_single_pane_to_full_readable_width() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: initialContext)

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.width ?? 0, 1210, accuracy: 0.001)
    }

    func test_updating_layout_context_scales_multi_pane_widths_proportionally_to_readable_width() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)
        let initialWidths = store.activeWorklane?.paneStripState.columns.map(\.width) ?? []
        let expectedScaleFactor = updatedContext.singlePaneWidth / initialContext.singlePaneWidth

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(
            store.activeWorklane?.paneStripState.columns.map(\.width),
            initialWidths.map { $0 * expectedScaleFactor }
        )
    }

    func test_updating_layout_context_reprojects_multi_pane_widths_when_only_sidebar_inset_changes() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 0
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)
        let initialWidths = store.activeWorklane?.paneStripState.columns.map(\.width) ?? []
        let expectedScaleFactor = updatedContext.singlePaneWidth / initialContext.singlePaneWidth

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(
            store.activeWorklane?.paneStripState.columns.map(\.width),
            initialWidths.map { $0 * expectedScaleFactor }
        )
    }

    func test_updating_layout_context_updates_single_column_stack_width_to_latest_single_pane_width() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: initialContext)
        store.updatePaneViewportHeight(640)
        store.send(.splitVertically)

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.panes.count, 2)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.width ?? 0, 1210, accuracy: 0.001)
    }

    func test_updating_layout_context_reprojects_multi_pane_layout_sizing_even_when_widths_do_not_change() {
        let collapsedSizing = PaneLayoutSizing(
            horizontalInset: 0,
            topInset: PaneLayoutSizing.balanced.topInset,
            bottomInset: PaneLayoutSizing.balanced.bottomInset + 1,
            interPaneSpacing: PaneLayoutSizing.balanced.interPaneSpacing
        )
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 0
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 0,
            sizing: collapsedSizing
        )
        let store = WorklaneStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)

        var changeNotifications = 0
        store.onChange = { _ in
            changeNotifications += 1
        }

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorklane?.paneStripState.layoutSizing, collapsedSizing)
        XCTAssertEqual(changeNotifications, 1)
    }

    func test_updating_layout_context_emits_immediate_layout_resize_change() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let updatedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1500,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: initialContext)
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }
        let activeWorklaneID = store.activeWorklaneID

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(
            changes,
            [.layoutResized(activeWorklaneID, animation: .immediate)]
        )
    }

    func test_updating_from_fallback_layout_context_reprojects_initial_shell_to_current_full_width() {
        let store = WorklaneStore(layoutContext: .fallback)
        let actualContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1268,
            leadingVisibleInset: 290
        )

        store.updateLayoutContext(actualContext)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.width ?? 0, 978, accuracy: 0.001)
    }

    func test_restore_pane_layout_emits_split_curve_layout_resize_change() {
        let store = WorklaneStore()
        let restoredState = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 520),
                PaneState(id: PaneID("right"), title: "right", width: 520),
            ],
            focusedPaneID: PaneID("right")
        )
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }
        let activeWorklaneID = store.activeWorklaneID

        store.restorePaneLayout(restoredState)

        XCTAssertEqual(
            changes,
            [.layoutResized(activeWorklaneID, animation: .splitCurve)]
        )
    }

    func test_closing_back_to_single_pane_restores_full_readable_width() {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorklaneStore(layoutContext: layoutContext)

        store.send(.splitAfterFocusedPane)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.width ?? 0, 910, accuracy: 0.001)
    }

    func test_split_vertically_adds_pane_inside_current_column() {
        let store = WorklaneStore()
        store.updatePaneViewportHeight(640)

        store.send(.splitVertically)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "pane 1")
    }

    func test_split_vertically_refuses_when_viewport_height_is_below_minimum_equalized_height() {
        let store = WorklaneStore()
        store.updatePaneViewportHeight(300)

        store.send(.splitVertically)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.panes.map(\.title), ["shell"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "shell")
    }

    func test_closing_focused_pane_inside_vertical_stack_prefers_lower_neighbor() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("middle"), title: "middle"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 900,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            )
                        ],
                        focusedColumnID: PaneColumnID("stack")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.first?.panes.map(\.title), ["top", "bottom"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "bottom")
    }

    func test_resize_focused_pane_uses_last_interacted_vertical_divider() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("middle"), title: "middle"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 900,
                                paneHeights: [200, 300, 400],
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            )
                        ],
                        focusedColumnID: PaneColumnID("stack")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.markDividerInteraction(.pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("middle")))
        store.resizeFocusedPane(
            in: .vertical,
            delta: -50,
            availableSize: CGSize(width: 1200, height: 920),
            minimumSizeByPaneID: [
                PaneID("top"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("bottom"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        let heights = store.activeWorklane?.paneStripState.columns[0].resolvedPaneHeights(
            totalHeight: 920,
            spacing: store.activeWorklane?.paneStripState.layoutSizing.interPaneSpacing ?? 6
        )
        XCTAssertEqual(heights?[1] ?? 0, 252.66666666666669, accuracy: 0.001)
        XCTAssertEqual(heights?[2] ?? 0, 453.5555555555555, accuracy: 0.001)
    }

    func test_movePane_updates_active_worklane_structure_and_focus() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("dragged"), title: "dragged")],
                                width: 320,
                                paneHeights: [280],
                                focusedPaneID: PaneID("dragged"),
                                lastFocusedPaneID: PaneID("dragged")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 540,
                                paneHeights: [500, 100],
                                focusedPaneID: PaneID("top"),
                                lastFocusedPaneID: PaneID("top")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.movePane(
            paneID: PaneID("dragged"),
            toColumnID: PaneColumnID("stack"),
            toPaneIndex: 1
        )

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns.map(\.id), [PaneColumnID("stack")])
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.columns[0].panes.map(\.id),
            [PaneID("top"), PaneID("dragged"), PaneID("bottom")]
        )
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns[0].paneHeights, [500, 280, 100])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.id, PaneID("dragged"))
    }

    func test_splitDropPane_rejects_horizontal_split_onto_multi_pane_stack() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("source"),
                                panes: [PaneState(id: PaneID("dragged"), title: "dragged")],
                                width: 320,
                                focusedPaneID: PaneID("dragged"),
                                lastFocusedPaneID: PaneID("dragged")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 540,
                                paneHeights: [2, 3],
                                focusedPaneID: PaneID("top"),
                                lastFocusedPaneID: PaneID("top")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("source")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.splitDropPane(
            paneID: PaneID("dragged"),
            ontoTargetPaneID: PaneID("top"),
            axis: .horizontal,
            leading: true,
            availableHeight: 920,
            singleColumnWidth: 900
        )

        let columns = store.activeWorklane?.paneStripState.columns
        XCTAssertEqual(columns?.count, 2)
        XCTAssertEqual(columns?[0].panes.map(\.id), [PaneID("dragged")])
        XCTAssertEqual(columns?[1].panes.map(\.id), [PaneID("top"), PaneID("bottom")])
        XCTAssertEqual(columns?[0].width ?? 0, 320, accuracy: 0.001)
        XCTAssertEqual(columns?[1].width ?? 0, 540, accuracy: 0.001)
    }

    func test_insertPaneAsColumn_generates_unique_column_id_when_default_id_collides() {
        var state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("column-shell"),
                    panes: [PaneState(id: PaneID("shell"), title: "shell")],
                    width: 420,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("column-shell")
        )

        state.insertPaneAsColumn(
            PaneState(id: PaneID("shell"), title: "duplicate shell"),
            atColumnIndex: 1,
            width: 420
        )

        XCTAssertEqual(Set(state.columns.map(\.id)).count, state.columns.count)
    }

    func test_duplicatePaneAsColumn_carries_meaningful_terminal_title_as_command() throws {
        let sourcePaneID = PaneID("source")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: sourcePaneID,
                                title: "shell",
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                                width: 420
                            ),
                        ],
                        focusedPaneID: sourcePaneID
                    ),
                    nextPaneNumber: 1,
                    metadataByPaneID: [
                        sourcePaneID: TerminalMetadata(
                            title: "drift --showcase",
                            currentWorkingDirectory: "/tmp/project"
                        ),
                    ],
                    paneContextByPaneID: [
                        sourcePaneID: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: "mbp"
                        ),
                    ]
                ),
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.duplicatePaneAsColumn(
            paneID: sourcePaneID,
            toColumnIndex: 1,
            singleColumnWidth: 900
        )

        let duplicatedPane = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane)
        XCTAssertNotEqual(duplicatedPane.id, sourcePaneID)
        XCTAssertEqual(duplicatedPane.sessionRequest.command, "drift --showcase")
        XCTAssertEqual(duplicatedPane.sessionRequest.workingDirectory, "/tmp/project")
    }

    func test_send_duplicateFocusedPane_duplicates_focused_pane_into_next_column() throws {
        let sourcePaneID = PaneID("source")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: sourcePaneID,
                                title: "shell",
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                                width: 420
                            ),
                        ],
                        focusedPaneID: sourcePaneID
                    ),
                    nextPaneNumber: 1,
                    metadataByPaneID: [
                        sourcePaneID: TerminalMetadata(
                            title: "drift --showcase",
                            currentWorkingDirectory: "/tmp/project"
                        ),
                    ],
                    paneContextByPaneID: [
                        sourcePaneID: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: "mbp"
                        ),
                    ]
                ),
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.duplicateFocusedPane)

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].panes.map(\.id), [sourcePaneID])

        let duplicatedPane = try XCTUnwrap(columns[1].panes.first)
        XCTAssertNotEqual(duplicatedPane.id, sourcePaneID)
        XCTAssertEqual(duplicatedPane.sessionRequest.command, "drift --showcase")
        XCTAssertEqual(duplicatedPane.sessionRequest.workingDirectory, "/tmp/project")
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedColumnID, columns[1].id)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, duplicatedPane.id)
    }

    func test_splitDropPane_horizontal_split_from_stack_keeps_column_ids_unique() throws {
        let draggedPaneID = PaneID("dragged")
        let siblingPaneID = PaneID("sibling")
        let stackedColumnID = PaneColumnID("column-\(draggedPaneID.rawValue)")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: stackedColumnID,
                                panes: [
                                    PaneState(id: draggedPaneID, title: "dragged"),
                                    PaneState(id: siblingPaneID, title: "sibling"),
                                ],
                                width: 900,
                                paneHeights: [1, 1],
                                focusedPaneID: draggedPaneID,
                                lastFocusedPaneID: draggedPaneID
                            ),
                        ],
                        focusedColumnID: stackedColumnID
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.splitDropPane(
            paneID: draggedPaneID,
            ontoTargetPaneID: siblingPaneID,
            axis: .horizontal,
            leading: true,
            availableHeight: 920,
            singleColumnWidth: 900
        )

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].panes.map(\.id), [draggedPaneID])
        XCTAssertEqual(columns[1].panes.map(\.id), [siblingPaneID])
        XCTAssertEqual(Set(columns.map(\.id)).count, columns.count)
        XCTAssertEqual(columns[1].id, stackedColumnID)
        XCTAssertNotEqual(columns[0].id, stackedColumnID)
    }

    func test_resize_focused_pane_left_shrinks_only_the_focused_middle_column() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("left"), title: "left")],
                                width: 400,
                                focusedPaneID: PaneID("left"),
                                lastFocusedPaneID: PaneID("left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("middle"),
                                panes: [PaneState(id: PaneID("middle"), title: "middle")],
                                width: 400,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("right"), title: "right")],
                                width: 500,
                                focusedPaneID: PaneID("right"),
                                lastFocusedPaneID: PaneID("right")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("middle")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.resizeFocusedPane(
            in: .horizontal,
            delta: -40,
            availableSize: CGSize(width: 1000, height: 920),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        let columns = store.activeWorklane?.paneStripState.columns
        XCTAssertEqual(columns?[0].width ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(columns?[1].width ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(columns?[2].width ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.lastInteractedDivider,
            .column(afterColumnID: PaneColumnID("left"))
        )
    }

    func test_resize_focused_pane_right_grows_only_the_focused_interior_column() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("left"), title: "left")],
                                width: 400,
                                focusedPaneID: PaneID("left"),
                                lastFocusedPaneID: PaneID("left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("middle"),
                                panes: [PaneState(id: PaneID("middle"), title: "middle")],
                                width: 400,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("right"), title: "right")],
                                width: 500,
                                focusedPaneID: PaneID("right"),
                                lastFocusedPaneID: PaneID("right")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("middle")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.resizeFocusedPane(
            in: .horizontal,
            delta: 40,
            availableSize: CGSize(width: 1200, height: 920),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        let columns = store.activeWorklane?.paneStripState.columns
        XCTAssertEqual(columns?[0].width ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(columns?[1].width ?? 0, 440, accuracy: 0.001)
        XCTAssertEqual(columns?[2].width ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.lastInteractedDivider,
            .column(afterColumnID: PaneColumnID("middle"))
        )
    }

    func test_horizontal_arrange_emits_split_curve_layout_resize_change() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("left"), title: "left", width: 520),
                            PaneState(id: PaneID("right"), title: "right", width: 520),
                        ],
                        focusedPaneID: PaneID("left")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        store.arrangeActiveWorklaneHorizontally(
            .halfWidth,
            availableWidth: 1280
        )

        XCTAssertEqual(
            changes,
            [.layoutResized(WorklaneID("main"), animation: .splitCurve)]
        )
    }

    func test_resize_target_emits_immediate_layout_resize_change() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("left"), title: "left", width: 520),
                            PaneState(id: PaneID("right"), title: "right", width: 520),
                        ],
                        focusedPaneID: PaneID("left")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        store.resize(
            .divider(.column(afterColumnID: PaneColumnID("column-left"))),
            delta: 24,
            availableSize: CGSize(width: 1280, height: 840),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        XCTAssertEqual(
            changes,
            [.layoutResized(WorklaneID("main"), animation: .immediate)]
        )
    }

    func test_resize_focused_last_pane_right_shrinks_it_without_resizing_neighbors() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("left"), title: "left", width: 600),
                            PaneState(id: PaneID("right"), title: "right", width: 600),
                        ],
                        focusedPaneID: PaneID("right")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.resizeFocusedPane(
            in: .horizontal,
            delta: 40,
            availableSize: CGSize(width: 1200, height: 920),
            minimumSizeByPaneID: [
                PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                PaneID("right"): PaneMinimumSize(width: 320, height: 160),
            ]
        )

        let columns = store.activeWorklane?.paneStripState.columns
        XCTAssertEqual(columns?[0].width ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(columns?[1].width ?? 0, 594, accuracy: 0.001)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, PaneID("right"))
        XCTAssertEqual(
            store.activeWorklane?.paneStripState.lastInteractedDivider,
            .column(afterColumnID: PaneColumnID("column-left"))
        )
    }

    func test_reset_active_worklane_layout_restores_default_widths_and_equal_heights() {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1400,
            leadingVisibleInset: 0
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 720,
                                paneHeights: [240, 480],
                                focusedPaneID: PaneID("top"),
                                lastFocusedPaneID: PaneID("top")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("editor"), title: "editor")],
                                width: 520,
                                focusedPaneID: PaneID("editor"),
                                lastFocusedPaneID: PaneID("editor")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: WorklaneID("main")
        )

        store.resetActiveWorklaneLayout()

        XCTAssertEqual(store.activeWorklane?.paneStripState.columns[0].width ?? 0, layoutContext.newPaneWidth, accuracy: 0.001)
        XCTAssertEqual(store.activeWorklane?.paneStripState.columns[1].width ?? 0, layoutContext.newPaneWidth, accuracy: 0.001)
        let heights = store.activeWorklane?.paneStripState.columns[0].resolvedPaneHeights(
            totalHeight: 920,
            spacing: store.activeWorklane?.paneStripState.layoutSizing.interPaneSpacing ?? 6
        )
        XCTAssertEqual(heights?[0] ?? 0, heights?[1] ?? 0, accuracy: 0.001)
    }

    func test_focus_up_and_down_move_within_vertical_stack() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("middle"), title: "middle"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 900,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            )
                        ],
                        focusedColumnID: PaneColumnID("stack")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "bottom")

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "middle")
    }

    func test_focus_first_and_last_column_move_between_columns() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("left"), title: "left")],
                                width: 900,
                                focusedPaneID: PaneID("left"),
                                lastFocusedPaneID: PaneID("left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("right"), title: "right")],
                                width: 900,
                                focusedPaneID: PaneID("right"),
                                lastFocusedPaneID: PaneID("right")
                            )
                        ],
                        focusedColumnID: PaneColumnID("right")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("main")
        )

        store.send(.focusFirstColumn)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedColumn?.id, PaneColumnID("left"))

        store.send(.focusLastColumn)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedColumn?.id, PaneColumnID("right"))
    }

    func test_focus_next_pane_by_sidebar_order_moves_within_worklane_then_across_worklanes() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("ws1-left"), title: "ws1-left")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-left"),
                                lastFocusedPaneID: PaneID("ws1-left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("ws1-right"), title: "ws1-right")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-right"),
                                lastFocusedPaneID: PaneID("ws1-right")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("main"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("main")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, PaneID("ws1-right"))

        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws2"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, PaneID("ws2-pane"))
    }

    func test_focus_previous_pane_by_sidebar_order_wraps_to_last_pane_of_last_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("main"),
                                panes: [PaneState(id: PaneID("ws1-pane"), title: "ws1-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-pane"),
                                lastFocusedPaneID: PaneID("ws1-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("main")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [PaneState(id: PaneID("ws2-left"), title: "ws2-left")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-left"),
                                lastFocusedPaneID: PaneID("ws2-left")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [PaneState(id: PaneID("ws2-right"), title: "ws2-right")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-right"),
                                lastFocusedPaneID: PaneID("ws2-right")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusPreviousPaneBySidebarOrder)

        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws2"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, PaneID("ws2-right"))
    }

    func test_split_before_inserts_adjacent_pane_before_focus() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("api"),
                    title: "API",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("api-shell"), title: "shell"),
                            PaneState(id: PaneID("api-editor"), title: "editor"),
                        ],
                        focusedPaneID: PaneID("api-editor")
                    ),
                    nextPaneNumber: 1
                )
            ],
            activeWorklaneID: WorklaneID("api")
        )

        store.send(.splitBeforeFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell", "pane 1", "editor"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "pane 1")
    }

    func test_close_removes_focused_pane_inside_active_worklane_only() throws {
        let store = WorklaneStore()
        store.createWorklane()
        let worklane2ID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "WS 1" })?.id)

        store.selectWorklane(id: worklane2ID)
        store.send(.splitAfterFocusedPane)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])

        store.selectWorklane(id: WorklaneID("worklane-main"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])
    }

    func test_close_focused_pane_on_single_pane_worklane_closes_worklane_when_another_worklane_exists() throws {
        let store = WorklaneStore()
        store.createWorklane()

        let mainID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "MAIN" })?.id)
        let worklane2ID = try XCTUnwrap(store.worklanes.first(where: { $0.title == "WS 1" })?.id)

        store.selectWorklane(id: worklane2ID)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.worklanes.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorklaneID, mainID)
    }

    func test_close_focused_pane_on_last_remaining_worklane_requests_window_close() {
        let store = WorklaneStore()

        let result = store.closeFocusedPane()

        XCTAssertEqual(result, .closeWindow)
        XCTAssertEqual(store.worklanes.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])
    }

    func test_close_pane_requests_window_close_when_closing_last_pane_in_last_worklane() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        let result = store.closePane(id: paneID)

        XCTAssertEqual(result, .closeWindow)
        XCTAssertEqual(store.worklanes.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.title), ["shell"])
    }

    func test_close_pane_removes_requested_pane_from_active_worklane() throws {
        let store = WorklaneStore()

        store.send(.splitAfterFocusedPane)
        let insertedPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)

        store.closePane(id: insertedPaneID)

        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertFalse(store.activeWorklane?.paneStripState.panes.contains(where: { $0.id == insertedPaneID }) ?? true)
    }

    func test_close_focused_pane_reexpands_remaining_columns_to_fill_readable_width() {
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
                    title: "MAIN",
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

        _ = store.closeFocusedPane()

        let widths = store.activeWorklane?.paneStripState.columns.map(\.width) ?? []
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0] / widths[1], 3 / 7, accuracy: 0.001)
        XCTAssertEqual(widths.reduce(0, +) + layoutContext.sizing.interPaneSpacing, layoutContext.availableWidth, accuracy: 0.001)
    }

    func test_transfer_pane_to_other_worklane_reexpands_remaining_source_columns_to_fill_readable_width() throws {
        let layoutContext = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1500,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
        let sourceWorklaneID = WorklaneID("source")
        let targetWorklaneID = WorklaneID("target")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: sourceWorklaneID,
                    title: "SOURCE",
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
                ),
                WorklaneState(
                    id: targetWorklaneID,
                    title: "TARGET",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("target-pane"), title: "target")],
                        focusedPaneID: PaneID("target-pane")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: sourceWorklaneID
        )

        store.transferPaneToWorklane(
            paneID: PaneID("middle"),
            targetWorklaneID: targetWorklaneID,
            singleColumnWidth: layoutContext.singlePaneWidth
        )

        let sourceWorklane = try XCTUnwrap(store.worklanes.first(where: { $0.id == sourceWorklaneID }))
        let widths = sourceWorklane.paneStripState.columns.map(\.width)
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0] / widths[1], 3 / 7, accuracy: 0.001)
        XCTAssertEqual(widths.reduce(0, +) + layoutContext.sizing.interPaneSpacing, layoutContext.availableWidth, accuracy: 0.001)
    }

    func test_reorderPane_into_existing_column_moves_pane_into_stack_and_normalizes_widths() throws {
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
                    title: "MAIN",
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
                                id: PaneColumnID("right"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 700,
                                paneHeights: [4, 6],
                                focusedPaneID: PaneID("top"),
                                lastFocusedPaneID: PaneID("top")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                )
            ],
            layoutContext: layoutContext,
            activeWorklaneID: worklaneID
        )

        store.reorderPane(
            paneID: PaneID("left"),
            toColumnID: PaneColumnID("right"),
            atPaneIndex: 1,
            singleColumnWidth: layoutContext.singlePaneWidth
        )

        let columns = try XCTUnwrap(store.activeWorklane?.paneStripState.columns)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].id, PaneColumnID("right"))
        XCTAssertEqual(columns[0].panes.map(\.id), [PaneID("top"), PaneID("left"), PaneID("bottom")])
        XCTAssertEqual(columns[0].paneHeights, [4, 1, 6])
        XCTAssertEqual(columns[0].width, layoutContext.singlePaneWidth, accuracy: 0.001)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.id, PaneID("left"))
    }

    func test_focus_commands_update_only_active_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("api"),
                    title: "API",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("api-logs"), title: "logs"),
                            PaneState(id: PaneID("api-editor"), title: "editor"),
                            PaneState(id: PaneID("api-shell"), title: "shell"),
                        ],
                        focusedPaneID: PaneID("api-editor")
                    ),
                    nextPaneNumber: 1
                ),
                WorklaneState(
                    id: WorklaneID("web"),
                    title: "WEB",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("web-shell"), title: "shell"),
                        ],
                        focusedPaneID: PaneID("web-shell")
                    ),
                    nextPaneNumber: 1
                ),
            ],
            activeWorklaneID: WorklaneID("api")
        )

        store.send(.focusRight)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "shell")

        store.selectWorklane(id: WorklaneID("web"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "shell")

        store.selectWorklane(id: WorklaneID("api"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "shell")
    }

    func test_update_metadata_notifies_change_immediately() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var notificationCount = 0

        store.onChange = { _ in
            notificationCount += 1
        }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.metadata?.gitBranch, "main")
    }

    func test_apply_local_pane_context_uses_shell_branch_provisionally_and_clears_stale_review_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                paneContext: nil,
                origin: .shell,
                toolName: "claude",
                text: nil,
                artifactKind: .pullRequest,
                artifactLabel: "PR #42",
                artifactURL: URL(string: "https://example.com/pr/42")
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp",
                    gitBranch: "feature/review-band"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(auxiliaryState.metadata?.gitBranch, "main")
        XCTAssertEqual(auxiliaryState.shellContext?.gitBranch, "feature/review-band")
        XCTAssertNil(auxiliaryState.gitContext)
        XCTAssertNil(auxiliaryState.reviewState)
        XCTAssertNil(auxiliaryState.agentStatus?.artifactLink)
        XCTAssertNil(auxiliaryState.presentation.branch)
        XCTAssertEqual(auxiliaryState.presentation.branchDisplayText, "feature/review-band")
        XCTAssertNil(auxiliaryState.presentation.lookupBranch)
        XCTAssertNil(auxiliaryState.presentation.pullRequest)
        XCTAssertEqual(auxiliaryState.presentation.reviewChips, [])
        XCTAssertEqual(auxiliaryState.presentation.contextText, "feature/review-band · /tmp/project")
    }

    func test_updating_canonical_git_context_branch_clears_branch_derived_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
            )
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("feature/review-band")
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.branch,
            "feature/review-band"
        )
    }

    func test_default_worklane_shell_session_contains_agent_identity_environment() throws {
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)
        let pane = try XCTUnwrap(worklane.paneStripState.focusedPane)

        let request = pane.sessionRequest

        XCTAssertTrue(worklane.id.rawValue.hasPrefix("wl_"))
        XCTAssertTrue(pane.id.rawValue.hasPrefix("pn_"))
        XCTAssertTrue((request.environmentVariables["ZENTTY_WINDOW_ID"] ?? "").hasPrefix("wd_"))
        XCTAssertEqual(request.environmentVariables["ZENTTY_WORKLANE_ID"], worklane.id.rawValue)
        XCTAssertEqual(request.environmentVariables["ZENTTY_PANE_ID"], pane.id.rawValue)
        XCTAssertFalse((request.environmentVariables["ZENTTY_INSTANCE_SOCKET"] ?? "").isEmpty)
        XCTAssertFalse((request.environmentVariables["ZENTTY_PANE_TOKEN"] ?? "").isEmpty)
        XCTAssertFalse((request.environmentVariables["ZENTTY_CLI_BIN"] ?? "").isEmpty)
        if let cliBin = request.environmentVariables["ZENTTY_CLI_BIN"] {
            XCTAssertTrue(cliBin.contains("/Contents/Resources/bin/shared/zentty"))
        }
        XCTAssertNil(request.environmentVariables["ZENTTY_CLAUDE_HOOK_COMMAND"])
        XCTAssertNil(request.environmentVariables["ZENTTY_AGENT_BIN"])
        XCTAssertNil(request.environmentVariables["ZENTTY_AGENT_EVENT_COMMAND"])
        XCTAssertNil(request.environmentVariables["ZENTTY_AGENT_SIGNAL_COMMAND"])
        let allWrapperDirs = request.environmentVariables["ZENTTY_ALL_WRAPPER_BIN_DIRS"] ?? ""
        let path = request.environmentVariables["PATH"] ?? ""
        if !allWrapperDirs.isEmpty {
            for entry in allWrapperDirs.split(separator: ":") {
                XCTAssertTrue(String(entry).contains("/Contents/Resources/bin/"))
            }
        }
        XCTAssertTrue(path.contains("/Contents/Resources/bin/shared"))
        XCTAssertNil(request.environmentVariables["ZENTTY_WRAPPER_BIN_DIR"])
        XCTAssertNil(request.environmentVariables["ZENTTY_WRAPPER_BIN_DIRS"])
        if let shellIntegrationDirectory = request.environmentVariables["ZENTTY_SHELL_INTEGRATION_DIR"] {
            XCTAssertTrue(shellIntegrationDirectory.contains("/Contents/Resources/shell-integration"))
        }
    }

    func test_default_worklane_shell_session_exports_all_wrapper_directories_and_prepends_support_path() throws {
        let store = WorklaneStore(processEnvironment: ["PATH": "/usr/bin:/bin"])

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertNil(request.environmentVariables["ZENTTY_WRAPPER_BIN_DIR"])
        XCTAssertNil(request.environmentVariables["ZENTTY_WRAPPER_BIN_DIRS"])
        if let allWrapperDirs = request.environmentVariables["ZENTTY_ALL_WRAPPER_BIN_DIRS"] {
            XCTAssertTrue(allWrapperDirs.contains("/Contents/Resources/bin/claude"))
            XCTAssertTrue(allWrapperDirs.contains("/Contents/Resources/bin/codex"))
            XCTAssertTrue(allWrapperDirs.contains("/Contents/Resources/bin/opencode"))
        }
        let path = try XCTUnwrap(request.environmentVariables["PATH"])
        XCTAssertTrue(path.contains("/Contents/Resources/bin/shared"))
        XCTAssertTrue(path.hasSuffix(":/usr/bin:/bin"))
    }

    func test_default_worklane_shell_session_overrides_zsh_zdotdir_for_shell_integration() throws {
        let store = WorklaneStore()

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        if let zdotdir = request.environmentVariables["ZDOTDIR"] {
            XCTAssertTrue(zdotdir.contains("/Contents/Resources/shell-integration"))
            XCTAssertNotNil(request.environmentVariables["ZENTTY_SHELL_INTEGRATION"])
        } else {
            XCTAssertNil(request.environmentVariables["ZENTTY_SHELL_INTEGRATION"])
        }
    }

    func test_default_worklane_shell_session_sets_initial_working_directory_environment() throws {
        let store = WorklaneStore()

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], NSHomeDirectory())
    }

    func test_split_after_local_pane_sets_initial_working_directory_environment() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
    }

    func test_split_after_ignores_agent_working_directory_and_uses_terminal_cwd() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: NSHomeDirectory(),
                    home: NSHomeDirectory(),
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .lifecycle,
                state: .idle,
                origin: .compatibility,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: "/tmp/project"
            )
        )

        store.send(.splitAfterFocusedPane)

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.workingDirectory, NSHomeDirectory())
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], NSHomeDirectory())
    }

    func test_split_after_remote_pane_does_not_set_initial_working_directory_environment() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/remote-project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod-box"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertNil(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"])
        XCTAssertEqual(request.inheritFromPaneID, shellPaneID)
    }

    func test_split_after_remote_pane_seeds_remote_shell_context_for_child() throws {
        let store = WorklaneStore()
        let shellPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: shellPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/remote-project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod-box",
                    gitBranch: "main"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        let childPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let childAuxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[childPaneID])
        let childShellContext = try XCTUnwrap(childAuxiliaryState.shellContext)

        XCTAssertEqual(childShellContext.scope, .remote)
        XCTAssertEqual(childShellContext.path, "/srv/remote-project")
        XCTAssertEqual(childShellContext.home, "/home/peter")
        XCTAssertEqual(childShellContext.user, "peter")
        XCTAssertEqual(childShellContext.host, "prod-box")
        XCTAssertEqual(childShellContext.gitBranch, "main")
    }

    func test_second_split_from_remote_child_keeps_remote_inheritance_chain() throws {
        let store = WorklaneStore()
        let rootPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: rootPaneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/remote-project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod-box"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.send(.splitAfterFocusedPane)

        let firstChildPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let firstChildRequest = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(firstChildRequest.inheritFromPaneID, rootPaneID)

        store.send(.splitAfterFocusedPane)

        let secondChildPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let secondChildRequest = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)
        let secondChildShellContext = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[secondChildPaneID]?.shellContext)

        XCTAssertEqual(secondChildRequest.inheritFromPaneID, firstChildPaneID)
        XCTAssertNil(secondChildRequest.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"])
        XCTAssertEqual(secondChildShellContext.scope, .remote)
        XCTAssertEqual(secondChildShellContext.path, "/srv/remote-project")
    }

    func test_command_finished_does_not_promote_title_only_agent_to_unresolved_stop() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 1, durationNanoseconds: 500_000_000)
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_command_finished_promotes_explicit_running_agent_to_unresolved_stop() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 1, durationNanoseconds: 500_000_000)
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .unresolvedStop)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .claudeCode)
    }

    func test_command_finished_does_not_promote_running_agent_with_live_pid_to_unresolved_stop() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5"]
        try process.run()
        addTeardownBlock {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: process.processIdentifier,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 500_000_000)
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.trackedPID,
            process.processIdentifier
        )
    }

    func test_progress_report_event_stores_and_removes_terminal_progress() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let report = TerminalProgressReport(state: .indeterminate, progress: nil)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(report)
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.terminalProgress, report)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .remove, progress: nil))
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.terminalProgress)
    }

    func test_progress_report_activity_clears_blocked_agent_state_into_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Ship this?\n[Yes] [No]",
                interactionKind: .decision,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.none)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_submit_input_event_clears_blocked_claude_state_into_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Ship this?\n[Yes] [No]",
                interactionKind: .decision,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .userSubmittedInput
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.none)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_desktop_notification_event_surfaces_generic_needs_input_for_codex() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Waiting for your input")
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.genericInput)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Needs input")
    }

    func test_desktop_notification_event_promotes_running_codex_session_to_needs_input() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Waiting for your input")
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.genericInput)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.sessionID, "session-1")
    }

    func test_desktop_notification_event_classifies_codex_approval_request_as_requires_approval() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Approval requested: npm publish")
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.approval)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Requires approval"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Approval requested: npm publish"
        )
    }

    func test_desktop_notification_event_can_recognize_codex_from_notification_title_without_metadata() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Approval requested: npm publish")
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .codex)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.approval)
        )
    }

    func test_desktop_notification_event_can_recognize_codex_from_working_title_without_process_name() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: nil, body: "Question requested: Next Step")
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .codex)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.decision)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Needs decision"
        )
    }

    func test_desktop_notification_event_classifies_codex_question_request_as_decision() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(
                    title: "Codex",
                    body: "Question requested: Choose deployment target"
                )
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.decision)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Needs decision"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Question requested: Choose deployment target"
        )
    }

    func test_desktop_notification_event_classifies_natural_language_codex_question_with_options_as_decision() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(
                    title: "Codex",
                    body: "What should I ask you about?\n[Code] [Product] [Random]"
                )
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.decision)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Needs decision"
        )
    }

    func test_desktop_notification_event_classifies_codex_plan_mode_prompt_as_approval() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(
                    title: "Codex",
                    body: "Plan mode prompt: Implement this plan?"
                )
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.approval)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Requires approval"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Plan mode prompt: Implement this plan?"
        )
    }

    func test_submit_input_event_clears_blocked_codex_state_into_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Waiting for your input",
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .userSubmittedInput
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.none)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.sessionID, "session-1")
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_running_codex_title_clears_stale_generic_needs_input_into_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting for your input",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.genericInput)
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.none)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_running_codex_title_does_not_override_active_codex_question_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Codex",
                text: "What should Codex do next?",
                interactionKind: .question,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Follow up on the question",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.question)
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Needs decision"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.rememberedTitle,
            "Follow up on the question"
        )
    }

    func test_ready_codex_title_after_inferred_running_surfaces_agent_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_ready_codex_title_after_meaningful_intermediate_title_surfaces_agent_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Implemented the Pane Layout fix",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_submit_input_event_promotes_ready_codex_session_back_into_running() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Investigate lifecycle transitions",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")

        store.handleTerminalEvent(
            paneID: paneID,
            event: .userSubmittedInput
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_starting_different_tool_clears_stale_ready_status() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Investigate lifecycle transitions",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                confidence: .explicit,
                sessionID: "claude-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
    }

    func test_submit_input_event_promotes_starting_codex_session_into_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Starting ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .userSubmittedInput
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_ready_codex_title_after_running_surfaces_agent_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Investigate lifecycle transitions",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
    }

    func test_working_codex_title_promotes_explicit_session_to_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Demo",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_existing_working_codex_title_promotes_new_explicit_starting_session_to_running() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Demo",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_cold_ready_codex_title_does_not_surface_agent_ready() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertNotEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_ready_codex_title_does_not_override_active_question_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "What should Codex do next?",
                interactionKind: .question,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Needs decision")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_ready_codex_title_clears_stale_generic_needs_input_and_surfaces_agent_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting for your input",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.genericInput)
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.interactionLabel)
    }

    func test_waiting_codex_title_clears_stale_ready_without_surfacing_needs_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting · zentty main",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.runtimePhase, .idle)
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.isReady == true)
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_waiting_codex_title_does_not_override_running_session_with_needs_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting · zentty main",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.runtimePhase, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_waiting_for_your_input_codex_title_still_surfaces_needs_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting for your input",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind,
            .some(.genericInput)
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Needs input")
    }

    func test_interrupted_codex_run_does_not_surface_ready_and_new_claude_start_stays_starting() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .idle,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .stopCandidate,
                confidence: .explicit,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertNotEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Agent ready")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                confidence: .explicit,
                sessionID: "claude-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .claudeCode)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .starting)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText)
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_waiting_codex_title_preserves_specific_blocked_prompt_copy() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Plan mode prompt: Implement this plan?",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting · zentty main",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Requires approval")
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind, .approval)
    }

    func test_completion_notification_phrase_agent_turn_complete_surfaces_agent_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Agent turn complete")
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_desktop_notification_event_ignores_non_actionable_copy_for_codex() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Turn complete")
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_session_scoped_idle_signal_retires_running_codex_session() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let idleCommand = try AgentSignalCommand.parse(
            arguments: [
                "agent-signal",
                "lifecycle",
                "idle",
                "--origin", "explicit-api",
                "--tool", "Codex",
                "--session-id", "session-1",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": paneID.rawValue,
            ]
        )
        store.applyAgentStatusPayload(idleCommand.payload)

        let status = store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus
        XCTAssertEqual(status?.state, .idle)
        XCTAssertEqual(status?.sessionID, "session-1")
        XCTAssertTrue(status?.hasObservedRunning ?? false)
    }

    func test_command_finished_clears_active_terminal_progress() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .set, progress: 40))
        )

        XCTAssertNotNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.terminalProgress)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 250_000_000)
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.terminalProgress)
    }

    func test_metadata_update_to_non_agent_title_clears_inferred_attention_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 1, durationNanoseconds: 500_000_000)
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@host:/tmp/project",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_explicit_running_replaces_prior_attention_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
    }

    func test_prompt_idle_alone_does_not_create_attention_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .promptIdle,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_prompt_idle_retires_running_claude_session_into_idle() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .promptIdle,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
    }

    func test_idle_transition_surfaces_agent_ready_after_running_agent_completes() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
    }

    @MainActor
    func test_idle_transition_waits_before_surfacing_agent_ready() async throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertNotEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )

        let readyExpectation = expectation(description: "agent ready surfaced after debounce")
        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let updatedPaneID, let impacts) = change,
                  updatedPaneID == paneID,
                  impacts.contains(.attention),
                  store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText == "Agent ready"
            else {
                return
            }
            readyExpectation.fulfill()
        }
        defer { store.unsubscribe(subscription) }

        await fulfillment(of: [readyExpectation], timeout: 1.0)
    }

    @MainActor
    func test_work_resuming_within_ready_window_suppresses_agent_ready() async throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertNotEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_opencode_idle_transition_surfaces_agent_ready_after_running_session_completes() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "OpenCode",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_focusing_completed_agent_pane_clears_agent_ready_back_to_idle() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )

        store.focusPane(id: paneID)

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Idle")
    }

    func test_refocusing_already_focused_pane_without_ready_state_is_noop() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        store.focusPane(id: paneID)

        XCTAssertTrue(changes.isEmpty)
    }

    func test_user_input_after_completion_promotes_explicit_ready_codex_session_back_to_running() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .userSubmittedInput
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_progress_report_after_completion_does_not_clear_agent_ready_without_new_running_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: "OpenCode",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_idle_codex_signal_does_not_downgrade_active_approval_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Approval requested: edit Sources/App.swift",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind, .approval)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Requires approval")
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_shell_command_running_alone_does_not_create_running_agent_status() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_pid_attach_alone_creates_non_visible_starting_agent_status() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .starting)
        XCTAssertEqual(status.tool, .codex)
        XCTAssertEqual(status.trackedPID, 4242)
        XCTAssertFalse(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.isWorking ?? true)
    }

    func test_command_finished_does_not_promote_starting_agent_to_unresolved_stop() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 1, durationNanoseconds: 250_000_000)
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .starting)
    }

    func test_update_review_state_stores_and_clears_review_state_for_a_pane() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let reviewState = WorklaneReviewState(
            branch: "feature/review-band",
            pullRequest: WorklanePullRequestSummary(
                number: 128,
                url: URL(string: "https://example.com/pr/128"),
                state: .draft
            ),
            reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
        )

        store.updateReviewState(paneID: paneID, reviewState: reviewState)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState, reviewState)

        store.updateReviewState(paneID: paneID, reviewState: nil)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_update_review_resolution_updates_review_state_with_single_notification() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var notificationCount = 0

        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/review-band",
                repositoryRoot: "/tmp/review-band",
                reference: .branch("feature/review-band")
            )
        )

        store.onChange = { _ in
            notificationCount += 1
        }

        let resolution = WorklaneReviewResolution(
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
            )
        )

        store.updateReviewResolution(paneID: paneID, resolution: resolution)

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState, resolution.reviewState)

        store.updateReviewResolution(
            paneID: paneID,
            resolution: WorklaneReviewResolution(reviewState: nil)
        )

        XCTAssertEqual(notificationCount, 2)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_update_review_resolution_preserves_existing_state_on_transient_empty_refresh() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let existingResolution = WorklaneReviewResolution(
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
            )
        )
        store.updateReviewResolution(paneID: paneID, resolution: existingResolution)

        var notificationCount = 0
        store.onChange = { _ in
            notificationCount += 1
        }

        store.updateReviewResolution(
            paneID: paneID,
            resolution: WorklaneReviewResolution(
                reviewState: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        )

        XCTAssertEqual(notificationCount, 0)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState, existingResolution.reviewState)
    }

    func test_repeated_progress_report_with_same_state_does_not_notify_again() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var auxiliaryStateUpdateCount = 0

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, _) = change, changedPaneID == paneID else {
                return
            }
            auxiliaryStateUpdateCount += 1
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        let report = TerminalProgressReport(state: .set, progress: 40)
        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report))
        auxiliaryStateUpdateCount = 0

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report))

        XCTAssertEqual(auxiliaryStateUpdateCount, 0)
    }

    func test_local_pane_context_for_focused_pane_notifies_canvas_and_open_with_impacts() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var recordedImpacts: [WorklaneAuxiliaryInvalidation] = []

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, let impacts) = change, changedPaneID == paneID else {
                return
            }
            recordedImpacts.append(impacts)
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/local-project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let impacts = try XCTUnwrap(recordedImpacts.last)
        XCTAssertTrue(impacts.contains(.canvas))
        XCTAssertTrue(impacts.contains(.openWith))
    }

    func test_updating_git_context_notifies_sidebar_header_and_review_refresh_impacts() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            )
        )

        var recordedImpacts: [WorklaneAuxiliaryInvalidation] = []
        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, let impacts) = change, changedPaneID == paneID else {
                return
            }
            recordedImpacts.append(impacts)
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )

        let impacts = try XCTUnwrap(recordedImpacts.last)
        XCTAssertTrue(impacts.contains(.sidebar))
        XCTAssertTrue(impacts.contains(.header))
        XCTAssertTrue(impacts.contains(.reviewRefresh))
        XCTAssertFalse(impacts.contains(.canvas))
        XCTAssertFalse(impacts.contains(.openWith))
    }

    func test_updating_non_focused_pane_metadata_notifies_sidebar_without_header_or_attention() throws {
        let store = WorklaneStore()
        store.send(.splitHorizontally)

        let activeWorklane = try XCTUnwrap(store.activeWorklane)
        let focusedPaneID = try XCTUnwrap(activeWorklane.paneStripState.focusedPaneID)
        let backgroundPaneID = try XCTUnwrap(
            activeWorklane.paneStripState.panes.map(\.id).first(where: { $0 != focusedPaneID })
        )

        var recordedImpacts: [WorklaneAuxiliaryInvalidation] = []
        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, let impacts) = change,
                  changedPaneID == backgroundPaneID else {
                return
            }
            recordedImpacts.append(impacts)
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        store.updateMetadata(
            paneID: backgroundPaneID,
            metadata: TerminalMetadata(
                title: "build logs",
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )

        let impacts = try XCTUnwrap(recordedImpacts.first)
        XCTAssertTrue(impacts.contains(.sidebar))
        XCTAssertFalse(impacts.contains(.header))
        XCTAssertFalse(impacts.contains(.attention))
        XCTAssertFalse(impacts.contains(.canvas))
    }

    func test_clearing_agent_status_keeps_review_state_for_that_pane() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: nil,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNotNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_explicit_needs_input_beats_prompt_idle_shell_state() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Allow write?",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .promptIdle,
                origin: .shell,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionState, .awaitingHuman)
    }

    func test_updating_canonical_git_context_clears_branch_derived_review_state_when_branch_changes() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            )
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("feature/review-band")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: .pullRequest,
                artifactLabel: "PR #128",
                artifactURL: URL(string: "https://example.com/pr/128")
            )
        )

        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.artifactLink)
    }

    func test_equal_priority_needs_input_update_does_not_downgrade_specific_waiting_copy() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your approval",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your attention",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Claude needs your approval")
    }

    func test_equal_priority_needs_input_update_can_upgrade_generic_waiting_copy() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your attention",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude needs your approval",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Claude needs your approval")
    }

    func test_claude_ask_user_question_sequence_stays_needs_decision() throws {
        let store = WorklaneStore()
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let sessionStore = try ClaudeHookSessionStore()

        let environment = [
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]

        let sessionStart = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"SessionStart",
              "session_id":"session-1",
              "cwd":"/tmp/project"
            }
            """.utf8)
        )
        let preToolUse = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )
        let permissionRequest = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PermissionRequest",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion"
            }
            """.utf8)
        )
        let notification = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"Notification",
              "session_id":"session-1",
              "notification_type":"permission_prompt",
              "message":"Claude Code needs your attention"
            }
            """.utf8)
        )

        for input in [sessionStart, preToolUse, permissionRequest, notification] {
            let payloads = try AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: environment,
                sessionStore: sessionStore
            )
            for payload in payloads {
                store.applyAgentStatusPayload(payload)
            }
        }

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind, .decision)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Needs decision")
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Ship this?\n[Yes] [No]"
        )
    }

    func test_clear_stale_agent_sessions_removes_dead_running_process_status() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.1"]
        try process.run()

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: process.processIdentifier,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        process.waitUntilExit()
        store.clearStaleAgentSessions()

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .unresolvedStop)
    }

    func test_clear_stale_agent_sessions_persists_reducer_cleanup_even_when_visible_status_is_unchanged() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let now = Date()

        var reducerState = PaneAgentReducerState()
        reducerState.sessionsByID["session-running"] = PaneAgentSessionState(
            sessionID: "session-running",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now,
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )
        reducerState.sessionsByID["session-completed"] = PaneAgentSessionState(
            sessionID: "session-completed",
            parentSessionID: nil,
            tool: .claudeCode,
            state: .idle,
            text: nil,
            artifactLink: nil,
            updatedAt: now.addingTimeInterval(-PaneAgentReducerState.idleVisibilityWindow - 5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: now.addingTimeInterval(-1),
            unresolvedStopVisibleUntil: nil
        )

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID]?.agentReducerState = reducerState
        worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = reducerState.reducedStatus(now: now)
        store.activeWorklane = worklane

        store.clearStaleAgentSessions()

        let aux = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(aux.agentStatus?.state, .running)
        XCTAssertEqual(aux.agentReducerState.sessionsByID.keys.sorted(), ["session-running"])
    }

    func test_pane_context_signal_stores_local_context_and_formats_home_relative_display() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.shellContext,
            PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: nil,
                host: nil
            )
        )
        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "~/src/zentty")
    }

    func test_pane_context_local_home_with_user_and_host_shows_identity() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter",
                    home: "/Users/peter",
                    user: "peter",
                    host: "m1-pro-peter"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter@m1-pro-peter:~")
    }

    func test_pane_context_local_home_with_only_user_shows_user_identity() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter",
                    home: "/Users/peter",
                    user: "peter",
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter:~")
    }

    func test_pane_context_local_home_without_identity_falls_back_to_tilde() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "~")
    }

    func test_pane_context_local_subdirectory_with_identity_shows_only_path() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: "peter",
                    host: "m1-pro-peter"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "~/src/zentty")
    }

    func test_pane_context_signal_formats_remote_identity_and_path() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/home/peter/project",
                    home: "/home/peter",
                    user: "peter",
                    host: "gilfoyle"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text,
            "peter@gilfoyle ~/project"
        )
    }

    func test_pane_context_signal_uses_remote_identity_without_path_fallback() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: nil,
                    home: "/home/peter",
                    user: "peter",
                    host: "gilfoyle"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter@gilfoyle")
    }

    func test_pane_context_signal_clear_removes_stored_context() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: nil,
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.shellContext)
        XCTAssertNil(store.activeWorklane?.paneBorderContextDisplayByPaneID[paneID])
    }

    func test_pane_context_is_removed_when_pane_closes() throws {
        let store = WorklaneStore()
        store.send(.splitAfterFocusedPane)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.closePane(id: paneID)

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.shellContext)
    }

    func test_updating_metadata_clears_branch_derived_review_state_when_terminal_reports_new_working_directory() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@host:~/Development/project-a",
                currentWorkingDirectory: "/Users/peter/Development/project-a",
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "feature/project-a",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorklaneReviewChip(text: "Draft", style: .info)]
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@host:~/Development/project-b",
                currentWorkingDirectory: "/Users/peter/Development/project-b",
                processName: "zsh",
                gitBranch: nil
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_updating_codex_spinner_title_variant_notifies_sidebar_immediately() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        // Notification can arrive via either channel:
        //   1. `.auxiliaryStateUpdated(.sidebar)` via the slow path (e.g. for
        //      meaningful changes like cwd/branch/phase transitions)
        //   2. `.volatileAgentTitleUpdated` via the fast path when the
        //      classifier recognizes a pure codex spinner variant tick
        // Both channels ultimately update the sidebar row label for the
        // changed pane. The test asserts the intent — "sidebar is notified
        // of the spinner change" — without binding to the specific channel.
        var sidebarNotified = false
        var headerNotified = false
        let subscription = store.subscribe { change in
            switch change {
            case let .auxiliaryStateUpdated(_, changedPaneID, impacts)
                where changedPaneID == paneID:
                if impacts.contains(.sidebar) { sidebarNotified = true }
                if impacts.contains(.header) { headerNotified = true }
            case let .volatileAgentTitleUpdated(_, changedPaneID)
                where changedPaneID == paneID:
                sidebarNotified = true
            default:
                break
            }
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        sidebarNotified = false
        headerNotified = false

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertTrue(sidebarNotified, "sidebar must be notified of the spinner variant change")
        XCTAssertFalse(
            headerNotified,
            "chrome header must not be structurally invalidated for a pure spinner tick"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.metadata?.title,
            "Working ⠙ zentty"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Running"
        )
    }

    func test_updating_codex_status_title_subject_notifies_sidebar_immediately() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.knownNonRepositoryPaths.insert("/tmp/project")

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                state: .running,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ Investigate sidebar titles",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var recordedImpacts: [WorklaneAuxiliaryInvalidation] = []
        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, let impacts) = change, changedPaneID == paneID else {
                return
            }
            recordedImpacts.append(impacts)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ Make pane titles reactive again",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let impacts = try XCTUnwrap(recordedImpacts.last)
        XCTAssertTrue(impacts.contains(.sidebar))
        XCTAssertTrue(impacts.contains(.header))
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.rememberedTitle,
            "Make pane titles reactive again"
        )
    }

    func test_default_worklane_disables_ghostty_stderr_logging_when_unset() throws {
        let store = WorklaneStore(processEnvironment: ["PATH": "/usr/bin:/bin"])

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["GHOSTTY_LOG"], "macos,no-stderr")
    }

    // MARK: - Cross-Worklane Vertical Navigation

    func test_focusUp_at_top_pane_switches_to_previous_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [
                                    PaneState(id: PaneID("ws1-top"), title: "ws1-top"),
                                    PaneState(id: PaneID("ws1-bottom"), title: "ws1-bottom"),
                                ],
                                width: 900,
                                focusedPaneID: PaneID("ws1-top"),
                                lastFocusedPaneID: PaneID("ws1-top")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws2")
        )

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
    }

    func test_focusDown_at_bottom_pane_switches_to_next_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws1-pane"), title: "ws1-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-pane"),
                                lastFocusedPaneID: PaneID("ws1-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws2"))
    }

    func test_focusUp_at_top_wraps_to_last_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws1-pane"), title: "ws1-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-pane"),
                                lastFocusedPaneID: PaneID("ws1-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws2"))
    }

    func test_focusDown_at_bottom_wraps_to_first_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws1-pane"), title: "ws1-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-pane"),
                                lastFocusedPaneID: PaneID("ws1-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws2")
        )

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
    }

    func test_focusUp_single_worklane_is_noop() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("only"),
                    title: "ONLY",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("pane"), title: "pane")],
                                width: 900,
                                focusedPaneID: PaneID("pane"),
                                lastFocusedPaneID: PaneID("pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("only")
        )

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("only"))

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("only"))
    }

    func test_focusUp_mid_column_stays_within_column() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [
                                    PaneState(id: PaneID("top"), title: "top"),
                                    PaneState(id: PaneID("middle"), title: "middle"),
                                    PaneState(id: PaneID("bottom"), title: "bottom"),
                                ],
                                width: 900,
                                focusedPaneID: PaneID("middle"),
                                lastFocusedPaneID: PaneID("middle")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "top")

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.title, "middle")
    }

    func test_single_pane_worklane_both_directions_jump() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("ws1"),
                    title: "WS1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws1-pane"), title: "ws1-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws1-pane"),
                                lastFocusedPaneID: PaneID("ws1-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("ws2"),
                    title: "WS2",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("col"),
                                panes: [PaneState(id: PaneID("ws2-pane"), title: "ws2-pane")],
                                width: 900,
                                focusedPaneID: PaneID("ws2-pane"),
                                lastFocusedPaneID: PaneID("ws2-pane")
                            )
                        ],
                        focusedColumnID: PaneColumnID("col")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("ws1")
        )

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws2"))

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("ws1"))
    }

    func test_default_worklane_preserves_explicit_ghostty_log_override() throws {
        let store = WorklaneStore(
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "GHOSTTY_LOG": "stderr"
            ]
        )

        let request = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["GHOSTTY_LOG"], "stderr")
    }

}
