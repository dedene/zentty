import Foundation
import XCTest
@testable import Zentty

@MainActor
final class WorklaneReviewStateResolverTests: XCTestCase {
    func test_default_review_command_runner_includes_common_gui_command_locations_in_search_path() {
        let searchPaths = DefaultWorklaneReviewCommandRunner.executableSearchPaths(environment: [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin",
        ])

        XCTAssertTrue(searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(searchPaths.contains("/usr/local/bin"))
        XCTAssertTrue(searchPaths.contains("/Users/tester/.local/bin"))
    }

    func test_default_review_command_runner_resolves_absolute_executable_paths() {
        XCTAssertEqual(
            DefaultWorklaneReviewCommandRunner.resolveExecutablePath(
                for: "/bin/echo",
                environment: [:]
            ),
            "/bin/echo"
        )
    }

    func test_resolver_builds_draft_pull_request_state_with_failing_check_chip() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"},{"status":"COMPLETED","conclusion":"FAILURE"}]}"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "feature/review-band")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])
    }

    func test_resolver_builds_checks_passed_chip_when_all_checks_pass() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":7,"url":"https://example.com/pr/7","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])
    }

    func test_resolver_returns_ready_chip_when_pull_request_is_known_but_checks_are_unavailable() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":8,"url":"https://example.com/pr/8","isDraft":false,"state":"OPEN"}"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Ready"])
    }

    func test_resolver_returns_branch_only_when_gh_reports_no_pull_request() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .failure(stderr: "no pull requests found for branch \"feature/review-band\"")
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "feature/review-band")

        XCTAssertEqual(resolution.reviewState?.branch, "feature/review-band")
        XCTAssertNil(resolution.reviewState?.pullRequest)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), [])
    }

    func test_resolver_hides_github_diagnostics_when_gh_is_unavailable_or_unauthenticated() async {
        let unavailableRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .failure(stderr: "gh: command not found")
        )
        let unavailableResolver = WorklaneReviewStateResolver(runner: unavailableRunner)
        let unavailableResolution = await unavailableResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(unavailableResolution.reviewState)
        XCTAssertEqual(unavailableResolution.updatePolicy, .preserveExistingOnEmpty)

        let authRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .failure(stderr: "To get started with GitHub CLI, please run: gh auth login")
        )
        let authResolver = WorklaneReviewStateResolver(runner: authRunner)
        let authResolution = await authResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(authResolution.reviewState)
        XCTAssertEqual(authResolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_maps_merged_running_and_closed_states_to_expected_chips() async {
        let mergedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":11,"url":"https://example.com/pr/11","isDraft":false,"state":"MERGED"}"#)
        )
        let mergedResolver = WorklaneReviewStateResolver(runner: mergedRunner)
        let mergedResolution = await mergedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(mergedResolution.reviewState?.reviewChips.map(\.text), ["Merged"])

        let runningRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":12,"url":"https://example.com/pr/12","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"IN_PROGRESS"}]}"#)
        )
        let runningResolver = WorklaneReviewStateResolver(runner: runningRunner)
        let runningResolution = await runningResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(runningResolution.reviewState?.reviewChips.map(\.text), ["Running"])

        let closedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":13,"url":"https://example.com/pr/13","isDraft":false,"state":"CLOSED"}"#)
        )
        let closedResolver = WorklaneReviewStateResolver(runner: closedRunner)
        let closedResolution = await closedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(closedResolution.reviewState?.reviewChips.map(\.text), ["Closed"])
    }

    func test_resolver_caches_by_repo_root_and_branch() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-claude"), title: "claude")],
                focusedPaneID: PaneID("pane-claude")
            ),
            metadataByPaneID: [
                PaneID("pane-claude"): TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "feature/review-band"
                ),
            ]
            ,
            gitContextByPaneID: [
                PaneID("pane-claude"): PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("feature/review-band")
                ),
            ]
        )
        _ = await resolver.refreshForTesting(for: [worklane])
        _ = await resolver.refreshForTesting(for: [worklane])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call2.arguments[safe: 2], "view")
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
    }

    func test_resolver_uses_canonical_git_context_before_loading_pr_and_checks() async throws {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"},{"status":"COMPLETED","conclusion":"FAILURE"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "claude")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "feature/review-band"
                ),
            ]
            ,
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("feature/review-band")
                ),
            ]
        )
        let updates = await resolver.refreshForTesting(for: [worklane])
        let resolution = try XCTUnwrap(updates[paneID])

        XCTAssertEqual(resolution.reviewState?.branch, "feature/review-band")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call0.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call1.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(Array(call2.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call2.currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_uses_canonical_repo_root_when_metadata_cwd_is_missing() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: nil,
                    processName: "zsh",
                    gitBranch: "main"
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

        let updates = await resolver.refreshForTesting(for: [worklane])

        XCTAssertEqual(updates[paneID]?.reviewState?.branch, "main")
        XCTAssertEqual(updates[paneID]?.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(updates[paneID]?.reviewState?.reviewChips.map(\.text), ["1 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call0.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call1.currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(call2.arguments.contains("main"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call2.currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_refresh_skips_pane_without_canonical_git_context() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .failure(stderr: "fatal: not a git repository"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
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
        let updates = await resolver.refreshForTesting(for: [worklane])

        XCTAssertEqual(updates.count, 0)

        let calls = await runner.calls
        XCTAssertEqual(calls, [])
    }

    func test_resolver_probes_repository_before_branch_lookup_and_skips_follow_up_for_non_repo() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .stdout("main\n"),
            gitRemoteResult: .stdout("git@github.com:zenjoy/zentty.git\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/non-repo", branch: "main")

        XCTAssertNil(resolution.reviewState)
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
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.branch, "main")
        XCTAssertNil(resolution.reviewState?.pullRequest)
        XCTAssertEqual(resolution.reviewState?.reviewChips, [])

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
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.branch, "main")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4),
            let call5 = requireCall(calls, at: 5)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call3.arguments, ["git", "remote"])
        XCTAssertEqual(call4.arguments, ["git", "remote", "get-url", "fork"])
        XCTAssertEqual(Array(call5.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call5.arguments.contains("--repo"))
        XCTAssertTrue(call5.arguments.contains("dedene/zentty"))
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
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "upstream"])
        XCTAssertFalse(calls.contains { $0.arguments == ["git", "remote", "get-url", "origin"] })
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertTrue(call3.arguments.contains("dedene/zentty"))
    }

    func test_resolver_preserves_existing_state_when_remote_detection_fails_transiently() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .stdout(".git\n"),
            gitBranchResult: .stdout("main\n"),
            gitUpstreamRemoteResult: .failure(stderr: "no upstream remote"),
            gitRemoteListResult: .failure(stderr: "fatal: unable to read remotes"),
            gitRemoteResult: .failure(stderr: "fatal: unable to read config"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(resolution.reviewState)
        XCTAssertEqual(resolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_ignores_compacted_metadata_branch_and_derives_full_branch_from_git() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-shell")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
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
            ,
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                ),
            ]
        )

        let updates = await resolver.refreshForTesting(for: [worklane])

        XCTAssertEqual(updates[paneID]?.reviewState?.branch, "main")
        XCTAssertEqual(updates[paneID]?.reviewState?.pullRequest?.number, 1413)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call2.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call2.arguments.contains("main"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertFalse(call2.arguments.contains("m...n"))
    }

    func test_resolver_reloads_pr_when_branch_changes_in_same_cwd() async {
        let runner = StubGHRunner(
            gitBranchResults: [
                .stdout("feature/review-band\n"),
                .stdout("main\n"),
            ],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}"#),
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
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
            ],
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("feature/review-band")
                ),
            ]
        )
        let branchChangedWorklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
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
            ],
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                ),
            ]
        )

        let firstUpdates = await resolver.refreshForTesting(for: [worklane])
        let secondUpdates = await resolver.refreshForTesting(for: [branchChangedWorklane])
        let updates = [firstUpdates[paneID], secondUpdates[paneID]].compactMap { $0 }

        XCTAssertEqual(updates.map { $0.reviewState?.branch }, ["feature/review-band", "main"])
        XCTAssertEqual(updates.map { $0.reviewState?.pullRequest?.number }, [128, 256])
        XCTAssertEqual(updates.map { $0.reviewState?.reviewChips.map(\.text) ?? [] }, [["Draft", "1 failing"], ["Checks passed"]])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4),
            let call5 = requireCall(calls, at: 5)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call2.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call3.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call4.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call5.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call5.arguments.contains("main"))
        XCTAssertTrue(call5.arguments.contains("--repo"))
    }

    func test_refresh_focused_pane_force_reload_bypasses_cache_for_same_branch() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}"#),
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map(\.text), ["Draft", "1 failing"])

        let refreshedResolution = await resolver.refreshPaneForTesting(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        )

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 256)
        XCTAssertEqual(refreshedResolution?.reviewState?.reviewChips.map(\.text), ["Checks passed"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 5)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call3.arguments.contains("main"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(Array(call4.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call4.arguments.contains("main"))
        XCTAssertTrue(call4.arguments.contains("--repo"))
    }

    func test_refresh_pane_uses_cached_resolution_for_same_repo_and_branch() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)

        let refreshedResolution = await resolver.refreshPaneForTesting(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: false
        )

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 128)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
    }

    func test_refresh_focused_pane_force_reload_preserves_cached_resolution_when_gh_view_fails() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
                .failure(stderr: "network timeout"),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map { $0.text }, ["Checks passed"])

        let refreshedResolution = await resolver.refreshPaneForTesting(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        )

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(refreshedResolution?.reviewState?.reviewChips.map { $0.text }, ["Checks passed"])
        XCTAssertEqual(refreshedResolution?.reviewState?.reviewRefreshFailed, true)
        XCTAssertEqual(refreshedResolution?.updatePolicy, .replace)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 5)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(Array(call4.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call4.arguments.contains("--repo"))
    }

    func test_overlapping_forced_refresh_pane_calls_share_in_flight_fetch() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        await runner.setHoldPRView(true)
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let firstUpdate = expectation(description: "first refreshPane update")
        let secondUpdate = expectation(description: "second refreshPane update")
        var updatedPaneIDs: [PaneID] = []
        var pullRequestNumbers: [Int] = []

        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-one"),
            forceReload: true
        ) { paneID, resolution in
            updatedPaneIDs.append(paneID)
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            firstUpdate.fulfill()
        }
        await runner.waitForPRViewCallCount(1)

        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-two"),
            forceReload: true
        ) { paneID, resolution in
            updatedPaneIDs.append(paneID)
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            secondUpdate.fulfill()
        }

        let callCountBeforeRelease = await runner.prViewCallCount()
        XCTAssertEqual(callCountBeforeRelease, 1)
        await runner.releasePRView()
        await fulfillment(of: [firstUpdate, secondUpdate], timeout: 1)

        XCTAssertEqual(updatedPaneIDs, [PaneID("pane-one"), PaneID("pane-two")])
        XCTAssertEqual(pullRequestNumbers, [128, 128])
        let callCountAfterRelease = await runner.prViewCallCount()
        XCTAssertEqual(callCountAfterRelease, 1)
    }

    func test_forced_refresh_pane_joins_in_flight_batch_refresh_for_same_repository_key() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        await runner.setHoldPRView(true)
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-main")
        let batchUpdate = expectation(description: "batch refresh update")
        let forcedUpdate = expectation(description: "forced refreshPane update")
        let worklane = makeReviewWorklane(paneID: paneID, repoRoot: "/tmp/project", branch: "main")
        var updatedPaneIDs: [PaneID] = []
        var pullRequestNumbers: [Int] = []

        resolver.refresh(for: [worklane]) { paneID, resolution in
            updatedPaneIDs.append(paneID)
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            batchUpdate.fulfill()
        }
        await runner.waitForPRViewCallCount(1)

        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: paneID,
            forceReload: true
        ) { paneID, resolution in
            updatedPaneIDs.append(paneID)
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            forcedUpdate.fulfill()
        }

        let callCountBeforeRelease = await runner.prViewCallCount()
        XCTAssertEqual(callCountBeforeRelease, 1)
        await runner.releasePRView()
        await fulfillment(of: [batchUpdate, forcedUpdate], timeout: 1)

        XCTAssertEqual(updatedPaneIDs, [paneID, paneID])
        XCTAssertEqual(pullRequestNumbers, [256, 256])
        let callCountAfterRelease = await runner.prViewCallCount()
        XCTAssertEqual(callCountAfterRelease, 1)
    }

    func test_forced_refresh_pane_starts_new_fetch_after_previous_forced_refresh_completes() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
                .json(#"{"number":256,"url":"https://example.com/pr/256","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let firstUpdate = expectation(description: "first forced refresh")
        let secondUpdate = expectation(description: "second forced refresh")
        var pullRequestNumbers: [Int] = []

        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        ) { _, resolution in
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            firstUpdate.fulfill()
        }
        await fulfillment(of: [firstUpdate], timeout: 1)
        let callCountAfterFirstRefresh = await runner.prViewCallCount()
        XCTAssertEqual(callCountAfterFirstRefresh, 1)

        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: true
        ) { _, resolution in
            pullRequestNumbers.append(resolution.reviewState?.pullRequest?.number ?? -1)
            secondUpdate.fulfill()
        }
        await fulfillment(of: [secondUpdate], timeout: 1)

        XCTAssertEqual(pullRequestNumbers, [128, 256])
        let callCountAfterSecondRefresh = await runner.prViewCallCount()
        XCTAssertEqual(callCountAfterSecondRefresh, 2)
    }

    // MARK: - Consolidated single gh call

    func test_resolver_makes_single_gh_pr_view_call_with_consolidated_json() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":42,"url":"https://example.com/pr/42","isDraft":false,"state":"OPEN","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        _ = await resolver.resolve(path: "/tmp/project", branch: "main")

        let calls = await runner.calls
        let ghCalls = calls.filter { $0.arguments.first == "gh" }
        XCTAssertEqual(ghCalls.count, 1)
        XCTAssertEqual(Array(ghCalls[0].arguments.prefix(3)), ["gh", "pr", "view"])
        let jsonArg = ghCalls[0].arguments.first(where: { $0.contains("statusCheckRollup") })
        XCTAssertNotNil(jsonArg)
        XCTAssertTrue(jsonArg?.contains("reviewDecision") == true)
        XCTAssertTrue(jsonArg?.contains("mergeable") == true)
        XCTAssertFalse(calls.contains { Array($0.arguments.prefix(3)) == ["gh", "pr", "checks"] })
    }

    // MARK: - Approval chip

    func test_resolver_builds_approval_chip_from_review_decision() async {
        let approvedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1,"url":"https://example.com/pr/1","isDraft":false,"state":"OPEN","reviewDecision":"APPROVED","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let approved = await WorklaneReviewStateResolver(runner: approvedRunner).resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(approved.reviewState?.reviewChips.map(\.text), ["Approved", "Checks passed"])

        let changesRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":2,"url":"https://example.com/pr/2","isDraft":false,"state":"OPEN","reviewDecision":"CHANGES_REQUESTED"}"#)
        )
        let changes = await WorklaneReviewStateResolver(runner: changesRunner).resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(changes.reviewState?.reviewChips.map(\.text), ["Changes requested", "Ready"])

        let reviewRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":3,"url":"https://example.com/pr/3","isDraft":false,"state":"OPEN","reviewDecision":"REVIEW_REQUIRED"}"#)
        )
        let review = await WorklaneReviewStateResolver(runner: reviewRunner).resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(review.reviewState?.reviewChips.map(\.text), ["Review required", "Ready"])
    }

    // MARK: - Conflict chip

    func test_resolver_appends_conflict_chip_when_not_mergeable() async {
        let conflictRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":5,"url":"https://example.com/pr/5","isDraft":false,"state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let conflicting = await WorklaneReviewStateResolver(runner: conflictRunner).resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(conflicting.reviewState?.reviewChips.map(\.text), ["Checks passed", "Conflicts"])

        let cleanRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":6,"url":"https://example.com/pr/6","isDraft":false,"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        )
        let clean = await WorklaneReviewStateResolver(runner: cleanRunner).resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(clean.reviewState?.reviewChips.map(\.text), ["Checks passed"])
    }

    // MARK: - Checks state from statusCheckRollup

    func test_resolver_derives_checks_state_from_status_check_rollup() async {
        let failing = await resolveReviewState(rollup: #"[{"status":"COMPLETED","conclusion":"FAILURE"},{"status":"COMPLETED","conclusion":"SUCCESS"}]"#)
        XCTAssertEqual(failing?.checksState, .failing)
        XCTAssertEqual(failing?.reviewChips.map(\.text), ["1 failing"])

        let running = await resolveReviewState(rollup: #"[{"status":"IN_PROGRESS"}]"#)
        XCTAssertEqual(running?.checksState, .running)
        XCTAssertEqual(running?.reviewChips.map(\.text), ["Running"])

        let passed = await resolveReviewState(rollup: #"[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"SUCCESS"}]"#)
        XCTAssertEqual(passed?.checksState, .passed)
        XCTAssertEqual(passed?.reviewChips.map(\.text), ["Checks passed"])

        // A STALE run is terminal but not green — it must not be reported as "Checks passed".
        let stale = await resolveReviewState(rollup: #"[{"status":"COMPLETED","conclusion":"STALE"},{"status":"COMPLETED","conclusion":"SUCCESS"}]"#)
        XCTAssertEqual(stale?.checksState, .failing)
        XCTAssertEqual(stale?.reviewChips.map(\.text), ["1 failing"])

        let none = await resolveReviewState(rollup: "[]")
        XCTAssertEqual(none?.checksState, WorklaneChecksState.none)
        XCTAssertEqual(none?.reviewChips.map(\.text), ["Ready"])
    }

    private func resolveReviewState(rollup: String) async -> WorklaneReviewState? {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":9,"url":"https://example.com/pr/9","isDraft":false,"state":"OPEN","statusCheckRollup":\#(rollup)}"#)
        )
        return await WorklaneReviewStateResolver(runner: runner).resolve(path: "/tmp/project", branch: "main").reviewState
    }

    // MARK: - Cache TTL

    func test_resolver_refetches_after_cache_ttl_expires() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":1,"url":"https://example.com/pr/1","isDraft":false,"state":"OPEN"}"#),
                .json(#"{"number":2,"url":"https://example.com/pr/2","isDraft":false,"state":"OPEN"}"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner, now: { clock.now })

        let first = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(first.reviewState?.pullRequest?.number, 1)

        clock.advance(by: 30)
        let cached = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(cached.reviewState?.pullRequest?.number, 1)

        clock.advance(by: 120)
        let refetched = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(refetched.reviewState?.pullRequest?.number, 2)

        let viewCalls = await runner.calls.filter { Array($0.arguments.prefix(3)) == ["gh", "pr", "view"] }
        XCTAssertEqual(viewCalls.count, 2)
    }

    // MARK: - Failure visibility

    func test_resolver_flags_refresh_failed_and_preserves_data_on_transient_failure() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":7,"url":"https://example.com/pr/7","isDraft":false,"state":"OPEN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#),
                .failure(stderr: "network timeout"),
                .failure(stderr: "network timeout"),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let good = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(good.reviewState?.pullRequest?.number, 7)
        XCTAssertEqual(good.reviewState?.reviewRefreshFailed, false)

        let failed = await resolver.refreshPaneForTesting(repoRoot: "/tmp/project", branch: "main", paneID: PaneID("p"), forceReload: true)
        XCTAssertEqual(failed?.reviewState?.pullRequest?.number, 7)
        XCTAssertEqual(failed?.reviewState?.reviewChips.map(\.text), ["Checks passed"])
        XCTAssertEqual(failed?.reviewState?.reviewRefreshFailed, true)

        let failedAgain = await resolver.refreshPaneForTesting(repoRoot: "/tmp/project", branch: "main", paneID: PaneID("p"), forceReload: true)
        XCTAssertEqual(failedAgain?.reviewState, failed?.reviewState)
    }

    // MARK: - Adaptive poll interval

    func test_review_poll_interval_adapts_to_state() {
        typealias Polling = WorklaneRenderCoordinator.ReviewPolling
        XCTAssertEqual(Polling.interval(for: nil), Polling.idleInterval)
        XCTAssertEqual(
            Polling.interval(for: WorklaneReviewState(branch: "b", branchURL: nil, pullRequest: nil, reviewChips: [])),
            Polling.noPRInterval
        )
        XCTAssertEqual(Polling.interval(for: pollReviewState(.open, .running)), Polling.activeInterval)
        XCTAssertEqual(Polling.interval(for: pollReviewState(.open, .passed)), Polling.idleInterval)
        XCTAssertEqual(Polling.interval(for: pollReviewState(.draft, .running)), Polling.activeInterval)
        XCTAssertEqual(Polling.interval(for: pollReviewState(.merged, .none)), Polling.terminalInterval)
        XCTAssertEqual(Polling.interval(for: pollReviewState(.closed, .none)), Polling.terminalInterval)
    }

    private func pollReviewState(_ state: WorklanePullRequestState, _ checks: WorklaneChecksState) -> WorklaneReviewState {
        WorklaneReviewState(
            branch: "b",
            branchURL: nil,
            pullRequest: WorklanePullRequestSummary(number: 1, url: nil, state: state),
            reviewChips: [],
            checksState: checks
        )
    }

    // MARK: - Age formatter

    func test_review_age_formatter_boundaries() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base), "just now")
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base.addingTimeInterval(30)), "just now")
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base.addingTimeInterval(60)), "1m ago")
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base.addingTimeInterval(240)), "4m ago")
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base.addingTimeInterval(7200)), "2h ago")
        XCTAssertEqual(ReviewAgeFormatter.string(since: base, now: base.addingTimeInterval(172_800)), "2d ago")
    }
}

