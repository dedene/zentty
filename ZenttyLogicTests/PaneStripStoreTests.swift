import XCTest
@testable import Zentty

@MainActor
final class PaneStripStoreTests: XCTestCase {
    func test_store_starts_with_single_main_workspace_and_first_active() {
        let store = WorkspaceStore()

        XCTAssertEqual(store.workspaces.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorkspace?.title, "MAIN")
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.panes.first?.sessionRequest.workingDirectory,
            NSHomeDirectory()
        )
    }

    func test_select_workspace_switches_active_workspace_without_resetting_other_workspace_state() throws {
        let store = WorkspaceStore()
        store.createWorkspace()

        let workspace2ID = try XCTUnwrap(store.workspaces.first(where: { $0.title == "WS 2" })?.id)
        let mainID = try XCTUnwrap(store.workspaces.first(where: { $0.title == "MAIN" })?.id)
        store.selectWorkspace(id: workspace2ID)
        store.send(.splitAfterFocusedPane)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell", "pane 1"])

        store.selectWorkspace(id: mainID)
        XCTAssertEqual(store.activeWorkspace?.title, "MAIN")
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])

        store.selectWorkspace(id: workspace2ID)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell", "pane 1"])
    }

    func test_create_workspace_adds_new_workspace_with_single_shell_pane_and_focuses_it() {
        let store = WorkspaceStore()

        store.createWorkspace()

        XCTAssertEqual(store.workspaces.map(\.title), ["MAIN", "WS 2"])
        XCTAssertEqual(store.activeWorkspace?.title, "WS 2")
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.surfaceContext,
            .tab
        )
    }

    func test_default_workspace_uses_window_surface_context() throws {
        let store = WorkspaceStore()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.surfaceContext, .window)
    }

    func test_split_after_inserts_adjacent_pane_and_inherits_focused_working_directory() throws {
        let store = WorkspaceStore()
        _ = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: PaneID("workspace-main-shell"),
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project")
        )

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "pane 1")
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/project"
        )
        XCTAssertNil(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            PaneID("workspace-main-shell")
        )
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.surfaceContext, .split)
    }

    func test_split_after_falls_back_to_home_when_focused_working_directory_is_missing() throws {
        let store = WorkspaceStore()
        _ = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "pane 1")
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            NSHomeDirectory()
        )
        XCTAssertNil(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
    }

    func test_split_after_uses_focused_local_pane_context_when_metadata_is_missing() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertNil(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID)
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_split_after_prefers_focused_local_pane_context_over_seed_metadata() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let seededWorkingDirectory = try XCTUnwrap(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory
        )

        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: seededWorkingDirectory)
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.workingDirectory, "/tmp/local-project")
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
        XCTAssertNil(request.inheritFromPaneID)
        XCTAssertEqual(request.configInheritanceSourcePaneID, shellPaneID)
    }

    func test_split_after_uses_focused_remote_pane_context_when_metadata_is_missing() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/srv/remote-project"
        )
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID,
            shellPaneID
        )
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_create_workspace_uses_last_focused_local_pane_context() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        store.createWorkspace()

        XCTAssertEqual(store.activeWorkspace?.title, "WS 2")
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            shellPaneID
        )
    }

    func test_create_workspace_prefers_last_focused_local_pane_context_over_seed_metadata() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let seededWorkingDirectory = try XCTUnwrap(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory
        )

        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: seededWorkingDirectory)
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        store.createWorkspace()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.workingDirectory, "/tmp/local-project")
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
        XCTAssertEqual(request.configInheritanceSourcePaneID, shellPaneID)
    }

    func test_create_workspace_keeps_last_focused_local_directory_when_current_focus_is_remote() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
        let remotePaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        store.createWorkspace()

        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/local-project"
        )
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.configInheritanceSourcePaneID,
            remotePaneID
        )
    }

    func test_split_horizontally_reuses_source_column_width_for_laptop_context() throws {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorkspaceStore(layoutContext: layoutContext)

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.map(\.width), [910, 910])
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
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.map(\.width), [1200, 1200])
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
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.map(\.width), [1600, 1600])
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
        let store = WorkspaceStore(layoutContext: layoutContext)

        store.send(.splitHorizontally)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.map(\.width), [1720, 1720])
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
        let store = WorkspaceStore(layoutContext: initialContext)

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.width ?? 0, 1210, accuracy: 0.001)
    }

    func test_updating_layout_context_scales_multi_pane_widths_proportionally_to_viewport() {
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
        let store = WorkspaceStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.map(\.width), [1137.5, 1137.5])
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
        let store = WorkspaceStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)

        var changeNotifications = 0
        store.onChange = { _ in
            changeNotifications += 1
        }

        store.updateLayoutContext(updatedContext)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.layoutSizing, collapsedSizing)
        XCTAssertEqual(changeNotifications, 1)
    }

    func test_updating_from_fallback_layout_context_reprojects_initial_shell_to_current_full_width() {
        let store = WorkspaceStore(layoutContext: .fallback)
        let actualContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1268,
            leadingVisibleInset: 290
        )

        store.updateLayoutContext(actualContext)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.width ?? 0, 978, accuracy: 0.001)
    }

    func test_closing_back_to_single_pane_restores_full_readable_width() {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorkspaceStore(layoutContext: layoutContext)

        store.send(.splitAfterFocusedPane)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.width ?? 0, 910, accuracy: 0.001)
    }

    func test_split_vertically_adds_pane_inside_current_column() {
        let store = WorkspaceStore()
        store.updatePaneViewportHeight(640)

        store.send(.splitVertically)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "pane 1")
    }

    func test_split_vertically_refuses_when_viewport_height_is_below_minimum_equalized_height() {
        let store = WorkspaceStore()
        store.updatePaneViewportHeight(300)

        store.send(.splitVertically)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.panes.map(\.title), ["shell"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "shell")
    }

    func test_closing_focused_pane_inside_vertical_stack_prefers_lower_neighbor() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.count, 1)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns.first?.panes.map(\.title), ["top", "bottom"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "bottom")
    }

    func test_resize_focused_pane_uses_last_interacted_vertical_divider() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
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

        let heights = store.activeWorkspace?.paneStripState.columns[0].resolvedPaneHeights(
            totalHeight: 920,
            spacing: store.activeWorkspace?.paneStripState.layoutSizing.interPaneSpacing ?? 6
        )
        XCTAssertEqual(heights?[1] ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(heights?[2] ?? 0, 450, accuracy: 0.001)
    }

    func test_resize_focused_pane_left_grows_only_the_focused_column() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
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

        let columns = store.activeWorkspace?.paneStripState.columns
        XCTAssertEqual(columns?[0].width ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(columns?[1].width ?? 0, 440, accuracy: 0.001)
        XCTAssertEqual(columns?[2].width ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.lastInteractedDivider,
            .column(afterColumnID: PaneColumnID("left"))
        )
    }

    func test_reset_active_workspace_layout_restores_default_widths_and_equal_heights() {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1400,
            leadingVisibleInset: 0
        )
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.resetActiveWorkspaceLayout()

        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns[0].width ?? 0, layoutContext.newPaneWidth, accuracy: 0.001)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.columns[1].width ?? 0, layoutContext.newPaneWidth, accuracy: 0.001)
        let heights = store.activeWorkspace?.paneStripState.columns[0].resolvedPaneHeights(
            totalHeight: 920,
            spacing: store.activeWorkspace?.paneStripState.layoutSizing.interPaneSpacing ?? 6
        )
        XCTAssertEqual(heights?[0] ?? 0, heights?[1] ?? 0, accuracy: 0.001)
    }

    func test_focus_up_and_down_move_within_vertical_stack() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.send(.focusDown)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "bottom")

        store.send(.focusUp)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "middle")
    }

    func test_focus_first_and_last_column_move_between_columns() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("main"),
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
            activeWorkspaceID: WorkspaceID("main")
        )

        store.send(.focusFirstColumn)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedColumn?.id, PaneColumnID("left"))

        store.send(.focusLastColumn)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedColumn?.id, PaneColumnID("right"))
    }

    func test_split_before_inserts_adjacent_pane_before_focus() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("api"),
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
            activeWorkspaceID: WorkspaceID("api")
        )

        store.send(.splitBeforeFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell", "pane 1", "editor"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "pane 1")
    }

    func test_close_removes_focused_pane_inside_active_workspace_only() throws {
        let store = WorkspaceStore()
        store.createWorkspace()
        let workspace2ID = try XCTUnwrap(store.workspaces.first(where: { $0.title == "WS 2" })?.id)

        store.selectWorkspace(id: workspace2ID)
        store.send(.splitAfterFocusedPane)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])

        store.selectWorkspace(id: WorkspaceID("workspace-main"))
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])
    }

    func test_close_focused_pane_on_single_pane_workspace_closes_workspace_when_another_workspace_exists() throws {
        let store = WorkspaceStore()
        store.createWorkspace()

        let mainID = try XCTUnwrap(store.workspaces.first(where: { $0.title == "MAIN" })?.id)
        let workspace2ID = try XCTUnwrap(store.workspaces.first(where: { $0.title == "WS 2" })?.id)

        store.selectWorkspace(id: workspace2ID)
        store.send(.closeFocusedPane)

        XCTAssertEqual(store.workspaces.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorkspaceID, mainID)
    }

    func test_close_focused_pane_on_last_remaining_workspace_keeps_single_shell_open() {
        let store = WorkspaceStore()

        store.send(.closeFocusedPane)

        XCTAssertEqual(store.workspaces.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])
    }

    func test_close_pane_removes_requested_pane_from_active_workspace() throws {
        let store = WorkspaceStore()

        store.send(.splitAfterFocusedPane)
        let insertedPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.count, 2)

        store.closePane(id: insertedPaneID)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.count, 1)
        XCTAssertFalse(store.activeWorkspace?.paneStripState.panes.contains(where: { $0.id == insertedPaneID }) ?? true)
    }

    func test_focus_commands_update_only_active_workspace() {
        let store = WorkspaceStore(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("api"),
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
                WorkspaceState(
                    id: WorkspaceID("web"),
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
            activeWorkspaceID: WorkspaceID("api")
        )

        store.send(.focusRight)
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "shell")

        store.selectWorkspace(id: WorkspaceID("web"))
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "shell")

        store.selectWorkspace(id: WorkspaceID("api"))
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "shell")
    }

    func test_update_metadata_notifies_change_immediately() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        var notificationCount = 0

        store.onChange = { _ in
            notificationCount += 1
        }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.metadata?.gitBranch, "main")
    }

    func test_apply_local_pane_context_updates_metadata_git_branch() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(
            store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.metadata?.gitBranch,
            "feature/review-band"
        )
    }

    func test_apply_local_pane_context_branch_change_clears_branch_derived_state() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project", gitBranch: "main")
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            )
        )
        store.updateInferredArtifact(
            paneID: paneID,
            artifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #42",
                url: URL(string: "https://example.com/pr/42")!,
                isExplicit: false
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact)
        XCTAssertEqual(
            store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.metadata?.gitBranch,
            "feature/review-band"
        )
    }

    func test_default_workspace_shell_session_contains_agent_identity_environment() throws {
        let store = WorkspaceStore()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["ZENTTY_WORKSPACE_ID"], "workspace-main")
        XCTAssertEqual(request.environmentVariables["ZENTTY_PANE_ID"], "workspace-main-shell")
        XCTAssertFalse((request.environmentVariables["ZENTTY_AGENT_BIN"] ?? "").isEmpty)
        XCTAssertEqual(request.environmentVariables["ZENTTY_AGENT_SIGNAL_COMMAND"], "\(request.environmentVariables["ZENTTY_AGENT_BIN"]!) agent-signal")
        XCTAssertEqual(request.environmentVariables["ZENTTY_CLAUDE_HOOK_COMMAND"], "\(request.environmentVariables["ZENTTY_AGENT_BIN"]!) claude-hook")
        XCTAssertTrue((request.environmentVariables["ZENTTY_WRAPPER_BIN_DIR"] ?? "").contains("/Contents/Resources/bin"))
        XCTAssertTrue((request.environmentVariables["PATH"] ?? "").contains("/Contents/Resources/bin"))
        XCTAssertTrue((request.environmentVariables["ZENTTY_SHELL_INTEGRATION_DIR"] ?? "").contains("/Contents/Resources/shell-integration"))
    }

    func test_default_workspace_shell_session_overrides_zsh_zdotdir_for_shell_integration() throws {
        let store = WorkspaceStore()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertTrue((request.environmentVariables["ZDOTDIR"] ?? "").contains("/Contents/Resources/shell-integration"))
        XCTAssertNotNil(request.environmentVariables["ZENTTY_SHELL_INTEGRATION"])
    }

    func test_default_workspace_shell_session_sets_initial_working_directory_environment() throws {
        let store = WorkspaceStore()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], NSHomeDirectory())
    }

    func test_split_after_local_pane_sets_initial_working_directory_environment() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertEqual(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"], "/tmp/local-project")
    }

    func test_split_after_remote_pane_does_not_set_initial_working_directory_environment() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)
        XCTAssertNil(request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"])
        XCTAssertEqual(request.inheritFromPaneID, shellPaneID)
    }

    func test_command_finished_does_not_promote_title_only_agent_to_unresolved_stop() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_command_finished_promotes_explicit_running_agent_to_unresolved_stop() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .unresolvedStop)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .claudeCode)
    }

    func test_progress_report_event_stores_and_removes_terminal_progress() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let report = TerminalProgressReport(state: .indeterminate, progress: nil)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(report)
        )

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.terminalProgress, report)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .remove, progress: nil))
        )

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.terminalProgress)
    }

    func test_command_finished_clears_active_terminal_progress() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .set, progress: 40))
        )

        XCTAssertNotNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.terminalProgress)

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 250_000_000)
        )

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.terminalProgress)
    }

    func test_metadata_update_to_non_agent_title_clears_inferred_attention_state() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_explicit_running_replaces_prior_attention_state() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
    }

    func test_prompt_idle_alone_does_not_create_attention_state() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_shell_command_running_alone_does_not_create_running_agent_status() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_pid_attach_alone_creates_non_visible_starting_agent_status() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let status = try XCTUnwrap(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .starting)
        XCTAssertEqual(status.tool, .codex)
        XCTAssertEqual(status.trackedPID, 4242)
        XCTAssertFalse(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.isWorking ?? true)
    }

    func test_command_finished_does_not_promote_starting_agent_to_unresolved_stop() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .starting)
    }

    func test_update_review_state_stores_and_clears_review_state_for_a_pane() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let reviewState = WorkspaceReviewState(
            branch: "feature/review-band",
            pullRequest: WorkspacePullRequestSummary(
                number: 128,
                url: URL(string: "https://example.com/pr/128"),
                state: .draft
            ),
            reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
        )

        store.updateReviewState(paneID: paneID, reviewState: reviewState)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState, reviewState)

        store.updateReviewState(paneID: paneID, reviewState: nil)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_update_review_resolution_updates_review_state_and_inferred_artifact_with_single_notification() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        var notificationCount = 0

        store.onChange = { _ in
            notificationCount += 1
        }

        let resolution = WorkspaceReviewResolution(
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
            ),
            inferredArtifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )

        store.updateReviewResolution(paneID: paneID, resolution: resolution)

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState, resolution.reviewState)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact, resolution.inferredArtifact)

        store.updateReviewResolution(
            paneID: paneID,
            resolution: WorkspaceReviewResolution(reviewState: nil, inferredArtifact: nil)
        )

        XCTAssertEqual(notificationCount, 2)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact)
    }

    func test_update_review_resolution_preserves_existing_state_on_transient_empty_refresh() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let existingResolution = WorkspaceReviewResolution(
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
            ),
            inferredArtifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )
        store.updateReviewResolution(paneID: paneID, resolution: existingResolution)

        var notificationCount = 0
        store.onChange = { _ in
            notificationCount += 1
        }

        store.updateReviewResolution(
            paneID: paneID,
            resolution: WorkspaceReviewResolution(
                reviewState: nil,
                inferredArtifact: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        )

        XCTAssertEqual(notificationCount, 0)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState, existingResolution.reviewState)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact, existingResolution.inferredArtifact)
    }

    func test_clearing_agent_status_keeps_review_state_for_that_pane() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
                paneID: paneID,
                state: nil,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNotNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
    }

    func test_explicit_needs_input_beats_prompt_idle_shell_state() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionState, .awaitingHuman)
    }

    func test_updating_metadata_clears_branch_derived_review_state_when_branch_changes() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
            )
        )
        store.updateInferredArtifact(
            paneID: paneID,
            artifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
                paneID: paneID,
                state: .running,
                toolName: "Claude Code",
                text: nil,
                artifactKind: .pullRequest,
                artifactLabel: "PR #128",
                artifactURL: URL(string: "https://example.com/pr/128")
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.artifactLink)
    }

    func test_equal_priority_needs_input_update_does_not_downgrade_specific_waiting_copy() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Claude needs your approval")
    }

    func test_equal_priority_needs_input_update_can_upgrade_generic_waiting_copy() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text, "Claude needs your approval")
    }

    func test_clear_stale_agent_sessions_removes_dead_running_process_status() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.1"]
        try process.run()

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.agentStatus)
    }

    func test_pane_context_signal_stores_local_context_and_formats_home_relative_display() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
            store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.shellContext,
            PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: nil,
                host: nil
            )
        )
        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "~/src/zentty")
    }

    func test_pane_context_local_home_with_user_and_host_shows_identity() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter@m1-pro-peter:~")
    }

    func test_pane_context_local_home_with_only_user_shows_user_identity() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter:~")
    }

    func test_pane_context_local_home_without_identity_falls_back_to_tilde() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "~")
    }

    func test_pane_context_local_subdirectory_with_identity_shows_only_path() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "~/src/zentty")
    }

    func test_pane_context_signal_formats_remote_identity_and_path() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
            store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text,
            "peter@gilfoyle ~/project"
        )
    }

    func test_pane_context_signal_uses_remote_identity_without_path_fallback() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertEqual(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID]?.text, "peter@gilfoyle")
    }

    func test_pane_context_signal_clear_removes_stored_context() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.shellContext)
        XCTAssertNil(store.activeWorkspace?.paneBorderContextDisplayByPaneID[paneID])
    }

    func test_pane_context_is_removed_when_pane_closes() throws {
        let store = WorkspaceStore()
        store.send(.splitAfterFocusedPane)
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.shellContext)
    }

    func test_updating_metadata_clears_branch_derived_review_state_when_title_implies_new_working_directory() throws {
        let store = WorkspaceStore()
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@host:~/Development/project-a",
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorkspaceReviewState(
                branch: "feature/project-a",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [WorkspaceReviewChip(text: "Draft", style: .info)]
            )
        )
        store.updateInferredArtifact(
            paneID: paneID,
            artifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@host:~/Development/project-b",
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )

        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.reviewState)
        XCTAssertNil(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.inferredArtifact)
    }
}
