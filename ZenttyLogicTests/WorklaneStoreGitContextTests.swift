import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreGitContextTests: XCTestCase {
    func test_replace_worklanes_resolves_git_context_from_title_derived_working_directory() async throws {
        let homePath = NSHomeDirectory()
        let repoPath = "\(homePath)/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        let resolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                repoPath: PaneGitContext(
                    workingDirectory: repoPath,
                    repositoryRoot: repoPath,
                    reference: .branch("feature/scaleway-transactional-mails")
                )
            ]
        )
        let store = WorklaneStore(gitContextResolver: resolver)
        let paneID = PaneID("pane-shell")
        let updated = expectation(description: "git context resolved from title-derived cwd")

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, _) = change, changedPaneID == paneID else {
                return
            }

            if store.worklanes.first?.auxiliaryStateByPaneID[paneID]?.presentation.branch == "feature/scaleway-transactional-mails" {
                updated.fulfill()
            }
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        store.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        currentWorkingDirectory: nil,
                        processName: "zsh"
                    )
                ]
            )
        ])

        await fulfillment(of: [updated], timeout: 1.0)

        let presentation = try XCTUnwrap(store.worklanes.first?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.cwd, repoPath)
        XCTAssertEqual(presentation.repoRoot, repoPath)
        XCTAssertEqual(presentation.branch, "feature/scaleway-transactional-mails")
    }

    func test_metadata_update_resolves_git_context_from_cwd_and_updates_presentation() async throws {
        let resolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                "/tmp/project": PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                )
            ]
        )
        let store = WorklaneStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let updated = expectation(description: "git context resolved")

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, _) = change, changedPaneID == paneID else {
                return
            }

            if store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.branch == "main" {
                updated.fulfill()
            }
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklane!.id,
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: NSHomeDirectory(),
                    user: NSUserName(),
                    host: nil
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            )
        )

        await fulfillment(of: [updated], timeout: 1.0)

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.repoRoot, "/tmp/project")
        XCTAssertEqual(presentation.branch, "main")
        XCTAssertEqual(presentation.contextText, "main · /tmp/project")
    }

    func test_local_pane_context_repo_change_clears_stale_git_and_review_state_immediately() throws {
        let resolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                "/tmp/project-b": PaneGitContext(
                    workingDirectory: "/tmp/project-b",
                    repositoryRoot: "/tmp/project-b",
                    reference: .branch("feature/review-band")
                )
            ],
            delayNanoseconds: 300_000_000
        )
        let store = WorklaneStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project-a",
                processName: "zsh",
                gitBranch: "main"
            )
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project-a",
                repositoryRoot: "/tmp/project-a",
                reference: .branch("main")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project-b",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp",
                    gitBranch: "feature/review-band"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.gitContext)
        XCTAssertNil(auxiliaryState.reviewState)
        XCTAssertEqual(auxiliaryState.localReviewWorkingDirectory, "/tmp/project-b")
        XCTAssertEqual(auxiliaryState.presentation.branchDisplayText, "feature/review-band")
        XCTAssertNil(auxiliaryState.presentation.lookupBranch)
        XCTAssertNil(auxiliaryState.presentation.pullRequest)
        XCTAssertEqual(auxiliaryState.presentation.contextText, "feature/review-band · /tmp/project-b")
    }

    func test_local_pane_context_branch_change_clears_stale_review_state_before_git_refresh() throws {
        let resolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                "/tmp/project": PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("feature/review-band")
                )
            ],
            delayNanoseconds: 300_000_000
        )
        let store = WorklaneStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )
        store.updateReviewState(
            paneID: paneID,
            reviewState: WorklaneReviewState(
                branch: "main",
                pullRequest: WorklanePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorklaneReviewChip(text: "Ready", style: .success)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp",
                    gitBranch: "feature/review-band"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.gitContext)
        XCTAssertNil(auxiliaryState.reviewState)
        XCTAssertEqual(auxiliaryState.localReviewWorkingDirectory, "/tmp/project")
        XCTAssertEqual(auxiliaryState.presentation.branchDisplayText, "feature/review-band")
        XCTAssertNil(auxiliaryState.presentation.lookupBranch)
        XCTAssertNil(auxiliaryState.presentation.pullRequest)
        XCTAssertEqual(auxiliaryState.presentation.contextText, "feature/review-band · /tmp/project")
    }

    func test_metadata_branch_change_in_same_directory_reloads_git_context() async throws {
        let paneID = PaneID("pane-shell")
        let worklaneID = WorklaneID("worklane-main")
        let resolver = SequencedPaneGitContextResolver(
            resultsByWorkingDirectory: [
                "/tmp/project": [
                    PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("main")
                    ),
                    PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("feature/review-band")
                    ),
                ]
            ]
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: paneID, title: "shell")],
                        focusedPaneID: paneID
                    ),
                    paneContextByPaneID: [
                        paneID: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: NSHomeDirectory(),
                            user: NSUserName(),
                            host: nil
                        ),
                    ]
                ),
            ],
            gitContextResolver: resolver
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )
        try await waitForBranch("main", paneID: paneID, in: store)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "feature/review-band"
            )
        )
        try await waitForBranch("feature/review-band", paneID: paneID, in: store)

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.branch, "feature/review-band")
        XCTAssertEqual(presentation.lookupBranch, "feature/review-band")
    }

    func test_local_pane_context_branch_change_in_same_directory_reloads_git_context() async throws {
        let resolver = SequencedPaneGitContextResolver(
            resultsByWorkingDirectory: [
                "/tmp/project": [
                    PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("main")
                    ),
                    PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("feature/review-band")
                    ),
                ]
            ]
        )
        let store = WorklaneStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp",
                    gitBranch: "main"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        try await waitForBranch("main", paneID: paneID, in: store)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp",
                    gitBranch: "feature/review-band"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        try await waitForBranch("feature/review-band", paneID: paneID, in: store)

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.branch, "feature/review-band")
        XCTAssertEqual(presentation.lookupBranch, "feature/review-band")
    }

    private func waitForBranch(
        _ branch: String,
        paneID: PaneID,
        in store: WorklaneStore
    ) async throws {
        let updated = expectation(description: "branch updated to \(branch)")

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID, _) = change, changedPaneID == paneID else {
                return
            }

            if store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.branch == branch {
                updated.fulfill()
            }
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

        if store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.branch == branch {
            store.unsubscribe(subscription)
            return
        }

        await fulfillment(of: [updated], timeout: 1.0)
        store.unsubscribe(subscription)
    }
}

