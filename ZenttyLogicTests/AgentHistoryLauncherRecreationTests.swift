import XCTest
@testable import Zentty

/// Resuming after `git worktree add`: the outcome arrives after the palette has closed on
/// `.recreatingWorktree`, so every result must end in a launch or a toast.
extension AgentHistoryLauncherTests {
    func test_folder_choice_recreate_runs_creator_then_resumes_on_success() throws {
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let recreation = worktreeRecreation()
        let creator = LauncherFakeWorktreeCreator(result: .success(())) { recreation in
            fileSystem.makeDirectory(recreation.resumeDirectory)
        }
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(
            hosts: [host],
            presenting: host,
            recorder: recorder,
            fileSystem: fileSystem,
            creator: creator
        )
        let resumed = expectation(description: "resumed after recreating")
        host.onToast = { message in
            if message.hasPrefix("Resuming") { resumed.fulfill() }
        }

        let outcome = launcher.resume(
            source(endedSessionID, rowID: 8, title: "Worktree work"),
            intent: .primary,
            folderChoice: .recreateWorktree(recreation)
        )

        XCTAssertEqual(outcome, .recreatingWorktree)
        XCTAssertTrue(outcome.closesPalette)
        XCTAssertEqual(host.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage])
        XCTAssertTrue(recorder.opens.isEmpty, "nothing is recorded until the session launches")
        wait(for: [resumed], timeout: 2)

        XCTAssertEqual(creator.requests, [recreation])
        XCTAssertEqual(host.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage, "Resuming Worktree work"])
        XCTAssertEqual(host.worklaneStore.worklanes.count, 2)
        let pane = try XCTUnwrap(host.worklaneStore.activeWorklane?.paneStripState.panes.first)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, recreation.resumeDirectory)
        XCTAssertEqual(recorder.opens.map(\.rowID), [8])
    }

    func test_folder_choice_recreate_failure_toasts_and_does_not_launch() {
        let longLine = "fatal: '" + String(repeating: "b", count: 200) + "' is already checked out"
        let creator = LauncherFakeWorktreeCreator(
            result: .failure(AgentHistoryWorktreeError(exitCode: 128, message: longLine + "\nhint: second line"))
        )
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder, creator: creator)
        let failed = expectation(description: "failure toast")
        host.onToast = { message in
            if message.hasPrefix("Couldn't recreate") { failed.fulfill() }
        }

        let outcome = launcher.resume(
            source(endedSessionID, rowID: 8),
            intent: .primary,
            folderChoice: .recreateWorktree(worktreeRecreation())
        )

        XCTAssertEqual(outcome, .recreatingWorktree)
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(host.toasts, [
            AgentHistoryLauncher.recreatingWorktreeMessage,
            "Couldn't recreate the worktree: " + String(longLine.prefix(120)) + "…",
        ])
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func test_recreate_success_without_folder_toasts_missing_folder() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let creator = LauncherFakeWorktreeCreator(result: .success(()))   // creates no folder
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder, creator: creator)
        let handled = expectation(description: "recreation handled")
        creator.expectHandled(handled)

        let outcome = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(worktreeRecreation()))

        XCTAssertEqual(outcome, .recreatingWorktree)
        wait(for: [handled], timeout: 2)
        XCTAssertEqual(host.toasts, [
            AgentHistoryLauncher.recreatingWorktreeMessage, AgentHistoryLauncher.recreatedFolderMissingMessage,
        ])
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func test_recreate_resumes_in_another_window_when_presenting_one_closed() throws {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let other = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: false))
        let windows = LauncherWindows(hosts: [presenting, other], presenting: presenting)
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let creator = LauncherFakeWorktreeCreator(result: .success(())) { fileSystem.makeDirectory($0.resumeDirectory) }
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(windows: windows, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let handled = expectation(description: "recreation handled")
        creator.expectHandled(handled)
        let recreation = worktreeRecreation()

        let outcome = launcher.resume(
            source(endedSessionID, rowID: 8, title: "Worktree work"), intent: .primary,
            folderChoice: .recreateWorktree(recreation))
        // The presenting window closes while git runs (completion hops to main after this).
        windows.hosts = [other]
        windows.presenting = other

        XCTAssertEqual(outcome, .recreatingWorktree)
        wait(for: [handled], timeout: 2)
        XCTAssertEqual(presenting.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage])
        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 1)
        XCTAssertEqual(other.toasts, ["Resuming Worktree work"])
        XCTAssertEqual(other.worklaneStore.worklanes.count, 2)
        let pane = try XCTUnwrap(other.worklaneStore.activeWorklane?.paneStripState.panes.first)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, recreation.resumeDirectory)
        XCTAssertEqual(recorder.opens.map(\.rowID), [8])
    }

    func test_recreate_with_no_window_left_launches_nothing() {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let windows = LauncherWindows(hosts: [presenting], presenting: presenting)
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let creator = LauncherFakeWorktreeCreator(result: .success(())) { fileSystem.makeDirectory($0.resumeDirectory) }
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(windows: windows, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let handled = expectation(description: "recreation handled")
        creator.expectHandled(handled)

        _ = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(worktreeRecreation()))
        windows.hosts = []
        windows.presenting = nil

        wait(for: [handled], timeout: 2)
        XCTAssertEqual(presenting.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage])
        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func test_recreate_secondary_without_split_toasts_the_failure() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        host.splitUnavailable = true
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let creator = LauncherFakeWorktreeCreator(result: .success(())) { fileSystem.makeDirectory($0.resumeDirectory) }
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(
            hosts: [host], presenting: host, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let handled = expectation(description: "recreation handled")
        creator.expectHandled(handled)

        let outcome = launcher.resume(
            source(endedSessionID, rowID: 8), intent: .secondary, folderChoice: .recreateWorktree(worktreeRecreation()))

        XCTAssertTrue(outcome.closesPalette)
        wait(for: [handled], timeout: 2)
        XCTAssertEqual(host.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage, AgentHistoryLauncher.splitFailedMessage])
        let worklane = try XCTUnwrap(host.worklaneStore.activeWorklane)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [shellPaneID])
        XCTAssertTrue(recorder.opens.isEmpty)
    }
}
