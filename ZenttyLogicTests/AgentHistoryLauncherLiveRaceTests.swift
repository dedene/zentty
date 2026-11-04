import XCTest
@testable import Zentty

/// A session can go live, or start resuming, between the palette's look and a deferred launch:
/// while the folder sheet is open, while git recreates the worktree, or before a just-launched
/// agent has registered. Every launch path checks again right before it would start a process,
/// so the launcher never starts a duplicate of a session (spec goal 3).
extension AgentHistoryLauncherTests {
    // MARK: - Went live while the folder sheet was open

    func test_folder_choice_jumps_when_the_session_went_live_while_the_sheet_was_open() {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let windows = LauncherWindows(hosts: [presenting], presenting: presenting)
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(windows: windows, recorder: recorder)
        let gone = folderGoneSource(liveSessionID, rowID: 6)

        guard case .needsFolderChoice = launcher.perform(.primary, source: gone) else {
            return XCTFail("the folder sheet opens first")
        }
        // Someone resumed the session in another window while the sheet was open.
        let sessionHost = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        windows.hosts.append(sessionHost)

        let outcome = launcher.resume(gone, intent: .primary, folderChoice: .repositoryRoot("/work/repo"))

        guard case .jumped(let location) = outcome else {
            return XCTFail("expected a jump to the live session, got \(outcome)")
        }
        XCTAssertEqual(location.windowID, windowB)
        XCTAssertEqual(sessionHost.navigations.map(\.paneID), [livePaneID])
        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 1, "no second process")
        XCTAssertTrue(presenting.toasts.isEmpty)
        XCTAssertEqual(recorder.opens.map(\.rowID), [6])
    }

    func test_secondary_folder_choice_forks_when_the_session_went_live_while_the_sheet_was_open() {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let windows = LauncherWindows(hosts: [presenting], presenting: presenting)
        let launcher = makeLauncher(windows: windows)
        let gone = folderGoneSource(liveSessionID, rowID: 6)
        let sessionHost = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        windows.hosts.append(sessionHost)

        let outcome = launcher.resume(gone, intent: .secondary, folderChoice: .repositoryRoot("/work/repo"))

        guard case .forked = outcome else {
            return XCTFail("expected a fork of the live session, got \(outcome)")
        }
        XCTAssertEqual(sessionHost.forkRequests.map(\.paneID), [livePaneID])
        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 1)
        XCTAssertEqual(presenting.worklaneStore.activeWorklane?.paneStripState.panes.count, 1)
    }

    // MARK: - Went live, or was resumed again, while git recreated the worktree

    func test_finished_recreation_jumps_when_the_session_went_live_while_git_ran() {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let windows = LauncherWindows(hosts: [presenting], presenting: presenting)
        let fileSystem = LauncherMutableFileSystem(base: baseFileSystem())
        let creator = HeldWorktreeCreator()
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(windows: windows, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let recreation = worktreeRecreation()

        XCTAssertEqual(
            launcher.resume(
                source(liveSessionID, rowID: 8), intent: .primary, folderChoice: .recreateWorktree(recreation)),
            .recreatingWorktree
        )
        let sessionHost = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        windows.hosts.append(sessionHost)
        fileSystem.makeDirectory(recreation.resumeDirectory)
        let handled = expectation(description: "recreation handled")
        creator.finish(with: .success(()), handled: handled)
        wait(for: [handled], timeout: 2)

        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 1, "no second process")
        XCTAssertEqual(presenting.toasts, [AgentHistoryLauncher.recreatingWorktreeMessage])
        XCTAssertEqual(sessionHost.navigations.map(\.paneID), [livePaneID])
        XCTAssertEqual(sessionHost.toasts.count, 1)
        XCTAssertEqual(recorder.opens.map(\.rowID), [8])
    }

    func test_other_folder_choice_waits_while_a_recreation_of_the_same_session_runs() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        var base = baseFileSystem()
        base.makeDirectory("/Users/tester")
        let fileSystem = LauncherMutableFileSystem(base: base)
        let creator = HeldWorktreeCreator()
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(
            hosts: [host], presenting: host, recorder: recorder, fileSystem: fileSystem, creator: creator)
        let recreation = worktreeRecreation()
        let session = source(endedSessionID, rowID: 8)

        XCTAssertEqual(
            launcher.resume(session, intent: .primary, folderChoice: .recreateWorktree(recreation)),
            .recreatingWorktree
        )
        // A second window's sheet, still open, now picks the home folder: outside the worktree.
        XCTAssertEqual(
            launcher.resume(session, intent: .primary, folderChoice: .homeFolder("/Users/tester")),
            .failed(message: AgentHistoryLauncher.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        )
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)

        fileSystem.makeDirectory(recreation.resumeDirectory)
        let handled = expectation(description: "recreation handled")
        creator.finish(with: .success(()), handled: handled)
        wait(for: [handled], timeout: 2)

        XCTAssertEqual(host.worklaneStore.worklanes.count, 2, "exactly one launch")
        XCTAssertEqual(recorder.opens.map(\.rowID), [8])
    }

    // MARK: - Resumed again before the launched agent registered

    func test_second_resume_of_a_just_launched_session_goes_to_its_pane() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        let ended = source(endedSessionID, rowID: 1, title: "Ship it")

        guard case .resumed(let launched) = launcher.perform(.primary, source: ended) else {
            return XCTFail("the first ↩ resumes")
        }
        let again = launcher.perform(.primary, source: ended)
        let fork = launcher.perform(.secondary, source: ended)

        XCTAssertEqual(again, .resumed(launched))
        XCTAssertEqual(fork, .failed(message: AgentHistoryLauncher.stillStartingMessage, offerCopySessionID: false))
        XCTAssertEqual(host.worklaneStore.worklanes.count, 2, "one resumed worklane")
        XCTAssertEqual(host.worklaneStore.activeWorklane?.paneStripState.panes.count, 1, "no split either")
        XCTAssertEqual(host.navigations.last, LauncherNavigation(worklaneID: launched.worklaneID, paneID: launched.paneID))
        XCTAssertEqual(host.toasts, ["Resuming Ship it", "Jumped to Ship it"])
    }

    func test_second_resume_goes_to_a_just_launched_pane_the_user_floated() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        let ended = source(endedSessionID, rowID: 1, title: "Ship it")

        guard case .resumed(let launched) = launcher.perform(.primary, source: ended) else {
            return XCTFail("the first resume launches")
        }
        // A worklane's only tile can't float, so give it a neighbour first.
        XCTAssertNotNil(host.worklaneStore.openSplit(
            in: launched.worklaneID,
            targetPaneID: launched.paneID,
            PaneLaunchRequest(workingDirectory: "/work/repo", command: nil)
        ))
        host.worklaneStore.floatPane(
            launched.paneID,
            canvas: CGRect(x: 0, y: 0, width: 1000, height: 800),
            tileFrame: nil
        )
        XCTAssertTrue(try XCTUnwrap(host.worklaneStore.activeWorklane).isFloating(launched.paneID))

        XCTAssertEqual(launcher.perform(.primary, source: ended), .resumed(launched))
        XCTAssertEqual(host.worklaneStore.worklanes.count, 2, "no second process")
        XCTAssertEqual(host.navigations.last, LauncherNavigation(worklaneID: launched.worklaneID, paneID: launched.paneID))
    }

    func test_just_launched_session_is_not_resumed_again_from_another_window() {
        let hostA = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let hostB = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: false))
        let reservations = AgentHistorySessionReservations()
        let launcherA = makeLauncher(
            windows: LauncherWindows(hosts: [hostA, hostB], presenting: hostA), sessionReservations: reservations)
        let launcherB = makeLauncher(
            windows: LauncherWindows(hosts: [hostA, hostB], presenting: hostB), sessionReservations: reservations)
        let ended = source(endedSessionID, rowID: 1)

        guard case .resumed(let launched) = launcherA.perform(.primary, source: ended) else {
            return XCTFail("window A resumes")
        }
        XCTAssertEqual(launcherB.perform(.primary, source: ended), .resumed(launched))

        XCTAssertEqual(hostA.worklaneStore.worklanes.count, 2)
        XCTAssertEqual(hostB.worklaneStore.worklanes.count, 1, "window B starts nothing")
        XCTAssertEqual(hostA.navigations.last?.paneID, launched.paneID)
    }

    func test_launch_reservation_ends_when_the_pane_closes_or_the_timeout_passes() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        var clock = fixedNow
        let launcher = makeLauncher(
            windows: LauncherWindows(hosts: [host], presenting: host), now: { clock })
        let ended = source(endedSessionID, rowID: 1)

        guard case .resumed(let first) = launcher.perform(.primary, source: ended) else {
            return XCTFail("first resume")
        }
        // The agent never registered: after the timeout, ↩ resumes again.
        clock += AgentHistorySessionReservations.launchTimeout
        guard case .resumed(let second) = launcher.perform(.primary, source: ended), second != first else {
            return XCTFail("a stale reservation resumes again")
        }
        // The agent exited and its pane closed: ↩ resumes again.
        XCTAssertEqual(host.worklaneStore.closePane(id: second.paneID), .closed)
        guard case .resumed(let third) = launcher.perform(.primary, source: ended), third != second else {
            return XCTFail("a closed pane's reservation resumes again")
        }
        XCTAssertEqual(host.worklaneStore.worklanes.count, 3)
    }

    private func folderGoneSource(_ sessionID: String, rowID: Int64) -> AgentHistoryResumeSource {
        var gone = source(sessionID, rowID: rowID)
        gone.workingDirectory = "/work/repo/gone"
        gone.repoRoot = "/work/repo"
        return gone
    }
}
