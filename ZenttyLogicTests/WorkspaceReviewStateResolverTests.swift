import Foundation
import XCTest
@testable import Zentty

@MainActor
final class WorkspaceReviewStateResolverTests: XCTestCase {
    func test_default_review_command_runner_includes_common_gui_command_locations_in_search_path() {
        let searchPaths = DefaultWorkspaceReviewCommandRunner.executableSearchPaths(environment: [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin",
        ])

        XCTAssertTrue(searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(searchPaths.contains("/usr/local/bin"))
        XCTAssertTrue(searchPaths.contains("/Users/tester/.local/bin"))
    }

    func test_default_review_command_runner_resolves_absolute_executable_paths() {
        XCTAssertEqual(
            DefaultWorkspaceReviewCommandRunner.resolveExecutablePath(
                for: "/bin/echo",
                environment: [:]
            ),
            "/bin/echo"
        )
    }

    func test_resolver_builds_draft_pull_request_state_with_failing_check_chip() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )

        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "feature/review-band")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])
        XCTAssertEqual(resolution.inferredArtifact?.label, "PR #128")
    }

    func test_resolver_builds_checks_passed_chip_when_all_checks_pass() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":7,"url":"https://example.com/pr/7","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )

        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])
    }

    func test_resolver_returns_ready_chip_when_pull_request_is_known_but_checks_are_unavailable() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":8,"url":"https://example.com/pr/8","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .failure(stderr: "GraphQL: checks unavailable")
        )

        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Ready"])
    }

    func test_resolver_returns_branch_only_when_gh_reports_no_pull_request() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .failure(stderr: "no pull requests found for branch \"feature/review-band\""),
            prChecksResult: .json("[]")
        )

        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "feature/review-band")

        XCTAssertEqual(resolution.reviewState?.branch, "feature/review-band")
        XCTAssertNil(resolution.reviewState?.pullRequest)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), [])
        XCTAssertNil(resolution.inferredArtifact)
    }

    func test_resolver_hides_github_diagnostics_when_gh_is_unavailable_or_unauthenticated() async {
        let unavailableRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .failure(stderr: "gh: command not found"),
            prChecksResult: .json("[]")
        )
        let unavailableResolver = WorkspaceReviewStateResolver(runner: unavailableRunner)
        let unavailableResolution = await unavailableResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(unavailableResolution.reviewState)
        XCTAssertNil(unavailableResolution.inferredArtifact)
        XCTAssertEqual(unavailableResolution.updatePolicy, .preserveExistingOnEmpty)

        let authRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .failure(stderr: "To get started with GitHub CLI, please run: gh auth login"),
            prChecksResult: .json("[]")
        )
        let authResolver = WorkspaceReviewStateResolver(runner: authRunner)
        let authResolution = await authResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(authResolution.reviewState)
        XCTAssertNil(authResolution.inferredArtifact)
        XCTAssertEqual(authResolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_maps_merged_running_and_closed_states_to_expected_chips() async {
        let mergedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":11,"url":"https://example.com/pr/11","isDraft":false,"state":"MERGED"}"#),
            prChecksResult: .json("[]")
        )
        let mergedResolver = WorkspaceReviewStateResolver(runner: mergedRunner)
        let mergedResolution = await mergedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(mergedResolution.reviewState?.reviewChips.map(\.text), ["Merged"])

        let runningRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":12,"url":"https://example.com/pr/12","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pending","state":"IN_PROGRESS","name":"lint"}]"#)
        )
        let runningResolver = WorkspaceReviewStateResolver(runner: runningRunner)
        let runningResolution = await runningResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(runningResolution.reviewState?.reviewChips.map(\.text), ["Running"])

        let closedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":13,"url":"https://example.com/pr/13","isDraft":false,"state":"CLOSED"}"#),
            prChecksResult: .json("[]")
        )
        let closedResolver = WorkspaceReviewStateResolver(runner: closedRunner)
        let closedResolution = await closedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(closedResolution.reviewState?.reviewChips.map(\.text), ["Closed"])
    }

    func test_resolver_caches_by_path_and_branch() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )

        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-claude"), title: "claude")],
                focusedPaneID: PaneID("pane-claude")
            ),
            metadataByPaneID: [
                PaneID("pane-claude"): TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude"
                ),
            ]
        )
        let firstRefresh = expectation(description: "first refresh")
        resolver.refresh(for: [workspace]) { _, _ in
            firstRefresh.fulfill()
        }
        await fulfillment(of: [firstRefresh], timeout: 1.0)

        let secondRefresh = expectation(description: "second refresh")
        resolver.refresh(for: [workspace]) { _, _ in
            secondRefresh.fulfill()
        }
        await fulfillment(of: [secondRefresh], timeout: 1.0)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[4].arguments[2], "view")
        XCTAssertTrue(calls[4].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertEqual(calls[5].arguments[2], "checks")
        XCTAssertTrue(calls[5].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertEqual(calls[6].arguments, ["git", "branch", "--show-current"])
    }

    func test_resolver_derives_branch_from_git_before_loading_pr_and_checks() async throws {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "claude")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude"
                ),
            ]
        )
        var updates: [WorkspaceReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)
        let resolution = try XCTUnwrap(updates.last)

        XCTAssertEqual(resolution.reviewState?.branch, "feature/review-band")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(calls[2].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[4].arguments[0...2], ["gh", "pr", "view"])
        XCTAssertTrue(calls[4].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertEqual(calls[4].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[5].arguments[0...2], ["gh", "pr", "checks"])
        XCTAssertTrue(calls[5].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertEqual(calls[5].currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_uses_local_pane_context_path_when_metadata_cwd_is_missing() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-shell")
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
                    currentWorkingDirectory: nil,
                    processName: "zsh"
                ),
            ],
            paneContextByPaneID: [
                paneID: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "m1-pro-peter"
                ),
            ]
        )

        var updates: [WorkspaceReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(updates.last?.reviewState?.branch, "main")
        XCTAssertEqual(updates.last?.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(updates.last?.reviewState?.reviewChips.map(\.text), ["1 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[4].arguments.contains("main"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertEqual(calls[4].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[5].arguments.contains("main"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertEqual(calls[5].currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_returns_nil_when_git_branch_lookup_fails() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .failure(stderr: "fatal: not a git repository"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-claude"), title: "claude")],
                focusedPaneID: PaneID("pane-claude")
            ),
            metadataByPaneID: [
                PaneID("pane-claude"): TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude"
                ),
            ]
        )
        var updates: [WorkspaceReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(updates.count, 1)
        XCTAssertNil(updates[0].reviewState)
        XCTAssertNil(updates[0].inferredArtifact)

        let calls = await runner.calls
        XCTAssertEqual(calls, [
            .init(arguments: ["git", "rev-parse", "--git-dir"], currentDirectoryPath: "/tmp/project"),
        ])
    }

    func test_resolver_probes_repository_before_branch_lookup_and_skips_follow_up_for_non_repo() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .stdout("main\n"),
            gitRemoteResult: .stdout("git@github.com:zenjoy/zentty.git\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/non-repo", branch: "main")

        XCTAssertNil(resolution.reviewState)
        XCTAssertNil(resolution.inferredArtifact)
        XCTAssertEqual(resolution.updatePolicy, .preserveExistingOnEmpty)

        let calls = await runner.calls
        XCTAssertEqual(calls, [
            .init(arguments: ["git", "rev-parse", "--git-dir"], currentDirectoryPath: "/tmp/non-repo"),
        ])
    }

    func test_resolver_skips_github_commands_when_origin_is_not_github() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .stdout(".git\n"),
            gitBranchResult: .stdout("main\n"),
            gitRemoteResult: .stdout("git@gitlab.com:zenjoy/zentty.git\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.branch, "main")
        XCTAssertNil(resolution.reviewState?.pullRequest)
        XCTAssertEqual(resolution.reviewState?.reviewChips, [])
        XCTAssertNil(resolution.inferredArtifact)

        let calls = await runner.calls
        XCTAssertEqual(calls, [
            .init(arguments: ["git", "rev-parse", "--git-dir"], currentDirectoryPath: "/tmp/project"),
            .init(arguments: ["git", "config", "--get", "branch.main.remote"], currentDirectoryPath: "/tmp/project"),
            .init(arguments: ["git", "remote", "get-url", "origin"], currentDirectoryPath: "/tmp/project"),
            .init(arguments: ["git", "remote"], currentDirectoryPath: "/tmp/project"),
        ])
    }

    func test_resolver_uses_non_origin_github_remote_when_origin_is_not_github() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .stdout(".git\n"),
            gitBranchResult: .stdout("main\n"),
            gitUpstreamRemoteResult: .failure(stderr: "no upstream remote"),
            gitRemoteListResult: .stdout("origin\nfork\n"),
            gitRemoteResult: .stdout("git@gitlab.com:zenjoy/zentty.git\n"),
            additionalGitRemoteResults: [
                "fork": [.stdout("git@github.com:dedene/zentty.git\n")],
            ],
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.branch, "main")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])
        XCTAssertEqual(resolution.inferredArtifact?.label, "PR #1413")

        let calls = await runner.calls
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].arguments, ["git", "remote"])
        XCTAssertEqual(calls[4].arguments, ["git", "remote", "get-url", "fork"])
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertTrue(calls[5].arguments.contains("dedene/zentty"))
        XCTAssertTrue(calls[6].arguments.contains("--repo"))
        XCTAssertTrue(calls[6].arguments.contains("dedene/zentty"))
    }

    func test_resolver_prefers_upstream_github_remote_before_origin() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .stdout(".git\n"),
            gitBranchResult: .stdout("main\n"),
            gitUpstreamRemoteResult: .stdout("upstream\n"),
            gitRemoteResult: .stdout("git@github.com:zenjoy/zentty.git\n"),
            additionalGitRemoteResults: [
                "upstream": [.stdout("git@github.com:dedene/zentty.git\n")],
            ],
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)

        let calls = await runner.calls
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].arguments, ["git", "remote", "get-url", "upstream"])
        XCTAssertFalse(calls.contains { $0.arguments == ["git", "remote", "get-url", "origin"] })
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertTrue(calls[3].arguments.contains("dedene/zentty"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertTrue(calls[4].arguments.contains("dedene/zentty"))
    }

    func test_resolver_preserves_existing_state_when_remote_detection_fails_transiently() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .stdout(".git\n"),
            gitBranchResult: .stdout("main\n"),
            gitUpstreamRemoteResult: .failure(stderr: "no upstream remote"),
            gitRemoteListResult: .failure(stderr: "fatal: unable to read remotes"),
            gitRemoteResult: .failure(stderr: "fatal: unable to read config"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(resolution.reviewState)
        XCTAssertNil(resolution.inferredArtifact)
        XCTAssertEqual(resolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_ignores_compacted_metadata_branch_and_derives_full_branch_from_git() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-shell")
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
                    currentWorkingDirectory: "/tmp/project",
                    processName: "zsh",
                    gitBranch: "m...n"
                ),
            ]
        )

        var updates: [WorkspaceReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(updates.last?.reviewState?.branch, "main")
        XCTAssertEqual(updates.last?.reviewState?.pullRequest?.number, 1413)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(calls[4].arguments.contains("main"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertFalse(calls[4].arguments.contains("m...n"))
        XCTAssertTrue(calls[5].arguments.contains("main"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
    }

    func test_resolver_reloads_pr_when_branch_changes_in_same_cwd() async {
        let runner = StubGHRunner(
            gitBranchResults: [
                .stdout("feature/review-band\n"),
                .stdout("main\n"),
            ],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN"}"#),
            ],
            prChecksResults: [
                .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"}]"#),
                .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#),
            ]
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "claude")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude"
                ),
            ]
        )

        var updates: [WorkspaceReviewResolution] = []
        let firstRefresh = expectation(description: "first refresh")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            firstRefresh.fulfill()
        }
        await fulfillment(of: [firstRefresh], timeout: 1.0)

        let secondRefresh = expectation(description: "second refresh")
        resolver.refresh(for: [workspace]) { _, resolution in
            updates.append(resolution)
            secondRefresh.fulfill()
        }
        await fulfillment(of: [secondRefresh], timeout: 1.0)

        XCTAssertEqual(updates.map { $0.reviewState?.branch }, ["feature/review-band", "main"])
        XCTAssertEqual(updates.map { $0.reviewState?.pullRequest?.number }, [128, 256])
        XCTAssertEqual(updates.map { $0.reviewState?.reviewChips.map(\.text) ?? [] }, [["Draft", "1 failing"], ["Checks passed"]])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 11)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(calls[4].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertTrue(calls[5].arguments.contains("feature/review-band"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertEqual(calls[6].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[7].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[8].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(calls[9].arguments.contains("main"))
        XCTAssertTrue(calls[9].arguments.contains("--repo"))
        XCTAssertTrue(calls[10].arguments.contains("main"))
        XCTAssertTrue(calls[10].arguments.contains("--repo"))
    }

    func test_refresh_focused_pane_force_reload_bypasses_cache_for_same_branch() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN"}"#),
            ],
            prChecksResults: [
                .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"}]"#),
                .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#),
            ]
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map(\.text), ["Draft", "1 failing"])

        var refreshedResolution: WorkspaceReviewResolution?
        let refreshExpectation = expectation(description: "forced refresh update")
        resolver.refreshFocusedPane(
            path: "/tmp/project",
            preferredBranch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        ) { _, resolution in
            refreshedResolution = resolution
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 256)
        XCTAssertEqual(refreshedResolution?.reviewState?.reviewChips.map(\.text), ["Checks passed"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].arguments[0...2], ["gh", "pr", "view"])
        XCTAssertTrue(calls[3].arguments.contains("main"))
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertEqual(calls[4].arguments[0...2], ["gh", "pr", "checks"])
        XCTAssertTrue(calls[4].arguments.contains("main"))
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertEqual(calls[5].arguments[0...2], ["gh", "pr", "view"])
        XCTAssertTrue(calls[5].arguments.contains("main"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
        XCTAssertEqual(calls[6].arguments[0...2], ["gh", "pr", "checks"])
        XCTAssertTrue(calls[6].arguments.contains("main"))
        XCTAssertTrue(calls[6].arguments.contains("--repo"))
    }

    func test_refresh_focused_pane_force_reload_preserves_cached_resolution_when_gh_view_fails() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
                .failure(stderr: "network timeout"),
            ],
            prChecksResults: [
                .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#),
                .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#),
            ]
        )
        let resolver = WorkspaceReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map { $0.text }, ["Checks passed"])

        var refreshedResolution: WorkspaceReviewResolution?
        let refreshExpectation = expectation(description: "forced refresh keeps cache")
        resolver.refreshFocusedPane(
            path: "/tmp/project",
            preferredBranch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        ) { _, resolution in
            refreshedResolution = resolution
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(refreshedResolution?.reviewState?.reviewChips.map { $0.text }, ["Checks passed"])
        XCTAssertEqual(refreshedResolution?.updatePolicy, .replace)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[1].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].arguments[0...2], ["gh", "pr", "view"])
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertEqual(calls[4].arguments[0...2], ["gh", "pr", "checks"])
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertEqual(calls[5].arguments[0...2], ["gh", "pr", "view"])
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
    }
}

