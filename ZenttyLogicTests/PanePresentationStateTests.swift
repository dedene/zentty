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

    func test_normalize_preserves_remembered_title_across_idle_and_metadata_loss() {
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
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 20),
                hasObservedRunning: true
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
        XCTAssertEqual(presentation.runtimePhase, PanePresentationPhase.idle)
        XCTAssertEqual(presentation.statusText, "Idle")
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

    func test_normalize_hides_idle_when_session_was_never_observed_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 35)
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

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertNil(presentation.statusText)
    }

    func test_normalize_shows_idle_task_progress_when_incomplete_even_before_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "opencode",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .openCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 36),
                taskProgress: PaneAgentTaskProgress(doneCount: 0, totalCount: 3)
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

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.statusText, "Idle (0/3)")
        XCTAssertFalse(presentation.isReady)
        XCTAssertNil(presentation.statusSymbolName)
    }

    func test_normalize_suppresses_ready_label_while_task_progress_is_incomplete() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Implement task progress",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true,
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            ),
            showsReadyStatus: true,
            lastDesktopNotificationText: "Agent ready",
            lastDesktopNotificationDate: Date(timeIntervalSince1970: 42)
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.statusText, "Idle (1/3)")
        XCTAssertFalse(presentation.isReady)
        XCTAssertNil(presentation.statusSymbolName)
    }

    func test_normalize_restores_ready_label_once_task_progress_is_complete() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Implement task progress",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true,
                taskProgress: PaneAgentTaskProgress(doneCount: 3, totalCount: 3)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            ),
            showsReadyStatus: true,
            lastDesktopNotificationText: "Agent ready",
            lastDesktopNotificationDate: Date(timeIntervalSince1970: 42)
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.statusText, "Agent ready")
        XCTAssertTrue(presentation.isReady)
        XCTAssertEqual(presentation.statusSymbolName, "checkmark.circle.fill")
    }

    func test_normalize_treats_codex_spinner_title_variants_as_same_running_identity() {
        let spinnerFrames = ["Working ⠋ zentty", "Working ⠙ zentty"]

        let presentations = spinnerFrames.map { title in
            PanePresentationNormalizer.normalize(
                paneTitle: "shell",
                raw: PaneRawState(
                    metadata: TerminalMetadata(
                        title: title,
                        currentWorkingDirectory: "/tmp/project",
                        processName: "codex",
                        gitBranch: "main"
                    ),
                    shellContext: nil,
                    agentStatus: nil,
                    terminalProgress: nil,
                    reviewState: nil,
                    gitContext: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("main")
                    )
                ),
                previous: nil
            )
        }

        XCTAssertEqual(presentations.map(\.runtimePhase), [.running, .running])
        XCTAssertEqual(presentations.map(\.statusText), ["Running", "Running"])
        XCTAssertEqual(presentations[0].identityText, presentations[1].identityText)
        XCTAssertEqual(presentations[0].rememberedTitle, presentations[1].rememberedTitle)
    }

    func test_normalize_infers_codex_from_spinner_title_without_process_name() {
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: PaneRawState(
                metadata: TerminalMetadata(
                    title: "Working ⠋ zentty",
                    currentWorkingDirectory: "/tmp/project",
                    processName: nil,
                    gitBranch: "main"
                ),
                shellContext: nil,
                agentStatus: nil,
                terminalProgress: nil,
                reviewState: nil,
                gitContext: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                )
            ),
            previous: nil
        )

        XCTAssertEqual(presentation.recognizedTool, .codex)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_normalize_does_not_infer_codex_from_generic_working_title_without_process_name() {
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: PaneRawState(
                metadata: TerminalMetadata(
                    title: "Working :: project",
                    currentWorkingDirectory: "/tmp/project",
                    processName: nil,
                    gitBranch: "main"
                ),
                shellContext: nil,
                agentStatus: nil,
                terminalProgress: nil,
                reviewState: nil,
                gitContext: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                )
            ),
            previous: nil
        )

        XCTAssertNil(presentation.recognizedTool)
        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertNil(presentation.statusText)
    }

    func test_normalize_lets_codex_working_title_override_attached_starting_state() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .starting,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 41),
                trackedPID: 4242
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

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
        XCTAssertTrue(presentation.isWorking)
    }

    func test_normalize_lets_codex_working_title_override_stale_idle_state() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 41),
                hasObservedRunning: true
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

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
        XCTAssertTrue(presentation.isWorking)
    }

    func test_normalize_lets_codex_ready_title_override_attached_starting_state_after_running() {
        var previous = PanePresentationState()
        previous.runtimePhase = .running
        previous.statusText = "Running"
        previous.recognizedTool = .codex
        previous.isWorking = true

        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Ready zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .starting,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                trackedPID: 4242
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
            previous: previous
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.statusText, "Idle")
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
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 40),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
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
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 50),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
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

    func test_normalize_keeps_non_agent_pane_without_visible_idle_status() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: nil,
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

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertNil(presentation.statusText)
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
                artifactLink: WorklaneArtifactLink(
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

    func test_normalize_keeps_broad_status_text_while_exposing_split_question_metadata() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Review deployment",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .needsInput,
                text: "Ship this?\n[Yes] [No]",
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 60),
                interactionKind: .question
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

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.statusText, "Needs decision")
        XCTAssertEqual(presentation.interactionKind, .question)
        XCTAssertEqual(presentation.interactionLabel, "Needs decision")
        XCTAssertEqual(presentation.interactionSymbolName, "list.bullet")
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
                artifactLink: WorklaneArtifactLink(
                    kind: .pullRequest,
                    label: "PR #1413",
                    url: URL(string: "https://example.com/pr/1413")!,
                    isExplicit: true
                ),
                updatedAt: Date(timeIntervalSince1970: 60)
            ),
            terminalProgress: nil,
            reviewState: WorklaneReviewState(
                branch: "feature/review-band",
                pullRequest: WorklanePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
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

    func test_normalize_ignores_agent_working_directory_and_keeps_terminal_cwd_when_running() {
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

        XCTAssertEqual(presentation.cwd, NSHomeDirectory())
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
                state: .idle,
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

    func test_normalize_keeps_terminal_cwd_even_when_agent_reports_a_different_working_directory() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "zsh",
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
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                workingDirectory: "/tmp/project"
            ),
            shellActivityState: .commandRunning,
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

    func test_normalize_shows_command_title_during_execution_in_regular_shell() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "cmatrix",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "zsh",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.rememberedTitle, "cmatrix")
        XCTAssertEqual(presentation.identityText, "cmatrix")
    }

    func test_normalize_clears_command_title_when_prompt_returns_in_regular_shell() {
        var previous = PanePresentationState()
        previous.rememberedTitle = "cmatrix"
        previous.identityText = "cmatrix"

        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "~/Development/project",
                currentWorkingDirectory: "\(NSHomeDirectory())/Development/project",
                processName: "zsh",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: previous
        )

        XCTAssertNil(presentation.rememberedTitle)
    }

    func test_normalize_preserves_agent_remembered_title_when_title_reverts_to_cwd() {
        var previous = PanePresentationState()
        previous.rememberedTitle = "Investigate flaky test"
        previous.recognizedTool = .claudeCode

        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "~/Development/project",
                currentWorkingDirectory: "\(NSHomeDirectory())/Development/project",
                processName: "claude",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 70),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: previous
        )

        XCTAssertEqual(presentation.rememberedTitle, "Investigate flaky test")
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

    // MARK: - Claude Code title-based idle override

    func test_normalize_clears_running_when_claude_code_title_indicates_interrupted() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Interrupted · What should Claude do instead?",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
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

        XCTAssertEqual(presentation.runtimePhase, .idle)
    }

    func test_normalize_keeps_needs_input_when_claude_code_title_indicates_idle() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Interrupted · What should Claude do instead?",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .needsInput,
                text: "Approve tool?",
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10),
                interactionKind: .approval
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

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
    }

    func test_normalize_does_not_let_claude_code_title_promote_idle_to_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Thinking · about something",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
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

        XCTAssertEqual(presentation.runtimePhase, .idle)
    }

    func test_normalize_copilot_idle_with_osc_activity_resolves_to_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "GitHub Copilot",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .copilot,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
        XCTAssertTrue(presentation.isWorking)
    }

    func test_normalize_copilot_asking_title_resolves_to_needs_input_with_question_kind() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Asking question",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .copilot,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
        XCTAssertEqual(presentation.statusText, "Needs decision")
        XCTAssertEqual(presentation.interactionLabel, "Needs decision")
        XCTAssertFalse(presentation.isWorking)
    }

    func test_normalize_copilot_asking_title_beats_osc_activity() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Asking user",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .copilot,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
    }

    func test_normalize_copilot_non_asking_title_with_osc_activity_resolves_to_running() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "GitHub Copilot",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .copilot,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertNil(presentation.interactionKind)
    }

    func test_normalize_copilot_idle_with_osc_removed_stays_idle() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "GitHub Copilot",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .copilot,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: TerminalProgressReport(state: .remove, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertFalse(presentation.isWorking)
    }

    // MARK: - Copilot "Needs input" title detection without hooks

    func test_normalize_copilot_asking_title_without_hook_resolves_to_needs_input() {
        // Live-app regression: CopilotHookBridge may not have fired yet,
        // so agentStatus is nil. The normalizer must still detect the
        // "Asking ..." title via metadata.processName (not recognizedTool,
        // which uses resolveKnown and excludes copilot by design).
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Asking user question",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
        XCTAssertEqual(presentation.statusText, "Needs decision")
    }

    func test_normalize_copilot_awaiting_title_without_hook_resolves_to_needs_input() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Awaiting user response",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
    }

    func test_normalize_copilot_requesting_title_without_hook_resolves_to_needs_input() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Requesting user input",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
    }

    func test_normalize_copilot_title_with_trailing_question_word_resolves_to_needs_input() {
        // Secondary fallback: any title mentioning "question" as a word
        // should trip the matcher, even if the leading verb isn't in the
        // allow-list (e.g. the LLM gets creative with phrasing).
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Posing a clarifying question",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .question)
    }

    func test_normalize_copilot_analyzing_title_without_hook_stays_idle() {
        // Negative case: non-question gerunds must not trip the matcher.
        // Without a hook-driven agentStatus and without the "Asking ..."
        // pattern, Copilot falls through to the OSC-driven idle/running
        // path — here OSC is silent, so the pane is idle.
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Analyzing codebase",
                currentWorkingDirectory: "/tmp/project",
                processName: "copilot",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Copilot",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertNil(presentation.interactionKind)
    }

    func test_normalize_non_copilot_pane_with_asking_title_stays_unaffected() {
        // Negative case: the matcher must only fire for copilot panes.
        // A shell pane whose title happens to start with "Asking" must
        // not be flagged as needs-input.
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Asking the oracle",
                currentWorkingDirectory: "/tmp/project",
                processName: "bash",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "bash",
            raw: raw,
            previous: nil
        )

        XCTAssertNotEqual(presentation.runtimePhase, .needsInput)
        XCTAssertNil(presentation.interactionKind)
    }

    // MARK: - Normalizer branch coverage (Phase 0 golden baseline)
    //
    // These tests close coverage gaps on the cliff-face in
    // `normalizedRuntimePhase(from:recognizedTool:titlePhase:copilotTitleNeedsInput:)`
    // at PaneAuxiliaryState.swift. They lock the default switch cases
    // and the two no-tool fallbacks so the pipeline refactor in Phase 3
    // cannot silently drift.

    func test_normalize_agent_state_unresolved_stop_propagates_to_runtime_phase() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "claude",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .unresolvedStop,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "claude",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .unresolvedStop)
    }

    func test_normalize_unknown_tool_with_osc_progress_resolves_to_running() {
        // No agentStatus + unrecognized tool + active OSC progress
        // exercises the generic fallback at line 484-486 of the normalizer.
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "some-binary running",
                currentWorkingDirectory: "/tmp/project",
                processName: "some-binary",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil),
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .running)
    }

    func test_normalize_no_signals_defaults_to_idle() {
        // No agentStatus, no progress, unrecognized tool, no title phase.
        // Exercises the final default at line 488 of the normalizer.
        let raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: "/tmp/project",
                processName: "bash",
                gitBranch: nil
            ),
            shellContext: nil,
            agentStatus: nil,
            terminalProgress: nil,
            reviewState: nil,
            gitContext: nil
        )

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "bash",
            raw: raw,
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
    }
}
