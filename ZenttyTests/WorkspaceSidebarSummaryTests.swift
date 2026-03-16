import XCTest
@testable import Zentty

final class WorkspaceSidebarSummaryTests: XCTestCase {
    func test_builder_prefers_terminal_title_and_compacts_context_line_for_normal_shells() {
        let paneID = PaneID("workspace-main-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "main"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertEqual(summary.primaryText, "Claude Code")
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.contextText, "project • main")
        XCTAssertNil(summary.artifactLink)
        XCTAssertEqual(summary.badgeText, "M")
        XCTAssertFalse(summary.showsGeneratedTitle)
        XCTAssertTrue(summary.isActive)
    }

    func test_builder_falls_back_to_focused_pane_title_when_metadata_missing() {
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: PaneID("workspace-main-shell"), title: "shell"),
                    PaneState(id: PaneID("workspace-main-pane-1"), title: "pane 1"),
                ],
                focusedPaneID: PaneID("workspace-main-pane-1")
            )
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "pane 1")
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.contextText, "")
        XCTAssertFalse(summary.showsGeneratedTitle)
        XCTAssertEqual(summary.badgeText, "M")
        XCTAssertFalse(summary.isActive)
    }

    func test_builder_prioritizes_attention_from_non_focused_agent_pane() {
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
                shellPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "zsh",
                    gitBranch: "main"
                ),
                agentPaneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "main"
                ),
            ],
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

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertEqual(summary.primaryText, "Claude Code")
        XCTAssertEqual(summary.statusText, "Needs input")
        XCTAssertEqual(summary.contextText, "project • main")
        XCTAssertEqual(summary.attentionState, .needsInput)
    }

    func test_builder_prefers_explicit_artifact_over_inferred_pull_request() {
        let paneID = PaneID("workspace-main-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .needsInput,
                    text: nil,
                    artifactLink: WorkspaceArtifactLink(
                        kind: .session,
                        label: "Session",
                        url: URL(string: "https://example.com/session")!,
                        isExplicit: true
                    ),
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
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

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertEqual(summary.artifactLink?.label, "Session")
        XCTAssertEqual(summary.statusText, "Needs input")
    }
}