private struct StubPaneGitContextResolver: PaneGitContextResolving {
    let resultByWorkingDirectory: [String: PaneGitContext]
    var delayNanoseconds: UInt64 = 0

    func resolve(for workingDirectory: String) async -> PaneGitContext {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return resultByWorkingDirectory[workingDirectory]
            ?? PaneGitContext(
                workingDirectory: workingDirectory,
                repositoryRoot: nil,
                reference: nil
            )
    }
}

private struct SequencedPaneGitContextResolver: PaneGitContextResolving {
    let state: SequencedPaneGitContextResolverState

    init(resultsByWorkingDirectory: [String: [PaneGitContext]]) {
        self.state = SequencedPaneGitContextResolverState(resultsByWorkingDirectory: resultsByWorkingDirectory)
    }

    func resolve(for workingDirectory: String) async -> PaneGitContext {
        await state.resolve(for: workingDirectory)
    }
}

private actor SequencedPaneGitContextResolverState {
    private var remainingResultsByWorkingDirectory: [String: [PaneGitContext]]

    init(resultsByWorkingDirectory: [String: [PaneGitContext]]) {
        self.remainingResultsByWorkingDirectory = resultsByWorkingDirectory
    }

    func resolve(for workingDirectory: String) -> PaneGitContext {
        guard var remainingResults = remainingResultsByWorkingDirectory[workingDirectory], !remainingResults.isEmpty else {
            return PaneGitContext(
                workingDirectory: workingDirectory,
                repositoryRoot: nil,
                reference: nil
            )
        }

        let next = remainingResults.removeFirst()
        if remainingResults.isEmpty {
            remainingResultsByWorkingDirectory[workingDirectory] = [next]
        } else {
            remainingResultsByWorkingDirectory[workingDirectory] = remainingResults
        }
        return next
    }
}