private actor StubGHRunner: WorkspaceReviewCommandRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let currentDirectoryPath: String
    }

    enum ResultFixture {
        case stdout(String)
        case json(String)
        case failure(stderr: String)
    }

    private var gitRepositoryProbeResults: [ResultFixture]
    private var gitBranchResults: [ResultFixture]
    private var gitUpstreamRemoteResults: [ResultFixture]
    private var gitRemoteListResults: [ResultFixture]
    private var gitRemoteResults: [ResultFixture]
    private var additionalGitRemoteResults: [String: [ResultFixture]]
    private var prViewResults: [ResultFixture]
    private var prChecksResults: [ResultFixture]
    private(set) var calls: [Invocation] = []

    init(
        gitRepositoryProbeResult: ResultFixture = .stdout(".git\n"),
        gitBranchResult: ResultFixture = .stdout("main\n"),
        gitUpstreamRemoteResult: ResultFixture = .failure(stderr: "no upstream remote"),
        gitRemoteListResult: ResultFixture = .stdout("origin\n"),
        gitRemoteResult: ResultFixture = .stdout("git@github.com:zenjoy/zentty.git\n"),
        additionalGitRemoteResults: [String: [ResultFixture]] = [:],
        prViewResult: ResultFixture = .failure(stderr: "missing prViewResult fixture"),
        prChecksResult: ResultFixture = .failure(stderr: "missing prChecksResult fixture")
    ) {
        self.gitRepositoryProbeResults = [gitRepositoryProbeResult]
        self.gitBranchResults = [gitBranchResult]
        self.gitUpstreamRemoteResults = [gitUpstreamRemoteResult]
        self.gitRemoteListResults = [gitRemoteListResult]
        self.gitRemoteResults = [gitRemoteResult]
        self.additionalGitRemoteResults = additionalGitRemoteResults
        self.prViewResults = [prViewResult]
        self.prChecksResults = [prChecksResult]
    }

    init(
        gitRepositoryProbeResults: [ResultFixture] = [.stdout(".git\n")],
        gitBranchResults: [ResultFixture],
        gitUpstreamRemoteResults: [ResultFixture] = [.failure(stderr: "no upstream remote")],
        gitRemoteListResults: [ResultFixture] = [.stdout("origin\n")],
        gitRemoteResults: [ResultFixture] = [.stdout("git@github.com:zenjoy/zentty.git\n")],
        additionalGitRemoteResults: [String: [ResultFixture]] = [:],
        prViewResults: [ResultFixture],
        prChecksResults: [ResultFixture]
    ) {
        self.gitRepositoryProbeResults = gitRepositoryProbeResults
        self.gitBranchResults = gitBranchResults
        self.gitUpstreamRemoteResults = gitUpstreamRemoteResults
        self.gitRemoteListResults = gitRemoteListResults
        self.gitRemoteResults = gitRemoteResults
        self.additionalGitRemoteResults = additionalGitRemoteResults
        self.prViewResults = prViewResults
        self.prChecksResults = prChecksResults
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult {
        calls.append(Invocation(arguments: arguments, currentDirectoryPath: currentDirectoryPath))

        if arguments == ["git", "rev-parse", "--git-dir"] {
            return makeCommandResult(from: nextFixture(in: &gitRepositoryProbeResults))
        }

        if arguments == ["git", "branch", "--show-current"] {
            return makeCommandResult(from: nextFixture(in: &gitBranchResults))
        }

        if arguments.count == 4,
           arguments[0] == "git",
           arguments[1] == "config",
           arguments[2] == "--get",
           arguments[3].hasPrefix("branch."),
           arguments[3].hasSuffix(".remote") {
            return makeCommandResult(from: nextFixture(in: &gitUpstreamRemoteResults))
        }

        if arguments == ["git", "remote"] {
            return makeCommandResult(from: nextFixture(in: &gitRemoteListResults))
        }

        if arguments == ["git", "remote", "get-url", "origin"] {
            return makeCommandResult(from: nextFixture(in: &gitRemoteResults))
        }

        if arguments.count == 4,
           arguments[0] == "git",
           arguments[1] == "remote",
           arguments[2] == "get-url" {
            var fixtures = additionalGitRemoteResults[arguments[3], default: []]
            let fixture = nextFixture(in: &fixtures)
            additionalGitRemoteResults[arguments[3]] = fixtures
            return makeCommandResult(from: fixture)
        }

        if arguments.contains("view") {
            return makeCommandResult(from: nextFixture(in: &prViewResults))
        }

        return makeCommandResult(from: nextFixture(in: &prChecksResults))
    }

    private func nextFixture(in fixtures: inout [ResultFixture]) -> ResultFixture {
        precondition(!fixtures.isEmpty, "Missing test fixture for command invocation")

        if fixtures.count == 1 {
            return fixtures[0]
        }

        return fixtures.removeFirst()
    }

    private func makeCommandResult(from fixture: ResultFixture) -> WorkspaceReviewCommandResult {
        switch fixture {
        case .stdout(let value):
            return WorkspaceReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .json(let value):
            return WorkspaceReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .failure(let stderr):
            return WorkspaceReviewCommandResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(stderr.utf8)
            )
        }
    }
}
