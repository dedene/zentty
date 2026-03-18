import XCTest
@testable import Zentty

final class WorkspaceSidebarSummaryTests: XCTestCase {
    func test_builder_uses_compact_cwd_for_primary_text_before_process_name() {
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
                    title: "zsh",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feature/sidebar",
                    processName: "zsh",
                    gitBranch: "fix-pane-border-text-visibility"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertEqual(summary.primaryText, "feature/sidebar")
        XCTAssertEqual(summary.detailLines.map(\.text), ["fix-pane-border-text-visibility • sidebar"])
        XCTAssertNil(summary.topLabel)
        XCTAssertNil(summary.leadingAccessory)
        XCTAssertNil(summary.overflowText)
        XCTAssertTrue(summary.isActive)
    }

    func test_builder_maps_home_directory_to_tilde_with_home_accessory() {
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
                    title: "zsh",
                    currentWorkingDirectory: NSHomeDirectory(),
                    processName: "zsh",
                    gitBranch: nil
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "~")
        XCTAssertEqual(summary.leadingAccessory, .home)
        XCTAssertEqual(summary.detailLines.map(\.text), ["zsh • ~"])
    }

    func test_builder_normalizes_generated_pane_titles_when_metadata_is_missing() {
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

        XCTAssertEqual(summary.primaryText, "Split")
        XCTAssertEqual(summary.detailLines, [])
        XCTAssertNil(summary.leadingAccessory)
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
                    gitBranch: "feature/dismissals"
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
        XCTAssertEqual(summary.detailLines.map(\.text), ["feature/dismissals • project"])
        XCTAssertEqual(summary.leadingAccessory, .agent(.claudeCode))
        XCTAssertEqual(summary.attentionState, .needsInput)
    }

    func test_builder_keeps_meaningful_custom_workspace_title_as_quiet_top_label() {
        let paneID = PaneID("workspace-docs-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-docs"),
            title: "Docs",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/tmp/marketing-site",
                    processName: "zsh",
                    gitBranch: "refresh-homepage-copy"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.topLabel, "Docs")
        XCTAssertEqual(summary.primaryText, "marketing-site")
        XCTAssertEqual(summary.detailLines.map(\.text), ["refresh-homepage-copy • marketing-site"])
    }

    func test_builder_omits_custom_workspace_title_when_it_repeats_primary_identity() {
        let paneID = PaneID("workspace-sidebar-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-sidebar"),
            title: "sidebar",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feature/sidebar",
                    processName: "zsh",
                    gitBranch: "fix-pane-border-text-visibility"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertNil(summary.topLabel)
        XCTAssertEqual(summary.primaryText, "feature/sidebar")
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

    func test_builder_uses_pane_specific_detail_lines_for_multi_pane_workspaces() {
        let shellPaneID = PaneID("workspace-main-shell")
        let gitPaneID = PaneID("workspace-main-pane-1")
        let notesPaneID = PaneID("workspace-main-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: gitPaneID, title: "pane 1"),
                    PaneState(id: notesPaneID, title: "notes"),
                ],
                focusedPaneID: shellPaneID
            ),
            metadataByPaneID: [
                shellPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feature/sidebar",
                    processName: "zsh",
                    gitBranch: "fix-pane-border-text-visibility"
                ),
                gitPaneID: TerminalMetadata(
                    title: "git",
                    currentWorkingDirectory: "/tmp/git",
                    processName: "git",
                    gitBranch: "main"
                ),
                notesPaneID: TerminalMetadata(
                    title: "notes",
                    currentWorkingDirectory: "/tmp/copy",
                    processName: "notes",
                    gitBranch: nil
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar")
        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "fix-pane-border-text-visibility • sidebar",
                "main • git",
                "notes • copy",
            ]
        )
        XCTAssertNil(summary.overflowText)
    }

    func test_summaries_expand_colliding_primary_paths_to_longer_labels() {
        let apiWorkspaceID = WorkspaceID("workspace-api")
        let srcApiWorkspaceID = WorkspaceID("workspace-src-api")
        let workspaces = [
            WorkspaceState(
                id: apiWorkspaceID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("workspace-api-shell"), title: "shell")],
                    focusedPaneID: PaneID("workspace-api-shell")
                ),
                metadataByPaneID: [
                    PaneID("workspace-api-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/tmp/api",
                        processName: "zsh",
                        gitBranch: "main"
                    )
                ]
            ),
            WorkspaceState(
                id: srcApiWorkspaceID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("workspace-src-api-shell"), title: "shell")],
                    focusedPaneID: PaneID("workspace-src-api-shell")
                ),
                metadataByPaneID: [
                    PaneID("workspace-src-api-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: NSHomeDirectory() + "/src/api",
                        processName: "zsh",
                        gitBranch: "feature/sidebar"
                    )
                ]
            ),
        ]

        let summaries = WorkspaceSidebarSummaryBuilder.summaries(
            for: workspaces,
            activeWorkspaceID: apiWorkspaceID
        )

        XCTAssertEqual(summaries.map(\.primaryText), ["tmp/api", "src/api"])
    }
}
