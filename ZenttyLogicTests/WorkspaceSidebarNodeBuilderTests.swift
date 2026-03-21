import XCTest
@testable import Zentty

final class WorkspaceSidebarNodeBuilderTests: XCTestCase {
    func test_node_builder_marks_pane_as_working_from_terminal_progress_even_without_running_attention() {
        let shellPaneID = PaneID("workspace-main-shell")
        let agentPaneID = PaneID("workspace-main-agent")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: agentPaneID, title: "agent"),
                ],
                focusedPaneID: shellPaneID
            ),
            metadataByPaneID: [
                agentPaneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "feature/sidebar"
                )
            ],
            terminalProgressByPaneID: [
                agentPaneID: TerminalProgressReport(state: .indeterminate, progress: nil)
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)
        let pane = try! XCTUnwrap(node.panes.first)

        XCTAssertTrue(pane.isWorking)
        XCTAssertNil(pane.attentionState)
    }

    func test_node_builder_falls_back_to_running_agent_status_when_terminal_progress_is_absent() {
        let shellPaneID = PaneID("workspace-main-shell")
        let agentPaneID = PaneID("workspace-main-agent")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: agentPaneID, title: "agent"),
                ],
                focusedPaneID: shellPaneID
            ),
            metadataByPaneID: [
                agentPaneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "feature/sidebar"
                )
            ],
            agentStatusByPaneID: [
                agentPaneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .running,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let node = WorkspaceSidebarNodeBuilder.node(for: workspace, isActive: true)
        let pane = try! XCTUnwrap(node.panes.first)

        XCTAssertTrue(pane.isWorking)
        XCTAssertEqual(pane.attentionState, .running)
    }
}
