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
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "feature/review-band")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])
    }

    func test_resolver_builds_checks_passed_chip_when_all_checks_pass() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":7,"url":"https://example.com/pr/7","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])
    }

    func test_resolver_returns_ready_chip_when_pull_request_is_known_but_checks_are_unavailable() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":8,"url":"https://example.com/pr/8","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .failure(stderr: "GraphQL: checks unavailable")
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Ready"])
    }

    func test_resolver_returns_branch_only_when_gh_reports_no_pull_request() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .failure(stderr: "no pull requests found for branch \"feature/review-band\""),
            prChecksResult: .json("[]")
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
            prViewResult: .failure(stderr: "gh: command not found"),
            prChecksResult: .json("[]")
        )
        let unavailableResolver = WorklaneReviewStateResolver(runner: unavailableRunner)
        let unavailableResolution = await unavailableResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(unavailableResolution.reviewState)
        XCTAssertEqual(unavailableResolution.updatePolicy, .preserveExistingOnEmpty)

        let authRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .failure(stderr: "To get started with GitHub CLI, please run: gh auth login"),
            prChecksResult: .json("[]")
        )
        let authResolver = WorklaneReviewStateResolver(runner: authRunner)
        let authResolution = await authResolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(authResolution.reviewState)
        XCTAssertEqual(authResolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_maps_merged_running_and_closed_states_to_expected_chips() async {
        let mergedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":11,"url":"https://example.com/pr/11","isDraft":false,"state":"MERGED"}"#),
            prChecksResult: .json("[]")
        )
        let mergedResolver = WorklaneReviewStateResolver(runner: mergedRunner)
        let mergedResolution = await mergedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(mergedResolution.reviewState?.reviewChips.map(\.text), ["Merged"])

        let runningRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":12,"url":"https://example.com/pr/12","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pending","state":"IN_PROGRESS","name":"lint"}]"#)
        )
        let runningResolver = WorklaneReviewStateResolver(runner: runningRunner)
        let runningResolution = await runningResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(runningResolution.reviewState?.reviewChips.map(\.text), ["Running"])

        let closedRunner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":13,"url":"https://example.com/pr/13","isDraft":false,"state":"CLOSED"}"#),
            prChecksResult: .json("[]")
        )
        let closedResolver = WorklaneReviewStateResolver(runner: closedRunner)
        let closedResolution = await closedResolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(closedResolution.reviewState?.reviewChips.map(\.text), ["Closed"])
    }

    func test_resolver_caches_by_repo_root_and_branch() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )

        let resolver = WorklaneReviewStateResolver(runner: runner)
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
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
        let firstRefresh = expectation(description: "first refresh")
        resolver.refresh(for: [worklane]) { _, _ in
            firstRefresh.fulfill()
        }
        await fulfillment(of: [firstRefresh], timeout: 1.0)

        let secondRefresh = expectation(description: "second refresh")
        resolver.refresh(for: [worklane]) { _, _ in
            secondRefresh.fulfill()
        }
        await fulfillment(of: [secondRefresh], timeout: 1.0)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call2.arguments[safe: 2], "view")
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call3.arguments[safe: 2], "checks")
        XCTAssertTrue(call3.arguments.contains("feature/review-band"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
    }

    func test_resolver_uses_canonical_git_context_before_loading_pr_and_checks() async throws {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
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
        var updates: [WorklaneReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [worklane]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)
        let resolution = try XCTUnwrap(updates.last)

        XCTAssertEqual(resolution.reviewState?.branch, "feature/review-band")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.state, .draft)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call0.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call1.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(Array(call2.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call2.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "checks"])
        XCTAssertTrue(call3.arguments.contains("feature/review-band"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(call3.currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_uses_canonical_repo_root_when_metadata_cwd_is_missing() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
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

        var updates: [WorklaneReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [worklane]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(updates.last?.reviewState?.branch, "main")
        XCTAssertEqual(updates.last?.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(updates.last?.reviewState?.reviewChips.map(\.text), ["1 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call0.currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call1.currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(call2.arguments.contains("main"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertEqual(call2.currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(call3.arguments.contains("main"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(call3.currentDirectoryPath, "/tmp/project")
    }

    func test_resolver_refresh_skips_pane_without_canonical_git_context() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .failure(stderr: "fatal: not a git repository"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
        var updates: [WorklaneReviewResolution] = []
        resolver.refresh(for: [worklane]) { _, resolution in
            updates.append(resolution)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(updates.count, 0)

        let calls = await runner.calls
        XCTAssertEqual(calls, [])
    }

    func test_resolver_probes_repository_before_branch_lookup_and_skips_follow_up_for_non_repo() async {
        let runner = StubGHRunner(
            gitRepositoryProbeResult: .failure(stderr: "fatal: not a git repository"),
            gitBranchResult: .stdout("main\n"),
            gitRemoteResult: .stdout("git@github.com:zenjoy/zentty.git\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
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
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
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
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.branch, "main")
        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)
        XCTAssertEqual(resolution.reviewState?.reviewChips.map(\.text), ["Checks passed"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4),
            let call5 = requireCall(calls, at: 5),
            let call6 = requireCall(calls, at: 6)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(call3.arguments, ["git", "remote"])
        XCTAssertEqual(call4.arguments, ["git", "remote", "get-url", "fork"])
        XCTAssertTrue(call5.arguments.contains("--repo"))
        XCTAssertTrue(call5.arguments.contains("dedene/zentty"))
        XCTAssertTrue(call6.arguments.contains("--repo"))
        XCTAssertTrue(call6.arguments.contains("dedene/zentty"))
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
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertEqual(resolution.reviewState?.pullRequest?.number, 1413)

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
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "upstream"])
        XCTAssertFalse(calls.contains { $0.arguments == ["git", "remote", "get-url", "origin"] })
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertTrue(call3.arguments.contains("dedene/zentty"))
        XCTAssertTrue(call4.arguments.contains("--repo"))
        XCTAssertTrue(call4.arguments.contains("dedene/zentty"))
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
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let resolution = await resolver.resolve(path: "/tmp/project", branch: "main")

        XCTAssertNil(resolution.reviewState)
        XCTAssertEqual(resolution.updatePolicy, .preserveExistingOnEmpty)
    }

    func test_resolver_ignores_compacted_metadata_branch_and_derives_full_branch_from_git() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)
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

        var updates: [WorklaneReviewResolution] = []
        let refreshExpectation = expectation(description: "refresh update")
        resolver.refresh(for: [worklane]) { _, resolution in
            updates.append(resolution)
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(updates.last?.reviewState?.branch, "main")
        XCTAssertEqual(updates.last?.reviewState?.pullRequest?.number, 1413)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(call2.arguments.contains("main"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertFalse(call2.arguments.contains("m...n"))
        XCTAssertTrue(call3.arguments.contains("main"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
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
        let resolver = WorklaneReviewStateResolver(runner: runner)
        let paneID = PaneID("pane-claude")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
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
            ],
            gitContextByPaneID: [
                paneID: PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                ),
            ]
        )

        var updates: [WorklaneReviewResolution] = []
        let firstRefresh = expectation(description: "first refresh")
        resolver.refresh(for: [worklane]) { _, resolution in
            updates.append(resolution)
            firstRefresh.fulfill()
        }
        await fulfillment(of: [firstRefresh], timeout: 1.0)

        let secondRefresh = expectation(description: "second refresh")
        resolver.refresh(for: [branchChangedWorklane]) { _, resolution in
            updates.append(resolution)
            secondRefresh.fulfill()
        }
        await fulfillment(of: [secondRefresh], timeout: 1.0)

        XCTAssertEqual(updates.map { $0.reviewState?.branch }, ["feature/review-band", "main"])
        XCTAssertEqual(updates.map { $0.reviewState?.pullRequest?.number }, [128, 256])
        XCTAssertEqual(updates.map { $0.reviewState?.reviewChips.map(\.text) ?? [] }, [["Draft", "1 failing"], ["Checks passed"]])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 8)
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4),
            let call5 = requireCall(calls, at: 5),
            let call6 = requireCall(calls, at: 6),
            let call7 = requireCall(calls, at: 7)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(call1.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(call2.arguments.contains("feature/review-band"))
        XCTAssertTrue(call2.arguments.contains("--repo"))
        XCTAssertTrue(call3.arguments.contains("feature/review-band"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(call4.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call5.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(call6.arguments.contains("main"))
        XCTAssertTrue(call6.arguments.contains("--repo"))
        XCTAssertTrue(call7.arguments.contains("main"))
        XCTAssertTrue(call7.arguments.contains("--repo"))
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
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map(\.text), ["Draft", "1 failing"])

        var refreshedResolution: WorklaneReviewResolution?
        let refreshExpectation = expectation(description: "forced refresh update")
        resolver.refreshFocusedPane(
            repoRoot: "/tmp/project",
            branch: "main",
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
        guard
            let call0 = requireCall(calls, at: 0),
            let call1 = requireCall(calls, at: 1),
            let call2 = requireCall(calls, at: 2),
            let call3 = requireCall(calls, at: 3),
            let call4 = requireCall(calls, at: 4),
            let call5 = requireCall(calls, at: 5),
            let call6 = requireCall(calls, at: 6)
        else { return }
        XCTAssertEqual(call0.arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(call1.arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(call2.arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call3.arguments.contains("main"))
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(Array(call4.arguments.prefix(3)), ["gh", "pr", "checks"])
        XCTAssertTrue(call4.arguments.contains("main"))
        XCTAssertTrue(call4.arguments.contains("--repo"))
        XCTAssertEqual(Array(call5.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call5.arguments.contains("main"))
        XCTAssertTrue(call5.arguments.contains("--repo"))
        XCTAssertEqual(Array(call6.arguments.prefix(3)), ["gh", "pr", "checks"])
        XCTAssertTrue(call6.arguments.contains("main"))
        XCTAssertTrue(call6.arguments.contains("--repo"))
    }

    func test_refresh_pane_uses_cached_resolution_for_same_repo_and_branch() async {
        let runner = StubGHRunner(
            gitBranchResults: [.stdout("main\n")],
            prViewResults: [
                .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":false,"state":"OPEN"}"#),
            ],
            prChecksResults: [
                .json(#"[{"bucket":"pass","state":"SUCCESS","name":"unit-tests"}]"#),
            ]
        )
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)

        var refreshedResolution: WorklaneReviewResolution?
        let refreshExpectation = expectation(description: "cached refresh update")
        resolver.refreshPane(
            repoRoot: "/tmp/project",
            branch: "main",
            paneID: PaneID("pane-main"),
            forceReload: false
        ) { _, resolution in
            refreshedResolution = resolution
            refreshExpectation.fulfill()
        }
        await fulfillment(of: [refreshExpectation], timeout: 1.0)

        XCTAssertEqual(refreshedResolution?.reviewState?.pullRequest?.number, 128)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 5)
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
        let resolver = WorklaneReviewStateResolver(runner: runner)

        let initialResolution = await resolver.resolve(path: "/tmp/project", branch: "main")
        XCTAssertEqual(initialResolution.reviewState?.pullRequest?.number, 128)
        XCTAssertEqual(initialResolution.reviewState?.reviewChips.map { $0.text }, ["Checks passed"])

        var refreshedResolution: WorklaneReviewResolution?
        let refreshExpectation = expectation(description: "forced refresh keeps cache")
        resolver.refreshFocusedPane(
            repoRoot: "/tmp/project",
            branch: "main",
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
        XCTAssertEqual(Array(call3.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call3.arguments.contains("--repo"))
        XCTAssertEqual(Array(call4.arguments.prefix(3)), ["gh", "pr", "checks"])
        XCTAssertTrue(call4.arguments.contains("--repo"))
        XCTAssertEqual(Array(call5.arguments.prefix(3)), ["gh", "pr", "view"])
        XCTAssertTrue(call5.arguments.contains("--repo"))
    }
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

    func run(arguments: [String], currentDirectoryPath: String) async -> WorklaneReviewCommandResult {
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
