import XCTest
@testable import Zentty

final class PanePresentationStateTests: XCTestCase {
    func test_normalize_prefers_meaningful_title_and_canonical_branch_context() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Test session setup",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                processName: "claude",
                gitBranch: "wrong-branch"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                repositoryRoot: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                reference: .branch("main")
            )
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.identityText, "Test session setup")
        XCTAssertEqual(presentation.branch, "main")
        XCTAssertEqual(presentation.branchDisplayText, "main")
        XCTAssertEqual(presentation.contextText, "main · …/nimbu")
        XCTAssertEqual(presentation.runtimePhase, PanePresentationPhase.running)
        XCTAssertEqual(presentation.statusText, "Running")
        XCTAssertTrue(presentation.isWorking)
    }

    func test_normalize_preserves_remembered_title_across_completion_and_metadata_loss() {
        var previous = PanePresentationState()
        previous.cwd = "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu"
        previous.repoRoot = "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu"
        previous.branch = "main"
        previous.branchDisplayText = "main"
        previous.lookupBranch = "main"
        previous.identityText = "Test session setup"
        previous.contextText = "main · …/nimbu"
        previous.rememberedTitle = "Test session setup"
        previous.recognizedTool = .claudeCode
        previous.runtimePhase = .running
        previous.statusText = "Running"
        previous.isWorking = true
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                processName: "claude",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .completed,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                repositoryRoot: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                reference: .branch("main")
            )
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: previous
        )

        XCTAssertEqual(presentation.identityText, "Test session setup")
        XCTAssertEqual(presentation.rememberedTitle, "Test session setup")
        XCTAssertEqual(presentation.contextText, "main · …/nimbu")
        XCTAssertEqual(presentation.runtimePhase, PanePresentationPhase.completed)
        XCTAssertEqual(presentation.statusText, "Completed")
        XCTAssertFalse(presentation.isWorking)
    }

    func test_normalize_uses_short_sha_for_detached_head_and_hides_starting_status() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "/Users/peter",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                processName: "claude",
                gitBranch: "wrong-branch"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .starting,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                repositoryRoot: "/Users/peter/Development/Zenjoy/Nimbu/Rails/nimbu",
                reference: .detached("a1b2c3d")
            )
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.identityText, "a1b2c3d (detached) · …/nimbu")
        XCTAssertNil(presentation.branch)
        XCTAssertEqual(presentation.branchDisplayText, "a1b2c3d (detached)")
        XCTAssertEqual(presentation.runtimePhase, PanePresentationPhase.starting)
        XCTAssertNil(presentation.statusText)
        XCTAssertFalse(presentation.isWorking)
    }

    func test_normalize_ignores_stale_review_facts_when_canonical_git_context_is_missing() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Test session setup",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .completed,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 40)
            ),
            terminalProgress: nil,
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            ),
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertNil(presentation.pullRequest)
        XCTAssertEqual(presentation.reviewChips, [])
    }

    func test_normalize_uses_local_shell_branch_provisionally_until_canonical_git_context_exists() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Test session setup",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: PaneShellContext(
                scope: .local,
                path: "/tmp/project",
                home: "/Users/peter",
                user: "peter",
                host: "mbp",
                gitBranch: "feature/review-band"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .completed,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 50)
            ),
            terminalProgress: nil,
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            ),
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertNil(presentation.branch)
        XCTAssertEqual(presentation.branchDisplayText, "feature/review-band")
        XCTAssertNil(presentation.lookupBranch)
        XCTAssertNil(presentation.pullRequest)
        XCTAssertEqual(presentation.reviewChips, [])
        XCTAssertEqual(presentation.contextText, "feature/review-band · /tmp/project")
    }

    func test_normalize_preserves_non_pull_request_attention_artifact_and_timestamp() {
        let updatedAt = Date(timeIntervalSince1970: 55)
        let sessionURL = URL(string: "https://example.com/session/123")!
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Investigate flaky test",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .needsInput,
                text: "Needs input",
                artifactLink: WorkspaceArtifactLink(
                    kind: .session,
                    label: "Session",
                    url: sessionURL,
                    isExplicit: true
                ),
                updatedAt: updatedAt
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.attentionArtifactLink?.kind, .session)
        XCTAssertEqual(presentation.attentionArtifactLink?.url, sessionURL)
        XCTAssertEqual(presentation.updatedAt, updatedAt)
    }

    func test_normalize_does_not_expose_pull_request_artifacts_through_attention_channel() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Investigate flaky test",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "feature/review-band"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: WorkspaceArtifactLink(
                    kind: .pullRequest,
                    label: "PR #1413",
                    url: URL(string: "https://example.com/pr/1413")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 60)
            ),
            terminalProgress: nil,
            reviewState: WorkspaceReviewState(
                branch: "feature/review-band",
                pullRequest: WorkspacePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            ),
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("feature/review-band")
            )
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.pullRequest?.number, 1413)
        XCTAssertNil(presentation.attentionArtifactLink)
    }

    func test_normalize_prefers_agent_working_directory_over_shell_cwd_when_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "peter@MacBookPro:~",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "claude",
                gitBranch: nil
            ),
            shellContext: PaneShellContext(
                scope: .local,
                path: NSHomeDirectory(),
                home: NSHomeDirectory(),
                user: "peter",
                host: "MacBookPro"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                workingDirectory: "/Users/peter/Development/my-project"
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.cwd, "/Users/peter/Development/my-project")
    }

    func test_normalize_reverts_to_shell_cwd_after_agent_completes() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: "/Users/peter/Development/other-project",
                processName: "zsh",
                gitBranch: nil
            ),
            shellContext: PaneShellContext(
                scope: .local,
                path: "/Users/peter/Development/other-project",
                home: NSHomeDirectory(),
                user: "peter",
                host: "MacBookPro"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .completed,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                workingDirectory: "/Users/peter/Development/my-project"
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.cwd, "/Users/peter/Development/other-project")
    }

    func test_normalize_falls_through_when_agent_has_no_working_directory() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "claude",
                gitBranch: nil
            ),
            shellContext: PaneShellContext(
                scope: .local,
                path: NSHomeDirectory(),
                home: NSHomeDirectory(),
                user: "peter",
                host: "MacBookPro"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date()
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.cwd, NSHomeDirectory())
    }
}
