import XCTest
@testable import Zentty

@MainActor
final class WorkspaceStoreGitContextTests: XCTestCase {
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
        let store = WorkspaceStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)
        let updated = expectation(description: "git context resolved")

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let changedPaneID) = change, changedPaneID == paneID else {
                return
            }

            if store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.presentation.branch == "main" {
                updated.fulfill()
            }
        }
        addTeardownBlock {
            store.unsubscribe(subscription)
        }

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

        let presentation = try XCTUnwrap(store.activeWorkspace?.auxiliaryStateByPaneID[paneID]?.presentation)
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
        let store = WorkspaceStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

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
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let auxiliaryState = try XCTUnwrap(store.activeWorkspace?.auxiliaryStateByPaneID[paneID])
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
        let store = WorkspaceStore(gitContextResolver: resolver)
        let paneID = try XCTUnwrap(store.activeWorkspace?.paneStripState.focusedPaneID)

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
            reviewState: WorkspaceReviewState(
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 42,
                    url: URL(string: "https://example.com/pr/42"),
                    state: .open
                ),
                reviewChips: [WorkspaceReviewChip(text: "Ready", style: .success)]
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                workspaceID: WorkspaceID("workspace-main"),
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

        let auxiliaryState = try XCTUnwrap(store.activeWorkspace?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.gitContext)
        XCTAssertNil(auxiliaryState.reviewState)
        XCTAssertEqual(auxiliaryState.localReviewWorkingDirectory, "/tmp/project")
        XCTAssertEqual(auxiliaryState.presentation.branchDisplayText, "feature/review-band")
        XCTAssertNil(auxiliaryState.presentation.lookupBranch)
        XCTAssertNil(auxiliaryState.presentation.pullRequest)
        XCTAssertEqual(auxiliaryState.presentation.contextText, "feature/review-band · /tmp/project")
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