private final class TestClock {
    private(set) var now: Date
    init(start: Date) { self.now = start }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func requireCall(
    _ calls: [StubGHRunner.Invocation],
    at index: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) -> StubGHRunner.Invocation? {
    guard calls.indices.contains(index) else {
        XCTFail("Missing command invocation at index \(index); got \(calls.count)", file: file, line: line)
        return nil
    }
    return calls[index]
}

private func makeReviewWorklane(
    paneID: PaneID,
    repoRoot: String,
    branch: String
) -> WorklaneState {
    WorklaneState(
        id: WorklaneID("worklane-main"),
        title: nil,
        paneStripState: PaneStripState(
            panes: [PaneState(id: paneID, title: "shell")],
            focusedPaneID: paneID
        ),
        metadataByPaneID: [
            paneID: TerminalMetadata(
                title: "shell",
                currentWorkingDirectory: repoRoot,
                processName: "zsh",
                gitBranch: branch
            ),
        ],
        gitContextByPaneID: [
            paneID: PaneGitContext(
                workingDirectory: repoRoot,
                repositoryRoot: repoRoot,
                reference: .branch(branch)
            ),
        ]
    )
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private actor StubGHRunner: WorklaneReviewCommandRunning {
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
    private(set) var calls: [Invocation] = []
    private var holdsPRView = false
    private var heldPRViewContinuations: [CheckedContinuation<Void, Never>] = []
    private var prViewCallCountWaiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        gitRepositoryProbeResult: ResultFixture = .stdout(".git\n"),
        gitBranchResult: ResultFixture = .stdout("main\n"),
        gitUpstreamRemoteResult: ResultFixture = .failure(stderr: "no upstream remote"),
        gitRemoteListResult: ResultFixture = .stdout("origin\n"),
        gitRemoteResult: ResultFixture = .stdout("git@github.com:zenjoy/zentty.git\n"),
        additionalGitRemoteResults: [String: [ResultFixture]] = [:],
        prViewResult: ResultFixture = .failure(stderr: "missing prViewResult fixture")
    ) {
        self.gitRepositoryProbeResults = [gitRepositoryProbeResult]
        self.gitBranchResults = [gitBranchResult]
        self.gitUpstreamRemoteResults = [gitUpstreamRemoteResult]
        self.gitRemoteListResults = [gitRemoteListResult]
        self.gitRemoteResults = [gitRemoteResult]
        self.additionalGitRemoteResults = additionalGitRemoteResults
        self.prViewResults = [prViewResult]
    }

    init(
        gitRepositoryProbeResults: [ResultFixture] = [.stdout(".git\n")],
        gitBranchResults: [ResultFixture],
        gitUpstreamRemoteResults: [ResultFixture] = [.failure(stderr: "no upstream remote")],
        gitRemoteListResults: [ResultFixture] = [.stdout("origin\n")],
        gitRemoteResults: [ResultFixture] = [.stdout("git@github.com:zenjoy/zentty.git\n")],
        additionalGitRemoteResults: [String: [ResultFixture]] = [:],
        prViewResults: [ResultFixture]
    ) {
        self.gitRepositoryProbeResults = gitRepositoryProbeResults
        self.gitBranchResults = gitBranchResults
        self.gitUpstreamRemoteResults = gitUpstreamRemoteResults
        self.gitRemoteListResults = gitRemoteListResults
        self.gitRemoteResults = gitRemoteResults
        self.additionalGitRemoteResults = additionalGitRemoteResults
        self.prViewResults = prViewResults
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorklaneReviewCommandResult {
        calls.append(Invocation(arguments: arguments, currentDirectoryPath: currentDirectoryPath))
        resumeSatisfiedPRViewCallCountWaiters()

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
            if holdsPRView {
                await withCheckedContinuation { continuation in
                    heldPRViewContinuations.append(continuation)
                }
            }
            return makeCommandResult(from: nextFixture(in: &prViewResults))
        }

        preconditionFailure("Unexpected gh command: \(arguments.joined(separator: " "))")
    }

    func setHoldPRView(_ hold: Bool) {
        holdsPRView = hold
    }

    func releasePRView() {
        holdsPRView = false
        let continuations = heldPRViewContinuations
        heldPRViewContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForPRViewCallCount(_ expectedCount: Int) async {
        if prViewCallCount() >= expectedCount {
            return
        }

        await withCheckedContinuation { continuation in
            prViewCallCountWaiters.append((expectedCount, continuation))
        }
    }

    func prViewCallCount() -> Int {
        calls.filter { Array($0.arguments.prefix(3)) == ["gh", "pr", "view"] }.count
    }

    private func resumeSatisfiedPRViewCallCountWaiters() {
        let count = prViewCallCount()
        var remaining: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var ready: [CheckedContinuation<Void, Never>] = []

        for waiter in prViewCallCountWaiters {
            if count >= waiter.expectedCount {
                ready.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }

        prViewCallCountWaiters = remaining
        ready.forEach { $0.resume() }
    }

    private func nextFixture(in fixtures: inout [ResultFixture]) -> ResultFixture {
        precondition(!fixtures.isEmpty, "Missing test fixture for command invocation")

        if fixtures.count == 1 {
            return fixtures[0]
        }

        return fixtures.removeFirst()
    }

    private func makeCommandResult(from fixture: ResultFixture) -> WorklaneReviewCommandResult {
        switch fixture {
        case .stdout(let value):
            return WorklaneReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .json(let value):
            return WorklaneReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .failure(let stderr):
            return WorklaneReviewCommandResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(stderr.utf8)
            )
        }
    }
}
