import Foundation
import XCTest
@testable import Zentty

final class WorklaneHeaderSummaryBuilderTests: XCTestCase {
    func test_summary_uses_cached_review_state_and_keeps_worklane_attention() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
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
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: [
                    WorklaneReviewChip(text: "Draft", style: .info),
                    WorklaneReviewChip(text: "2 failing", style: .danger),
                ]
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.attention?.statusText, "Needs input")
        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertEqual(summary.branch, "feature/review-band")
        XCTAssertEqual(summary.pullRequest?.number, 128)
        XCTAssertEqual(summary.reviewChips.map(\.text), ["Draft", "2 failing"])
    }

    func test_summary_does_not_surface_explicit_pull_request_artifact_without_review_resolution() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
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
                artifactLink: WorklaneArtifactLink(
                    kind: .pullRequest,
                    label: "PR #42",
                    url: URL(string: "https://example.com/pr/42")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_attention_does_not_surface_pull_request_artifact_without_review_resolution() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
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
                artifactLink: WorklaneArtifactLink(
                    kind: .pullRequest,
                    label: "PR #42",
                    url: URL(string: "https://example.com/pr/42")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertNil(summary.attention?.artifactLink)
    }

    func test_summary_attention_preserves_non_pull_request_agent_artifact() {
        let paneID = PaneID("pane-shell")
        let sessionURL = URL(string: "https://example.com/session/abc")!
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .needsInput,
                text: "Needs input",
                artifactLink: WorklaneArtifactLink(
                    kind: .session,
                    label: "Session",
                    url: sessionURL,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.attention?.artifactLink?.kind, .session)
        XCTAssertEqual(summary.attention?.artifactLink?.url, sessionURL)
    }

    func test_summary_uses_location_context_when_review_state_is_unavailable() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertEqual(summary.branch, "main")
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_shows_branch_separately_when_focused_label_uses_location_context() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertEqual(summary.branch, "main")
    }

    func test_summary_uses_branch_to_compact_worktree_focused_label_without_local_git_probe() {
        let paneID = PaneID("pane-shell")
        let branch = "feature/scaleway-transactional-mails"
        let worktreePath = "\(NSHomeDirectory())/Development/Zenjoy/Nimbu/Rails/worktrees/\(branch)"
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/\(branch)",
                    currentWorkingDirectory: nil,
                    processName: "zsh"
                )
            ],
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: worktreePath,
                    repositoryRoot: worktreePath,
                    reference: .branch(branch)
                )
            ]
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "…/scaleway-transactional-mails")
        XCTAssertEqual(summary.branch, branch)
    }

    func test_summary_hides_detached_branch_chip_when_focused_label_already_contains_detached_reference() {
        let paneID = PaneID("pane-shell")
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
                    currentWorkingDirectory: "/tmp/project",
                    processName: "zsh",
                    gitBranch: nil
                )
            ],
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .detached("abcd123")
                )
            ]
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertEqual(summary.branch, "abcd123 (detached)")
    }

    func test_summary_hides_attention_for_starting_agent_session() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .starting,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertNil(summary.attention)
    }

    func test_summary_omits_compacted_metadata_branch_when_review_state_is_unavailable() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "m...n"
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertNil(summary.branch)
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_prefers_terminal_title_over_cwd_when_title_is_meaningful() {
        let paneID = PaneID("pane-shell")
        let homePath = NSHomeDirectory()
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nim...",
                currentWorkingDirectory: "\(homePath)/Development/Zenjoy/Nimbu/Rails/nimbu",
                processName: "zsh",
                gitBranch: nil
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "…/nimbu")
    }

    func test_summary_omits_git_fields_for_non_git_focus() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "zsh")
        XCTAssertNil(summary.branch)
        XCTAssertNil(summary.pullRequest)
        XCTAssertEqual(summary.reviewChips, [])
    }

    func test_summary_uses_focused_pane_context_in_multi_pane_worklane() {
        let shellPaneID = PaneID("pane-shell")
        let gitPaneID = PaneID("pane-git")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
                gitPaneID: WorklaneReviewState(
                    branch: "feature/sidebar-feedback",
                    pullRequest: WorklanePullRequestSummary(
                        number: 42,
                        url: URL(string: "https://example.com/pr/42"),
                        state: .open
                    ),
                    reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
                )
            ]
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/docs")
        XCTAssertEqual(summary.branch, "feature/sidebar-feedback")
        XCTAssertEqual(summary.pullRequest?.number, 42)
    }

    func test_summary_uses_terminal_process_name_when_no_better_identity_exists() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            paneTitle: "shell pane",
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: nil,
                processName: "codex",
                gitBranch: nil
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "codex")
    }

    func test_summary_prefers_stable_location_over_agent_process_name_when_cwd_exists() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            paneTitle: "shell pane",
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: nil
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
    }

    func test_summary_keeps_meaningful_session_title_for_idle_agent_panes() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "General coding assistance session",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42)
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "General coding assistance session")
        XCTAssertEqual(summary.branch, "main")
    }

    func test_summary_splits_branch_out_of_terminal_title_when_present() {
        let paneID = PaneID("pane-shell")
        let branch = "feature/scaleway-transactional-mails"
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "\(branch) · …/scaleway-transactional-mails",
                currentWorkingDirectory: "/tmp/scaleway-transactional-mails",
                processName: "zsh",
                gitBranch: branch
            ),
            reviewState: WorklaneReviewState(
                branch: branch,
                pullRequest: WorklanePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: []
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "…/scaleway-transactional-mails")
        XCTAssertEqual(summary.branch, branch)
        XCTAssertEqual(summary.pullRequest?.number, 1413)
    }

    func test_summary_backfills_branch_from_metadata_when_cached_review_state_omits_it() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Claude Code",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            reviewState: WorklaneReviewState(
                branch: nil,
                pullRequest: WorklanePullRequestSummary(
                    number: 128,
                    url: URL(string: "https://example.com/pr/128"),
                    state: .draft
                ),
                reviewChips: []
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertEqual(summary.branch, "feature/review-band")
        XCTAssertEqual(summary.reviewChips, [WorklaneReviewChip(text: "Draft", style: .info)])
    }

    func test_summary_omits_branch_when_only_compacted_sources_exist() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "m...n"
            ),
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: nil,
                reviewChips: []
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary.focusedLabel, "/tmp/project")
        XCTAssertNil(summary.branch)
    }

    func test_summary_omits_compacted_cached_branch_when_no_full_branch_source_exists() {
        let paneID = PaneID("pane-shell")
        let worklane = makeWorklane(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            ),
            reviewState: WorklaneReviewState(
                branch: "m...n",
                pullRequest: nil,
                reviewChips: []
            )
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: worklane)

        XCTAssertNil(summary.branch)
    }

    private func makeWorklane(
        paneID: PaneID,
        paneTitle: String = "shell",
        metadata: TerminalMetadata,
        agentStatus: PaneAgentStatus? = nil,
        reviewState: WorklaneReviewState? = nil
    ) -> WorklaneState {
        WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: paneTitle)],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [paneID: metadata],
            agentStatusByPaneID: agentStatus.map { [paneID: $0] } ?? [:],
            reviewStateByPaneID: reviewState.map { [paneID: $0] } ?? [:]
        )
    }
}
