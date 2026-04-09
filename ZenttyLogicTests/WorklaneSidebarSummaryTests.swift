import XCTest
@testable import Zentty

final class WorklaneSidebarSummaryTests: XCTestCase {
    func test_builder_uses_branch_prefixed_cwd_for_focused_primary_text_when_identity_is_path_derived() {
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)

        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility · …/sidebar")
        XCTAssertEqual(summary.focusedPaneLineIndex, 0)
        XCTAssertEqual(summary.detailLines.map(\.text), [])
        XCTAssertNil(summary.topLabel)
        XCTAssertNil(summary.overflowText)
        XCTAssertTrue(summary.isActive)
    }

    func test_builder_maps_home_directory_to_tilde_with_home_accessory() {
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "~")
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_ignores_agent_working_directory_and_shows_terminal_cwd() {
        let paneID = PaneID("worklane-main-shell")
        var auxiliaryState = PaneAuxiliaryState(
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "codex",
                gitBranch: nil
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10),
                workingDirectory: "/tmp/from-agent"
            )
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "~")
    }

    func test_builder_prefers_more_specific_local_pane_context_over_stale_home_metadata() {
        let paneID = PaneID("worklane-main-shell")
        let projectPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Development/Personal/zentty"
        )
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "main · …/zentty")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_prefers_local_shell_context_when_metadata_cwd_is_stale_non_descendant() {
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "main · …/k8s-zenjoy")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_ignores_agent_working_directory_until_terminal_reports_a_new_cwd() {
        let paneID = PaneID("worklane-main-shell")
        var worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
            ],
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: NSHomeDirectory(),
                    home: NSHomeDirectory(),
                    user: "peter",
                    host: "m1-pro-peter"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .codex,
                    state: .idle,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(),
                    workingDirectory: "/tmp/project"
                )
            ]
        )
        worklane.auxiliaryStateByPaneID[paneID]?.shellActivityState = .commandRunning

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "~")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_keeps_focused_slot_when_focused_pane_has_no_metadata() {
        let focusedPaneID = PaneID("worklane-main-pane-1")
        let notesPaneID = PaneID("worklane-main-notes")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "Shell")
        XCTAssertEqual(summary.focusedPaneLineIndex, 0)
        XCTAssertEqual(summary.detailLines.map(\.text), ["notes • /tmp/project"])
    }

    func test_builder_uses_process_name_when_no_cwd_exists_anywhere() {
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "Shell")
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_uses_focused_pane_for_fallback_identity_when_cwd_is_missing() {
        let firstPaneID = PaneID("worklane-main-pane-1")
        let secondPaneID = PaneID("worklane-main-pane-2")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "git")
    }

    func test_builder_prefers_focused_meaningful_terminal_identity_over_earlier_pane_cwd() {
        let firstPaneID = PaneID("worklane-main-pane-1")
        let focusedPaneID = PaneID("worklane-main-pane-2")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar-feedback • …/docs")
        XCTAssertEqual(summary.focusedPaneLineIndex, 1)
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/app"])
    }

    func test_builder_tracks_middle_focused_pane_without_reordering_visible_pane_lines() {
        let firstPaneID = PaneID("worklane-main-pane-1")
        let focusedPaneID = PaneID("worklane-main-pane-2")
        let thirdPaneID = PaneID("worklane-main-pane-3")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar-feedback • …/docs")
        XCTAssertEqual(summary.focusedPaneLineIndex, 1)
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/app", "notes • /tmp/copy"])
    }

    func test_builder_falls_back_to_generic_shell_when_worklane_is_anonymous() {
        let paneID = PaneID("worklane-main-pane-1")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "pane 1")],
                focusedPaneID: paneID
            )
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "Shell")
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_prioritizes_attention_from_non_focused_agent_pane() {
        let shellPaneID = PaneID("worklane-main-shell")
        let agentPaneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)

        XCTAssertEqual(summary.primaryText, "main • …/project")
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.detailLines.map(\.text), ["feature/dismissals • …/project"])
        XCTAssertNil(summary.attentionState)
        XCTAssertEqual(
            summary.paneRows.first(where: { $0.paneID == agentPaneID })?.statusText,
            "Needs input"
        )
    }

    func test_builder_carries_split_interaction_metadata_into_pane_rows() {
        let paneID = PaneID("worklane-main-agent")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Claude Code",
            contextText: "main · /tmp/project",
            rememberedTitle: "Claude Code",
            recognizedTool: .claudeCode,
            runtimePhase: .needsInput,
            statusText: "Needs input",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false,
            interactionKind: .question,
            interactionLabel: "Needs decision",
            interactionSymbolName: "list.bullet"
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.attentionState, .needsInput)
        XCTAssertEqual(paneRow.statusText, "Needs decision")
        XCTAssertEqual(paneRow.interactionKind, .question)
        XCTAssertEqual(paneRow.interactionLabel, "Needs decision")
        XCTAssertEqual(paneRow.interactionSymbolName, "list.bullet")
    }

    func test_builder_surfaces_cwd_as_pane_row_detail_text_for_single_pane_with_remembered_title() {
        let paneID = PaneID("worklane-main-agent")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Claude Code",
            contextText: "main · /tmp/project",
            rememberedTitle: "Claude Code",
            recognizedTool: .claudeCode,
            runtimePhase: .idle,
            statusText: nil,
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false,
            interactionKind: nil
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Claude Code")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/project")
    }

    func test_builder_uses_default_interaction_label_and_symbol_for_kind_only_metadata() {
        let paneID = PaneID("worklane-main-agent")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Claude Code",
            contextText: "main · /tmp/project",
            rememberedTitle: "Claude Code",
            recognizedTool: .claudeCode,
            runtimePhase: .needsInput,
            statusText: "Needs input",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false,
            interactionKind: .auth
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.interactionKind, .auth)
        XCTAssertEqual(paneRow.interactionLabel, "Needs sign-in")
        XCTAssertEqual(paneRow.interactionSymbolName, "key.fill")
    }

    func test_builder_keeps_meaningful_custom_worklane_title_as_quiet_top_label() {
        let paneID = PaneID("worklane-docs-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-docs"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.topLabel, "Docs")
        XCTAssertEqual(summary.primaryText, "refresh-homepage-copy · …/marketing-site")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_builder_omits_detail_line_for_single_pane_rows_without_branch() {
        let paneID = PaneID("worklane-sidebar-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-sidebar"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/sidebar")
        XCTAssertEqual(summary.detailLines, [])
    }

    func test_builder_omits_custom_worklane_title_when_it_repeats_primary_identity() {
        let paneID = PaneID("worklane-sidebar-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-sidebar"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertNil(summary.topLabel)
        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility · …/sidebar")
    }

    func test_builder_keeps_explicit_session_artifact_out_of_sidebar_card() {
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
                    artifactLink: WorklaneArtifactLink(
                        kind: .session,
                        label: "Session",
                        url: URL(string: "https://example.com/session")!,
                        isExplicit: true
                    ),
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)

        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.paneRows.first?.statusText, "Needs input")
    }

    func test_builder_uses_pane_specific_detail_lines_for_multi_pane_worklanes() {
        let shellPaneID = PaneID("worklane-main-shell")
        let gitPaneID = PaneID("worklane-main-pane-1")
        let notesPaneID = PaneID("worklane-main-pane-2")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "fix-pane-border-text-visibility • …/sidebar")
        XCTAssertEqual(summary.detailLines.map(\.text), ["main • …/git", "notes • /tmp/copy"])
        XCTAssertNil(summary.overflowText)
    }

    func test_builder_excludes_focused_pane_from_detail_lines_while_preserving_other_pane_order() {
        let shellPaneID = PaneID("worklane-main-shell")
        let gitPaneID = PaneID("worklane-main-pane-1")
        let notesPaneID = PaneID("worklane-main-pane-2")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.detailLines.map(\.text), ["fix-pane-border-text-visibility • …/sidebar", "main • …/git"])
        XCTAssertEqual(summary.focusedPaneLineIndex, 2)
    }

    func test_builder_shows_all_non_focused_pane_detail_lines_without_overflow_for_four_pane_worklanes() {
        let firstPaneID = PaneID("worklane-main-shell")
        let secondPaneID = PaneID("worklane-main-pane-1")
        let thirdPaneID = PaneID("worklane-main-pane-2")
        let fourthPaneID = PaneID("worklane-main-pane-3")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.detailLines.map(\.text), ["fix-pane-border-text-visibility • …/sidebar", "main • …/git", "notes • /tmp/copy"])
        XCTAssertNil(summary.overflowText)
    }

    func test_builder_expands_branchless_pane_paths_instead_of_dropping_lines_that_repeat_primary() {
        let primaryPaneID = PaneID("worklane-main-pane-1")
        let secondaryPaneID = PaneID("worklane-main-pane-2")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/api")
        XCTAssertEqual(
            summary.detailLines.map(\.text),
            [
                "\(NSHomeDirectory())/src/api",
            ]
        )
    }

    func test_summaries_expand_colliding_primary_paths_to_longer_labels() {
        let apiWorklaneID = WorklaneID("worklane-api")
        let srcApiWorklaneID = WorklaneID("worklane-src-api")
        let worklanes = [
            WorklaneState(
                id: apiWorklaneID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("worklane-api-shell"), title: "shell")],
                    focusedPaneID: PaneID("worklane-api-shell")
                ),
                metadataByPaneID: [
                    PaneID("worklane-api-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/tmp/api",
                        processName: "zsh",
                        gitBranch: "main"
                    )
                ]
            ),
            WorklaneState(
                id: srcApiWorklaneID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("worklane-src-api-shell"), title: "shell")],
                    focusedPaneID: PaneID("worklane-src-api-shell")
                ),
                metadataByPaneID: [
                    PaneID("worklane-src-api-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: NSHomeDirectory() + "/src/api",
                        processName: "zsh",
                        gitBranch: "feature/sidebar"
                    )
                ]
            ),
        ]

        let summaries = WorklaneSidebarSummaryBuilder.summaries(
            for: worklanes,
            activeWorklaneID: apiWorklaneID
        )

        XCTAssertEqual(summaries.map(\.primaryText), ["main · …/api", "feature/sidebar · …/api"])
    }

    func test_summaries_surface_disambiguation_prefix_on_dedicated_context_line() {
        // Two worklanes point at branchless directories that share the same
        // leaf ("api") in different parents — the disambiguation pass should
        // expand each path and surface the extra parent segment on a
        // dedicated `contextPrefixText` line so the single-line primary
        // (which drives the shimmer overlay) stays short.
        //
        // Note: single-pane summaries only become `isCwdDerived` when the
        // primary text is derived directly from the working directory (i.e.
        // no git branch), so the test intentionally omits `gitBranch`.
        let firstWorklaneID = WorklaneID("worklane-one")
        let secondWorklaneID = WorklaneID("worklane-two")
        let worklanes = [
            WorklaneState(
                id: firstWorklaneID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("worklane-one-shell"), title: "shell")],
                    focusedPaneID: PaneID("worklane-one-shell")
                ),
                metadataByPaneID: [
                    PaneID("worklane-one-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/tmp/alpha/api",
                        processName: "zsh",
                        gitBranch: nil
                    )
                ]
            ),
            WorklaneState(
                id: secondWorklaneID,
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: PaneID("worklane-two-shell"), title: "shell")],
                    focusedPaneID: PaneID("worklane-two-shell")
                ),
                metadataByPaneID: [
                    PaneID("worklane-two-shell"): TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/tmp/beta/api",
                        processName: "zsh",
                        gitBranch: nil
                    )
                ]
            ),
        ]

        let summaries = WorklaneSidebarSummaryBuilder.summaries(
            for: worklanes,
            activeWorklaneID: firstWorklaneID
        )

        // Primaries stay un-expanded — the shimmer overlay is single-line only
        // and would be hidden if these wrapped.
        XCTAssertEqual(
            summaries.map(\.primaryText),
            ["…/api", "…/api"]
        )
        // The disambiguation delta lands on the dedicated context prefix slot,
        // one segment deeper per worklane.
        let prefixes = summaries.map(\.contextPrefixText)
        XCTAssertEqual(prefixes.count, 2)
        XCTAssertEqual(prefixes[0], "…/alpha")
        XCTAssertEqual(prefixes[1], "…/beta")
    }

    func test_summaries_leave_context_prefix_nil_when_no_disambiguation_is_needed() {
        let worklaneID = WorklaneID("worklane-solo")
        let worklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("worklane-solo-shell"), title: "shell")],
                focusedPaneID: PaneID("worklane-solo-shell")
            ),
            metadataByPaneID: [
                PaneID("worklane-solo-shell"): TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/tmp/zentty",
                    processName: "zsh",
                    gitBranch: nil
                )
            ]
        )

        let summaries = WorklaneSidebarSummaryBuilder.summaries(
            for: [worklane],
            activeWorklaneID: worklaneID
        )

        let summary = try! XCTUnwrap(summaries.first)
        XCTAssertNil(summary.contextPrefixText)
    }

    func test_builder_marks_worklane_as_working_when_background_terminal_progress_exists() {
        let shellPaneID = PaneID("worklane-main-shell")
        let backgroundPaneID = PaneID("worklane-main-background")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertTrue(summary.isWorking)
        XCTAssertNil(summary.statusText)
        XCTAssertNil(summary.attentionState)
    }

    func test_builder_keeps_terminal_derived_primary_text_for_recognized_agent_before_meaningful_work() {
        let paneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "feature/sidebar · …/project")
        XCTAssertNil(summary.statusText)
        XCTAssertFalse(summary.isWorking)
    }

    func test_builder_does_not_mark_recognized_agent_worklane_as_running_from_terminal_progress_alone() {
        let paneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/project")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.statusText)
        XCTAssertNil(summary.attentionState)
    }

    func test_builder_omits_single_pane_detail_when_primary_already_contains_same_directory() {
        let paneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "…/nimbu")
        XCTAssertEqual(summary.detailLines.map(\.text), [])
    }

    func test_summaries_drop_startup_progress_for_recognized_agents_after_disambiguation_pass() {
        let worklaneID = WorklaneID("worklane-main")
        let paneID = PaneID("worklane-main-agent")
        let worklanes = [
            WorklaneState(
                id: worklaneID,
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
            WorklaneSidebarSummaryBuilder.summaries(
                for: worklanes,
                activeWorklaneID: worklaneID
            ).first
        )

        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.statusText)
    }

    func test_builder_uses_review_state_without_extra_sidebar_artifact_projection() {
        let paneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
                paneID: WorklaneReviewState(
                    branch: "main",
                    pullRequest: WorklanePullRequestSummary(
                        number: 1413,
                        url: URL(string: "https://example.com/pr/1413"),
                        state: .open
                    ),
                    reviewChips: [WorklaneReviewChip(text: "1 failing", style: .danger)]
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)

        XCTAssertEqual(summary.primaryText, "main · …/project")
        XCTAssertEqual(summary.detailLines.map { $0.text }, [])
    }

    func test_builder_keeps_running_single_pane_agent_title_primary_and_branch_trailing() {
        let paneID = PaneID("worklane-main-agent-running")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-running"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(summary.paneRows.count, 1)
        XCTAssertEqual(paneRow.primaryText, "Test session setup")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/nimbu")
        XCTAssertEqual(paneRow.statusText, "Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_uses_exact_codex_status_title_as_primary_when_running() {
        let paneID = PaneID("worklane-main-codex-running")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-codex-running"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Working ⠋ Investigate pane title updates",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
                    processName: "codex",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .codex,
                    state: .running,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42)
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Working ⠋ Investigate pane title updates")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/zentty")
        XCTAssertEqual(paneRow.statusText, "Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_uses_exact_claude_status_title_as_primary_when_running() {
        let paneID = PaneID("worklane-main-claude-running")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-claude-running"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Thinking ✳ Investigate pane title updates",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Thinking ✳ Investigate pane title updates")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/zentty")
        XCTAssertEqual(paneRow.statusText, "Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_surfaces_running_for_codex_spinner_title_without_explicit_agent_status() {
        let paneID = PaneID("worklane-main-codex-title-only")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/Users/peter/Development/Personal/zentty",
            repoRoot: "/Users/peter/Development/Personal/zentty",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "zentty",
            contextText: "main · …/zentty",
            rememberedTitle: "zentty",
            recognizedTool: .codex,
            runtimePhase: .running,
            statusText: "Running",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: true,
            interactionKind: nil
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-codex-title-only"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "zentty")
        XCTAssertEqual(paneRow.statusText, "Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_keeps_idle_single_pane_agent_title_primary_and_branch_trailing() {
        let paneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
                    state: .idle,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42),
                    hasObservedRunning: true
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(summary.paneRows.count, 1)
        XCTAssertEqual(paneRow.paneID, paneID)
        XCTAssertEqual(paneRow.primaryText, "General coding assistance session")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/nimbu")
        XCTAssertEqual(paneRow.statusText, "Idle")
        XCTAssertNil(paneRow.attentionState)
        XCTAssertFalse(paneRow.isWorking)
    }

    func test_builder_surfaces_agent_ready_for_completed_single_pane_agent_row() {
        let paneID = PaneID("worklane-main-agent-ready")
        var auxiliaryState = PaneAuxiliaryState(
            metadata: TerminalMetadata(
                title: "General coding assistance session",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                processName: "codex",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true
            )
        )
        auxiliaryState.raw.lastDesktopNotificationText = "Agent run complete"
        auxiliaryState.raw.lastDesktopNotificationDate = Date(timeIntervalSince1970: 42)
        auxiliaryState.raw.showsReadyStatus = true
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "agent",
            raw: auxiliaryState.raw,
            previous: nil
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.statusText, "Agent ready")
        XCTAssertEqual(paneRow.attentionState, .ready)
    }

    func test_builder_keeps_starting_single_pane_agent_title_primary_and_branch_trailing() {
        let paneID = PaneID("worklane-main-agent-starting")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-starting"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Test session setup")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertEqual(paneRow.detailText, "…/nimbu")
        XCTAssertNil(paneRow.statusText)
        XCTAssertNil(paneRow.attentionState)
        XCTAssertFalse(paneRow.isWorking)
    }

    func test_builder_moves_branch_to_trailing_for_idle_single_pane_agent_path_identity() {
        let paneID = PaneID("worklane-main-agent-path")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-path"),
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
                    state: .idle,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42),
                    hasObservedRunning: true
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "…/nimbu")
        XCTAssertEqual(paneRow.trailingText, "main")
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "Idle")
    }

    func test_builder_attaches_terminal_progress_status_to_own_non_agent_pane_row() {
        let shellPaneID = PaneID("worklane-main-shell")
        let buildPaneID = PaneID("worklane-main-build")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first { $0.paneID == buildPaneID })

        XCTAssertEqual(paneRow.primaryText, "npm test · …/project")
        XCTAssertNil(paneRow.trailingText)
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "Running")
        XCTAssertEqual(paneRow.attentionState, .running)
        XCTAssertTrue(paneRow.isWorking)
    }

    func test_builder_keeps_cwd_detail_for_multi_pane_agent_rows_with_meaningful_titles() {
        let shellPaneID = PaneID("worklane-main-shell")
        let agentPaneID = PaneID("worklane-main-agent")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
                    state: .idle,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42),
                    hasObservedRunning: true
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first { $0.paneID == agentPaneID })

        XCTAssertEqual(paneRow.primaryText, "Test session setup · …/nimbu")
        XCTAssertEqual(paneRow.trailingText, "feature/sidebar")
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "Idle")
    }

    func test_builder_moves_branch_to_trailing_for_multi_pane_agent_path_identity() {
        let shellPaneID = PaneID("worklane-main-shell")
        let agentPaneID = PaneID("worklane-main-agent-path")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main-path-multi"),
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
                    title: "/Users/peter",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                    processName: "claude",
                    gitBranch: "feature/sidebar"
                ),
            ],
            agentStatusByPaneID: [
                agentPaneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .idle,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 42),
                    hasObservedRunning: true
                )
            ]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        let paneRow = try! XCTUnwrap(summary.paneRows.first { $0.paneID == agentPaneID })

        XCTAssertEqual(paneRow.primaryText, "…/nimbu")
        XCTAssertEqual(paneRow.trailingText, "feature/sidebar")
        XCTAssertNil(paneRow.detailText)
        XCTAssertEqual(paneRow.statusText, "Idle")
    }
}
