import XCTest
@testable import Zentty

final class WorkspaceSidebarSummaryTests: XCTestCase {
    func test_builder_uses_branch_prefixed_cwd_for_focused_primary_text_when_identity_is_path_derived() {
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

        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility • …/sidebar")
        XCTAssertEqual(summary.focusedPaneLineIndex, 0)
        XCTAssertEqual(summary.detailLines.map(\.text), [])
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
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_prefers_more_specific_local_pane_context_over_stale_home_metadata() {
        let paneID = PaneID("workspace-main-shell")
        let projectPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Development/Personal/zentty"
        )
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
                    gitBranch: "main"
                )
            ],
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: projectPath,
                    home: NSHomeDirectory(),
                    user: "peter",
                    host: "m1-pro-peter"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "main • …/zentty")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
        XCTAssertNil(summary.leadingAccessory)
    }

    func test_builder_keeps_focused_slot_when_focused_pane_has_no_metadata() {
        let focusedPaneID = PaneID("workspace-main-pane-1")
        let notesPaneID = PaneID("workspace-main-notes")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: focusedPaneID, title: "pane 1"),
                    PaneState(id: notesPaneID, title: "notes"),
                ],
                focusedPaneID: focusedPaneID
            ),
            metadataByPaneID: [
                notesPaneID: TerminalMetadata(
                    title: "notes",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "notes",
                    gitBranch: nil
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "Shell")
        XCTAssertEqual(summary.focusedPaneLineIndex, 0)
        XCTAssertEqual(summary.detailLines.map(\.text), ["notes • /tmp/project"])
        XCTAssertNil(summary.leadingAccessory)
    }

    func test_builder_uses_process_name_when_no_cwd_exists_anywhere() {
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
                    title: nil,
                    currentWorkingDirectory: nil,
                    processName: "zsh",
                    gitBranch: nil
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "zsh")
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_uses_focused_pane_for_fallback_identity_when_cwd_is_missing() {
        let firstPaneID = PaneID("workspace-main-pane-1")
        let secondPaneID = PaneID("workspace-main-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: firstPaneID, title: "rails"),
                    PaneState(id: secondPaneID, title: "git"),
                ],
                focusedPaneID: secondPaneID
            ),
            metadataByPaneID: [
                firstPaneID: TerminalMetadata(
                    title: "rails",
                    currentWorkingDirectory: nil,
                    processName: nil,
                    gitBranch: nil
                ),
                secondPaneID: TerminalMetadata(
                    title: "git",
                    currentWorkingDirectory: nil,
                    processName: nil,
                    gitBranch: nil
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "git")
    }

    func test_builder_prefers_focused_meaningful_terminal_identity_over_earlier_pane_cwd() {
        let firstPaneID = PaneID("workspace-main-pane-1")
        let focusedPaneID = PaneID("workspace-main-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: firstPaneID, title: "server"),
                    PaneState(id: focusedPaneID, title: "git"),
                ],
                focusedPaneID: focusedPaneID
            ),
            metadataByPaneID: [
                firstPaneID: TerminalMetadata(
                    title: "server",
                    currentWorkingDirectory: "/tmp/app",
                    processName: "zsh",
                    gitBranch: "main"
                ),
                focusedPaneID: TerminalMetadata(
                    title: "git",
                    currentWorkingDirectory: "/tmp/docs",
                    processName: "zsh",
                    gitBranch: "feature/sidebar-feedback"
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar-feedback • …/docs")
        XCTAssertEqual(summary.focusedPaneLineIndex, 1)
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/app"])
    }

    func test_builder_tracks_middle_focused_pane_without_reordering_visible_pane_lines() {
        let firstPaneID = PaneID("workspace-main-pane-1")
        let focusedPaneID = PaneID("workspace-main-pane-2")
        let thirdPaneID = PaneID("workspace-main-pane-3")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: firstPaneID, title: "server"),
                    PaneState(id: focusedPaneID, title: "git"),
                    PaneState(id: thirdPaneID, title: "notes"),
                ],
                focusedPaneID: focusedPaneID
            ),
            metadataByPaneID: [
                firstPaneID: TerminalMetadata(
                    title: "server",
                    currentWorkingDirectory: "/tmp/app",
                    processName: "zsh",
                    gitBranch: "main"
                ),
                focusedPaneID: TerminalMetadata(
                    title: "git",
                    currentWorkingDirectory: "/tmp/docs",
                    processName: "zsh",
                    gitBranch: "feature/sidebar-feedback"
                ),
                thirdPaneID: TerminalMetadata(
                    title: "notes",
                    currentWorkingDirectory: "/tmp/copy",
                    processName: "notes",
                    gitBranch: nil
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar-feedback • …/docs")
        XCTAssertEqual(summary.focusedPaneLineIndex, 1)
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/app", "notes • /tmp/copy"])
    }

    func test_builder_falls_back_to_generic_shell_when_workspace_is_anonymous() {
        let paneID = PaneID("workspace-main-pane-1")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "pane 1")],
                focusedPaneID: paneID
            )
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "Shell")
        XCTAssertEqual(summary.detailLines, [])
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

        XCTAssertEqual(summary.primaryText, "main • …/project")
        XCTAssertEqual(summary.statusText, "Claude Code is waiting for your input")
        XCTAssertEqual(summary.stateBadgeText, "Needs input")
        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "feature/dismissals • …/project",
            ]
        )
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
        XCTAssertEqual(summary.primaryText, "refresh-homepage-copy • …/marketing-site")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_omits_detail_line_for_single_pane_rows_without_branch() {
        let paneID = PaneID("workspace-sidebar-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-sidebar"),
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
                    gitBranch: nil
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/sidebar")
        XCTAssertEqual(summary.detailLines, [])
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
        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility • …/sidebar")
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
        XCTAssertEqual(summary.statusText, "Claude Code is waiting for your input")
        XCTAssertEqual(summary.stateBadgeText, "Needs input")
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

        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility • …/sidebar")
        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "main • …/git",
                "notes • /tmp/copy",
            ]
        )
        XCTAssertNil(summary.overflowText)
    }

    func test_builder_excludes_focused_pane_from_detail_lines_while_preserving_other_pane_order() {
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
                focusedPaneID: notesPaneID
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

        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "fix-pane-border-text-visibility • …/sidebar",
                "main • …/git",
            ]
        )
        XCTAssertEqual(summary.focusedPaneLineIndex, 2)
    }

    func test_builder_shows_all_non_focused_pane_detail_lines_without_overflow_for_four_pane_workspaces() {
        let firstPaneID = PaneID("workspace-main-shell")
        let secondPaneID = PaneID("workspace-main-pane-1")
        let thirdPaneID = PaneID("workspace-main-pane-2")
        let fourthPaneID = PaneID("workspace-main-pane-3")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: firstPaneID, title: "shell"),
                    PaneState(id: secondPaneID, title: "pane 1"),
                    PaneState(id: thirdPaneID, title: "notes"),
                    PaneState(id: fourthPaneID, title: "tests"),
                ],
                focusedPaneID: fourthPaneID
            ),
            metadataByPaneID: [
                firstPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feature/sidebar",
                    processName: "zsh",
                    gitBranch: "fix-pane-border-text-visibility"
                ),
                secondPaneID: TerminalMetadata(
                    title: "git",
                    currentWorkingDirectory: "/tmp/git",
                    processName: "git",
                    gitBranch: "main"
                ),
                thirdPaneID: TerminalMetadata(
                    title: "notes",
                    currentWorkingDirectory: "/tmp/copy",
                    processName: "notes",
                    gitBranch: nil
                ),
                fourthPaneID: TerminalMetadata(
                    title: "tests",
                    currentWorkingDirectory: "/tmp/specs",
                    processName: "tests",
                    gitBranch: nil
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "fix-pane-border-text-visibility • …/sidebar",
                "main • …/git",
                "notes • /tmp/copy",
            ]
        )
        XCTAssertNil(summary.overflowText)
    }

    func test_builder_expands_branchless_pane_paths_instead_of_dropping_lines_that_repeat_primary() {
        let primaryPaneID = PaneID("workspace-main-pane-1")
        let secondaryPaneID = PaneID("workspace-main-pane-2")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: primaryPaneID, title: "pane 1"),
                    PaneState(id: secondaryPaneID, title: "pane 2"),
                ],
                focusedPaneID: primaryPaneID
            ),
            metadataByPaneID: [
                primaryPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/tmp/api",
                    processName: "zsh",
                    gitBranch: nil
                ),
                secondaryPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: NSHomeDirectory() + "/src/api",
                    processName: "zsh",
                    gitBranch: nil
                ),
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "/tmp/api")
        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "\(NSHomeDirectory())/src/api",
            ]
        )
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

        XCTAssertEqual(summaries.map(\.primaryText), ["main • …/api", "feature/sidebar • …/api"])
    }

    func test_builder_marks_workspace_as_working_when_background_terminal_progress_exists() {
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
                    gitBranch: nil
                ),
            ],
            terminalProgressByPaneID: [
                agentPaneID: TerminalProgressReport(state: .indeterminate, progress: nil)
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertTrue(summary.isWorking)
        XCTAssertEqual(summary.statusText, "Claude Code is working")
        XCTAssertEqual(summary.stateBadgeText, "Running")
        XCTAssertEqual(summary.attentionState, .running)
        XCTAssertEqual(summary.leadingAccessory, .agent(.claudeCode))
    }

    func test_builder_marks_recognized_agent_workspace_as_idle_with_explicit_state_copy() {
        let paneID = PaneID("workspace-main-agent")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "feature/sidebar"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "Claude Code")
        XCTAssertEqual(summary.statusText, "Claude Code is idle")
        XCTAssertEqual(summary.stateBadgeText, "Idle")
        XCTAssertEqual(summary.leadingAccessory, .agent(.claudeCode))
        XCTAssertFalse(summary.isWorking)
    }

    func test_summaries_preserve_working_state_after_disambiguation_pass() {
        let workspaceID = WorkspaceID("workspace-main")
        let paneID = PaneID("workspace-main-agent")
        let workspaces = [
            WorkspaceState(
                id: workspaceID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "agent")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "Claude Code",
                        currentWorkingDirectory: "/tmp/project",
                        processName: "claude",
                        gitBranch: "feature/sidebar"
                    )
                ],
                terminalProgressByPaneID: [
                    paneID: TerminalProgressReport(state: .indeterminate, progress: nil)
                ]
            )
        ]

        let summary = try! XCTUnwrap(
            WorkspaceSidebarSummaryBuilder.summaries(
                for: workspaces,
                activeWorkspaceID: workspaceID
            ).first
        )

        XCTAssertTrue(summary.isWorking)
        XCTAssertEqual(summary.statusText, "Claude Code is working")
        XCTAssertEqual(summary.stateBadgeText, "Running")
    }
}
