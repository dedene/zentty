import XCTest
@testable import Zentty

final class WorkspaceSidebarNodeBuilderTests: XCTestCase {
    func test_node_single_pane_has_empty_panes_array() {
        let paneID = PaneID("ws-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertTrue(node.panes.isEmpty)
        XCTAssertEqual(node.header.paneCount, 1)
    }

    func test_node_header_primary_from_first_pane_cwd() {
        let paneID = PaneID("ws-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    currentWorkingDirectory: "/tmp/project"
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.primaryText, "project")
    }

    func test_node_header_primary_falls_back_to_pane_context_path_when_metadata_is_empty() {
        let paneID = PaneID("ws-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: "peter",
                    host: "m1-pro-peter"
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.primaryText, "zentty")
    }

    func test_node_header_primary_prefers_metadata_cwd_over_pane_context_path() {
        let paneID = PaneID("ws-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(currentWorkingDirectory: "/tmp/metadata-project")
            ],
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/context-project",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.primaryText, "metadata-project")
    }

    func test_node_pane_labels_fall_back_to_pane_context_path_when_metadata_is_empty() {
        let pane1ID = PaneID("ws-pane-1")
        let pane2ID = PaneID("ws-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: pane1ID, title: "shell"),
                    PaneState(id: pane2ID, title: "pane 1"),
                ],
                focusedPaneID: pane1ID
            ),
            paneContextByPaneID: [
                pane1ID: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/zentty",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                ),
                pane2ID: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/src/docs",
                    home: "/Users/peter",
                    user: nil,
                    host: nil
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.primaryText, "zentty")
        XCTAssertEqual(node.panes.map(\.primaryText), ["zentty", "docs"])
    }

    func test_node_attention_bubbles_up_to_header() {
        let shellPaneID = PaneID("ws-shell")
        let agentPaneID = PaneID("ws-agent")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: agentPaneID, title: "agent"),
                ],
                focusedPaneID: shellPaneID
            ),
            agentStatusByPaneID: [
                agentPaneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .needsInput,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.attentionState, .needsInput)
        XCTAssertEqual(node.header.statusText, "Needs input")
    }

    func test_node_shared_branch_on_header_nil_on_panes() {
        let pane1ID = PaneID("ws-pane-1")
        let pane2ID = PaneID("ws-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: pane1ID, title: "shell"),
                    PaneState(id: pane2ID, title: "agent"),
                ],
                focusedPaneID: pane1ID
            ),
            metadataByPaneID: [
                pane1ID: TerminalMetadata(gitBranch: "main"),
                pane2ID: TerminalMetadata(gitBranch: "main"),
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertTrue(node.header.gitContext.contains("main"))
        for pane in node.panes {
            XCTAssertEqual(pane.gitContext, "")
        }
    }

    func test_node_divergent_branches_per_pane() {
        let pane1ID = PaneID("ws-pane-1")
        let pane2ID = PaneID("ws-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: pane1ID, title: "shell"),
                    PaneState(id: pane2ID, title: "agent"),
                ],
                focusedPaneID: pane1ID
            ),
            metadataByPaneID: [
                pane1ID: TerminalMetadata(gitBranch: "main"),
                pane2ID: TerminalMetadata(gitBranch: "feature/sidebar"),
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.gitContext, "")
        XCTAssertEqual(node.panes.count, 2)
        XCTAssertEqual(node.panes[0].gitContext, "main")
        XCTAssertEqual(node.panes[1].gitContext, "feature/sidebar")
    }

    func test_node_pr_number_appended_to_git_context() {
        let paneID = PaneID("ws-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(gitBranch: "feature/pr-test")
            ],
            inferredArtifactByPaneID: [
                paneID: WorkspaceArtifactLink(
                    kind: .pullRequest,
                    label: "PR #42",
                    url: URL(string: "https://example.com/pr/42")!,
                    isExplicit: false
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertTrue(node.header.gitContext.contains("feature/pr-test"))
        XCTAssertTrue(node.header.gitContext.contains("#42"))
    }

    func test_node_pane_focused_flag_correct() {
        let pane1ID = PaneID("ws-pane-1")
        let pane2ID = PaneID("ws-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: pane1ID, title: "shell"),
                    PaneState(id: pane2ID, title: "agent"),
                ],
                focusedPaneID: pane2ID
            )
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.panes.count, 2)
        XCTAssertFalse(node.panes[0].isFocused)
        XCTAssertTrue(node.panes[1].isFocused)
    }

    func test_node_pane_count_reflects_actual() {
        let pane1ID = PaneID("ws-pane-1")
        let pane2ID = PaneID("ws-pane-2")
        let pane3ID = PaneID("ws-pane-3")
        let workspace = WorkspaceState(
            id: WorkspaceID("ws"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: pane1ID, title: "shell"),
                    PaneState(id: pane2ID, title: "agent"),
                    PaneState(id: pane3ID, title: "editor"),
                ],
                focusedPaneID: pane1ID
            )
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)

        XCTAssertEqual(node.header.paneCount, 3)
        XCTAssertEqual(node.panes.count, 3)
    }
}
