import XCTest
@testable import Zentty

final class PaneStripStoreTests: XCTestCase {
    func test_store_starts_with_single_main_workspace_and_first_active() {
        let store = WorkspaceStore()

        XCTAssertEqual(store.workspaces.map(\.title), ["MAIN"])
        XCTAssertEqual(store.activeWorkspace?.title, "MAIN")
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell"])
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
    }

    func test_split_after_inserts_adjacent_pane_and_inherits_focused_working_directory() throws {
        let store = WorkspaceStore()
        let shellPaneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: shellPaneID,
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project")
        )

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.activeWorkspace?.paneStripState.focusedPane?.title, "pane 1")
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.workingDirectory,
            "/tmp/project"
        )
        XCTAssertEqual(
            store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest.inheritFromPaneID,
            shellPaneID
        )
    }

    func test_split_after_uses_ratio_based_new_pane_width_for_laptop_context() throws {
        let layoutContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1200,
            leadingVisibleInset: 290
        )
        let store = WorkspaceStore(layoutContext: layoutContext)

        store.send(.splitAfterFocusedPane)

        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.last?.width ?? 0, 800, accuracy: 0.001)
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
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.first?.width ?? 0, 1194, accuracy: 0.001)
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

        let widths = store.activeWorkspace?.paneStripState.panes.map(\.width) ?? []
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0], 1117.5, accuracy: 0.001)
        XCTAssertEqual(widths[1], 1000, accuracy: 0.001)
    }

    func test_updating_layout_context_reprojects_multi_pane_layout_sizing_even_when_widths_do_not_change() {
        let collapsedSizing = PaneLayoutSizing(
            horizontalInset: 0,
            verticalInset: PaneLayoutSizing.balanced.verticalInset,
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
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.first?.width ?? 0, 962, accuracy: 0.001)
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
        XCTAssertEqual(store.activeWorkspace?.paneStripState.panes.first?.width ?? 0, 894, accuracy: 0.001)
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
        XCTAssertEqual(store.activeWorkspace?.metadataByPaneID[paneID]?.currentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(store.activeWorkspace?.metadataByPaneID[paneID]?.gitBranch, "main")
    }

    func test_default_workspace_shell_session_contains_agent_identity_environment() throws {
        let store = WorkspaceStore()

        let request = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPane?.sessionRequest)

        XCTAssertEqual(request.environmentVariables["ZENTTY_WORKSPACE_ID"], "workspace-main")
        XCTAssertEqual(request.environmentVariables["ZENTTY_PANE_ID"], "workspace-main-shell")
        XCTAssertFalse((request.environmentVariables["ZENTTY_AGENT_BIN"] ?? "").isEmpty)
        XCTAssertEqual(request.environmentVariables["ZENTTY_CLAUDE_HOOK_COMMAND"], "\(request.environmentVariables["ZENTTY_AGENT_BIN"]!) claude-hook")
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

        XCTAssertNil(store.activeWorkspace?.agentStatusByPaneID[paneID])
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

        XCTAssertEqual(store.activeWorkspace?.agentStatusByPaneID[paneID]?.state, .unresolvedStop)
        XCTAssertEqual(store.activeWorkspace?.agentStatusByPaneID[paneID]?.tool, .claudeCode)
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

        XCTAssertNil(store.activeWorkspace?.agentStatusByPaneID[paneID])
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

        XCTAssertEqual(store.activeWorkspace?.agentStatusByPaneID[paneID]?.state, .running)
    }
}
