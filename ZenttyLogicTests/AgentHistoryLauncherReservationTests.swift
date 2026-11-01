import XCTest
@testable import Zentty

/// While `git worktree add` runs, its folder already exists, so the folder resolver would call a
/// session inside it ready. The launcher reserves the worktree path from the start of recreation
/// until the launch, so no second History resume or recreation lands in an unfinished checkout.
extension AgentHistoryLauncherTests {
    func test_second_recreation_of_the_same_worktree_is_refused_while_the_first_runs() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let creator = HeldWorktreeCreator()
        let launcher = makeLauncher(hosts: [host], presenting: host, creator: creator)
        let recreation = worktreeRecreation()

        let first = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(recreation))
        let second = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .secondary, folderChoice: .recreateWorktree(recreation))

        XCTAssertEqual(first, .recreatingWorktree)
        XCTAssertEqual(
            second,
            .failed(message: AgentHistoryLauncher.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        )
        XCTAssertEqual(creator.pendingCount, 1, "git ran once")
    }

    func test_resume_inside_a_worktree_being_recreated_waits_for_the_recreation() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let creator = HeldWorktreeCreator()
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(
            hosts: [host], presenting: host, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let recreation = worktreeRecreation()
        let session = worktreeSource(endedSessionID, rowID: 8)

        XCTAssertEqual(
            launcher.resume(session, intent: .primary, folderChoice: .recreateWorktree(recreation)),
            .recreatingWorktree
        )
        // git has made the folder but is still checking out (or running a slow hook).
        fileSystem.makeDirectory(recreation.resumeDirectory)

        XCTAssertEqual(
            launcher.perform(.primary, source: worktreeSource(endedSessionID, rowID: 9)),
            .failed(message: AgentHistoryLauncher.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        )
        XCTAssertEqual(
            launcher.resume(
                worktreeSource(endedSessionID, rowID: 9),
                intent: .primary,
                folderChoice: .repositoryRoot(recreation.worktreePath)
            ),
            .failed(message: AgentHistoryLauncher.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        )
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1, "nothing launched into the unfinished checkout")

        let handled = expectation(description: "recreation handled")
        creator.finish(with: .success(()), handled: handled)
        wait(for: [handled], timeout: 2)

        XCTAssertEqual(host.worklaneStore.worklanes.count, 2)
        XCTAssertEqual(recorder.opens.map(\.rowID), [8])
        // The worktree reservation ends with the launch.
        guard case .resumed = launcher.perform(.primary, source: worktreeSource(otherEndedSessionID, rowID: 9)) else {
            return XCTFail("the finished worktree resumes normally")
        }
    }

    func test_failed_recreation_releases_the_worktree() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let creator = HeldWorktreeCreator()
        let launcher = makeLauncher(hosts: [host], presenting: host, creator: creator)
        let recreation = worktreeRecreation()

        _ = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(recreation))
        let handled = expectation(description: "failure handled")
        creator.finish(with: .failure(AgentHistoryWorktreeError(exitCode: 128, message: "fatal: nope")), handled: handled)
        wait(for: [handled], timeout: 2)

        XCTAssertEqual(
            launcher.resume(
                source(endedSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(recreation)),
            .recreatingWorktree
        )
    }

    private func worktreeSource(_ sessionID: String, rowID: Int64) -> AgentHistoryResumeSource {
        let recreation = worktreeRecreation()
        return AgentHistoryResumeSource(
            sessionRowID: rowID,
            agent: .claude,
            nativeSessionID: sessionID,
            title: "Worktree work",
            workingDirectory: recreation.resumeDirectory,
            repoRoot: recreation.worktreePath,
            mainRepoRoot: recreation.mainRepoRoot,
            branch: recreation.branch,
            model: nil,
            effort: nil,
            generation: nil,
            sourceRoot: nil
        )
    }
}

/// A worktree creator whose git never finishes until the test says so.
final class HeldWorktreeCreator: AgentHistoryWorktreeCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void] = []

    var pendingCount: Int {
        lock.withLock { completions.count }
    }

    func recreate(
        _ recreation: AgentHistoryWorktreeRecreation,
        completion: @escaping @Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void
    ) {
        lock.withLock { completions.append(completion) }
    }

    /// Completes the oldest pending recreation; `handled` is fulfilled after the launcher's
    /// main-queue handling of it.
    func finish(with result: Result<Void, AgentHistoryWorktreeError>, handled: XCTestExpectation) {
        let completion = lock.withLock { completions.removeFirst() }
        DispatchQueue.global(qos: .userInitiated).async {
            completion(result)
            DispatchQueue.main.async { handled.fulfill() }
        }
    }
}
