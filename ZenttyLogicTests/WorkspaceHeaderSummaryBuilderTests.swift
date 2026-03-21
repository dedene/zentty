import Foundation
import XCTest
@testable import Zentty

final class WorkspaceHeaderSummaryBuilderTests: XCTestCase {
    func test_summary_uses_cached_review_state_and_keeps_workspace_attention() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .needsInput,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [
                    WorkspaceReviewChip(text: "Draft", style: .info),
                    WorkspaceReviewChip(text: "2 failing", style: .danger),
                ]
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.attention?.statusText, "Needs input")
        XCTAssertEqual(summary.focusedLabel, "Claude Code")
        XCTAssertEqual(summary.branch, "feature/review-band")
        XCTAssertEqual(summary.pullRequest?.number, 128)
        XCTAssertEqual(summary.reviewChips.map(\.text), ["Draft", "2 failing"])
    }

    func test_summary_falls_back_to_inferred_pull_request_artifact_when_explicit_pr_is_missing() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            inferredArtifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.branch, "feature/review-band")
        XCTAssertEqual(summary.pullRequest?.number, 128)
        XCTAssertEqual(summary.reviewChips, [WorkspaceReviewChip(text: "Ready", style: .success)])
    }

    func test_summary_falls_back_to_explicit_pull_request_artifact_when_cached_state_missing() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: WorkspaceArtifactLink(
                    kind: .pullRequest,
                    label: "PR #42",
                    url: URL(string: "https://example.com/pr/42")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.pullRequest?.number, 42)
        XCTAssertEqual(summary.reviewChips, [WorkspaceReviewChip(text: "Ready", style: .success)])
    }

    func test_summary_ignores_non_pull_request_artifacts_when_deriving_pr_identity() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: WorkspaceArtifactLink(
                    kind: .session,
                    label: "Session",
                    url: URL(string: "https://example.com/session")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            inferredArtifact: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #128",
                url: URL(string: "https://example.com/pr/128")!,
                isExplicit: false
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.pullRequest?.number, 128)
    }

    func test_summary_shows_branch_only_when_review_state_is_unavailable() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_omits_compacted_metadata_branch_when_review_state_is_unavailable() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "m...n"
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertNil(summary.branch)
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_prefers_terminal_title_over_cwd_when_title_is_meaningful() {
        let paneID = PaneID("pane-shell")
        let homePath = NSHomeDirectory()
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nim...",
                currentWorkingDirectory: "\(homePath)/Development/Zenjoy/Nimbu/Rails/nimbu",
                processName: "zsh",
                gitBranch: nil
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.focusedLabel, "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nim...")
    }

    func test_summary_omits_git_fields_for_non_git_focus() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.focusedLabel, "zsh")
        XCTAssertNil(summary.branch)
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_uses_focused_pane_context_in_multi_pane_workspace() {
        let shellPaneID = PaneID("pane-shell")
        let gitPaneID = PaneID("pane-git")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: gitPaneID, title: "git"),
                ],
                focusedPaneID: gitPaneID
            ),
            metadataByPaneID: [
                shellPaneID: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/tmp/app",
                    processName: "zsh",
                    gitBranch: "main"
                ),
                gitPaneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/docs",
                    processName: "claude",
                    gitBranch: "feature/sidebar-feedback"
                ),
            ],
            reviewStateByPaneID: [
                gitPaneID: WorkspaceReviewState(
                    branch: "feature/sidebar-feedback",
                    pullRequest: WorkspacePullRequestSummary(
                        number: 42,
                        url: URL(string: "https://example.com/pr/42"),
                        state: .open
                    ),
                    reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
                )
            ]
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.focusedLabel, "Claude Code")
        XCTAssertEqual(summary.branch, "feature/sidebar-feedback")
        XCTAssertEqual(summary.pullRequest?.number, 42)
    }

    func test_summary_prefers_recognized_tool_name_before_process_name_and_pane_title() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            paneTitle: "shell pane",
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: nil,
                processName: "codex",
                gitBranch: nil
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.focusedLabel, "Codex")
    }

    func test_summary_prefers_recognized_tool_name_over_cwd_for_agent_panes() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            paneTitle: "shell pane",
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: nil
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.focusedLabel, "Codex")
    }

    func test_summary_backfills_branch_from_metadata_when_cached_review_state_omits_it() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            reviewState: WorkspaceReviewState(
                branch: nil,
                pullRequest: WorkspacePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: []
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.branch, "feature/review-band")
        XCTAssertEqual(summary.reviewChips, [WorkspaceReviewChip(text: "Draft", style: .info)])
    }

    func test_summary_preserves_cached_branch_when_metadata_branch_is_compacted() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "m...n"
            ),
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: nil,
                reviewChips: []
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertEqual(summary.branch, "main")
    }

    func test_summary_omits_compacted_cached_branch_when_no_full_branch_source_exists() {
        let paneID = PaneID("pane-shell")
        let workspace = makeWorkspace(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            ),
            reviewState: WorkspaceReviewState(
                branch: "m...n",
                pullRequest: nil,
                reviewChips: []
            )
        )

        let summary = WorkspaceHeaderSummaryBuilder.summary(
            for: workspace,
            reviewStateProvider: DefaultWorkspaceReviewStateProvider()
        )

        XCTAssertNil(summary.branch)
    }

    private func makeWorkspace(
        paneID: PaneID,
        paneTitle: String = "shell",
        metadata: TerminalMetadata,
        agentStatus: PaneAgentStatus? = nil,
        inferredArtifact: WorkspaceArtifactLink? = nil,
        reviewState: WorkspaceReviewState? = nil
    ) -> WorkspaceState {
        WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: paneTitle)],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [paneID: metadata],
            agentStatusByPaneID: agentStatus.map { [paneID: $0] } ?? [:],
            inferredArtifactByPaneID: inferredArtifact.map { [paneID: $0] } ?? [:],
            reviewStateByPaneID: reviewState.map { [paneID: $0] } ?? [:]
        )
    }
}
