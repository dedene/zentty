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

        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility · …/sidebar")
        XCTAssertEqual(summary.focusedPaneLineIndex, 0)
        XCTAssertEqual(summary.detailLines.map(\.text), [])
        XCTAssertNil(summary.topLabel)
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

        XCTAssertEqual(summary.primaryText, "main · …/zentty")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_prefers_local_shell_context_when_metadata_cwd_is_stale_non_descendant() {
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
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                    processName: "zsh",
                    gitBranch: "main"
                )
            ],
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/Development/Zenjoy/Internal/k8s-zenjoy",
                    home: NSHomeDirectory(),
                    user: "peter",
                    host: "m1-pro-peter"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "main · …/k8s-zenjoy")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
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

        XCTAssertEqual(summary.primaryText, "Shell")
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
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.detailLines.map(\.text), ["feature/dismissals • …/project"])
        XCTAssertNil(summary.attentionState)
        XCTAssertEqual(
            summary.paneRows.first(where: { $0.paneID == agentPaneID })?.statusText,
            "╰ Needs input"
        )
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
        XCTAssertEqual(summary.primaryText, "refresh-homepage-copy · …/marketing-site")
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
        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility · …/sidebar")
    }

    func test_builder_keeps_explicit_session_artifact_out_of_sidebar_card() {
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
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.paneRows.first?.statusText, "╰ Needs input")
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
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/git", "notes • /tmp/copy"])
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

        XCTAssertEqual(summary.detailLines.map(\.text), ["fix-pane-border-text-visibility • …/sidebar", "main • …/git"])
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

        XCTAssertEqual(summary.detailLines.map(\.text), ["fix-pane-border-text-visibility • …/sidebar", "main • …/git", "notes • /tmp/copy"])
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

        XCTAssertEqual(summary.primaryText, "…/api")
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

        XCTAssertEqual(summaries.map(\.primaryText), ["main · …/api", "feature/sidebar · …/api"])
    }

    func test_builder_marks_workspace_as_working_when_background_terminal_progress_exists() {
        let shellPaneID = PaneID("workspace-main-shell")
        let backgroundPaneID = PaneID("workspace-main-background")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: backgroundPaneID, title: "build"),
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
                backgroundPaneID: TerminalMetadata(
                    title: "npm test",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "node",
                    gitBranch: nil
                ),
            ],
            terminalProgressByPaneID: [
                backgroundPaneID: TerminalProgressReport(state: .indeterminate, progress: nil)
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertTrue(summary.isWorking)
        XCTAssertNil(summary.statusText)
        XCTAssertNil(summary.attentionState)
    }

    func test_builder_keeps_terminal_derived_primary_text_for_recognized_agent_before_meaningful_work() {
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

        XCTAssertEqual(summary.primaryText, "feature/sidebar · …/project")
        XCTAssertNil(summary.statusText)
        XCTAssertFalse(summary.isWorking)
    }

    func test_builder_does_not_mark_recognized_agent_workspace_as_running_from_terminal_progress_alone() {
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
                    gitBranch: nil
                )
            ],
            terminalProgressByPaneID: [
                paneID: TerminalProgressReport(state: .indeterminate, progress: nil)
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/project")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.statusText)
        XCTAssertNil(summary.attentionState)
    }

    func test_builder_omits_single_pane_detail_when_primary_already_contains_same_directory() {
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
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: nil
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/nimbu")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_summaries_drop_startup_progress_for_recognized_agents_after_disambiguation_pass() {
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

        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.statusText)
    }

    func test_builder_uses_review_state_without_extra_sidebar_artifact_projection() {
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
                    gitBranch: "main"
                )
            ],
            reviewStateByPaneID: [
                paneID: WorkspaceReviewState(
                    branch: "main",
                    pullRequest: WorkspacePullRequestSummary(
                        number: 1413,
                        url: URL(string: "https://example.com/pr/1413"),
                        state: .open
                    ),
                    reviewChips: [WorkspaceReviewChip(text: "1 failing", style: .danger)]
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.primaryText, "main · …/project")
        XCTAssertEqual(summary.detailLines.map { $0.text }, [])
    }

    func test_builder_uses_inline_process_branch_and_cwd_for_running_single_pane_agent_row() {
        let paneID = PaneID("workspace-main-agent-running")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main-running"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Test session setup",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .running,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(summary.paneRows.count, 1)
        XCTAssertEqual(paneRow.primaryText, "Test session setup · main · …/nimbu")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "╰ Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_uses_stable_branch_and_cwd_for_completed_single_pane_agent_row() {
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
                    title: "General coding assistance session",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "codex",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .codex,
                    state: .completed,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(summary.paneRows.count, 1)
        XCTAssertEqual(paneRow.paneID, paneID)
        XCTAssertEqual(paneRow.primaryText, "General coding assistance session · main · …/nimbu")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "╰ Completed")
        XCTAssertEqual(paneRow.attentionState, .completed)
        XCTAssertFalse(paneRow.isWorking)
    }

    func test_builder_uses_stable_branch_and_cwd_for_starting_single_pane_recognized_agent() {
        let paneID = PaneID("workspace-main-agent-starting")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main-starting"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Test session setup",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .starting,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Test session setup · main · …/nimbu")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertNil(paneRow.statusText)
        XCTAssertNil(paneRow.attentionState)
        XCTAssertFalse(paneRow.isWorking)
    }

    func test_builder_does_not_surface_path_like_title_for_completed_single_pane_agent_row() {
        let paneID = PaneID("workspace-main-agent-path")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main-path"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "/Users/peter",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .completed,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "main · …/nimbu")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "╰ Completed")
    }

    func test_builder_attaches_terminal_progress_status_to_own_non_agent_pane_row() {
        let shellPaneID = PaneID("workspace-main-shell")
        let buildPaneID = PaneID("workspace-main-build")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: buildPaneID, title: "build"),
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
                buildPaneID: TerminalMetadata(
                    title: "npm test",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "node",
                    gitBranch: nil
                ),
            ],
            terminalProgressByPaneID: [
                buildPaneID: TerminalProgressReport(state: .indeterminate, progress: nil)
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first { $0.paneID == buildPaneID })

        XCTAssertEqual(paneRow.primaryText, "npm test · …/project")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "╰ Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_folds_cwd_into_primary_for_multi_pane_agent_rows_with_meaningful_titles() {
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
                    title: "Test session setup",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: "feature/sidebar"
                ),
            ],
            agentStatusByPaneID: [
                agentPaneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .completed,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first { $0.paneID == agentPaneID })

        XCTAssertEqual(paneRow.primaryText, "Test session setup · …/nimbu")
        XCTAssertEqual(paneRow.trailingText, "feature/sidebar")
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "╰ Completed")
    }
}
