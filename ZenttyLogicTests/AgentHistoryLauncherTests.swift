import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryLauncherTests: XCTestCase {
    let windowA = WindowID("win-launch-a")
    let windowB = WindowID("win-launch-b")
    let liveSessionID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
    let endedSessionID = "11111111-2222-4333-8444-555555555555"
    let livePaneID = PaneID("pn-live")
    let shellPaneID = PaneID("pn-shell")
    let projectPath = "/work/project"
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Live sessions

    func test_primary_on_live_session_navigates_toasts_and_records_open() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)

        let outcome = launcher.perform(.primary, source: source(liveSessionID, rowID: 7))

        guard case .jumped(let location) = outcome else {
            return XCTFail("expected a jump, got \(outcome)")
        }
        XCTAssertEqual(location.paneID, livePaneID)
        XCTAssertEqual(host.navigations, [LauncherNavigation(worklaneID: location.worklaneID, paneID: livePaneID)])
        XCTAssertEqual(host.toasts, ["Jumped to \(location.paneDisplayName)"])
        XCTAssertEqual(recorder.opens, [LauncherRecordedOpen(rowID: 7, at: fixedNow)])
        XCTAssertTrue(outcome.closesPalette)
        XCTAssertEqual(host.worklaneStore.activeWorklane?.paneStripState.panes.count, 1, "a jump opens nothing")
    }

    func test_secondary_on_live_session_forks_with_session_override_in_sessions_window() throws {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let sessionHost = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [presenting, sessionHost], presenting: presenting, recorder: recorder)

        let outcome = launcher.perform(.secondary, source: source(liveSessionID, rowID: 3, title: "Fix the parser"))

        guard case .forked(let result) = outcome else {
            return XCTFail("expected a fork, got \(outcome)")
        }
        XCTAssertEqual(sessionHost.forkRequests, [
            LauncherForkRequest(
                paneID: livePaneID,
                destination: .splitRight,
                sessionOverride: AgentForkSessionOverride(tool: .claudeCode, sessionID: liveSessionID)
            ),
        ])
        let forkPane = try XCTUnwrap(
            sessionHost.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID }
        )
        XCTAssertEqual(forkPane.sessionRequest.command, "claude --resume \(liveSessionID) --fork-session")
        XCTAssertEqual(sessionHost.navigations, [LauncherNavigation(worklaneID: result.worklaneID, paneID: result.paneID)])
        XCTAssertEqual(sessionHost.toasts, ["Forked Fix the parser into a split"])
        XCTAssertTrue(presenting.toasts.isEmpty)
        XCTAssertTrue(presenting.forkRequests.isEmpty)
        XCTAssertEqual(presenting.worklaneStore.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(recorder.opens.map(\.rowID), [3])
    }

    func test_live_session_in_other_window_jumps_and_toasts_in_that_window() {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let sessionHost = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        let launcher = makeLauncher(hosts: [presenting, sessionHost], presenting: presenting)

        let outcome = launcher.perform(.primary, source: source(liveSessionID, rowID: 1))

        guard case .jumped(let location) = outcome else {
            return XCTFail("expected a jump, got \(outcome)")
        }
        XCTAssertEqual(location.windowID, windowB)
        XCTAssertEqual(sessionHost.navigations.map(\.paneID), [livePaneID])
        XCTAssertEqual(sessionHost.toasts.count, 1)
        XCTAssertTrue(presenting.navigations.isEmpty)
        XCTAssertTrue(presenting.toasts.isEmpty)
    }

    func test_fork_error_surfaces_message() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        host.forkError = WorklaneStore.AgentForkError.unavailable("This agent can't fork sessions.")
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)

        let outcome = launcher.perform(.secondary, source: source(liveSessionID, rowID: 2))

        XCTAssertEqual(outcome, .failed(message: "This agent can't fork sessions.", offerCopySessionID: false))
        XCTAssertFalse(outcome.closesPalette)
        XCTAssertTrue(host.toasts.isEmpty)
        XCTAssertTrue(host.navigations.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    // MARK: - Ended sessions

    func test_primary_on_ended_session_opens_new_worklane_in_presenting_window() throws {
        let presenting = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let other = LauncherFakeHost(windowID: windowB, store: makeStore(windowB, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [other, presenting], presenting: presenting, recorder: recorder)
        let ended = source(endedSessionID, rowID: 9, title: "Ship the release")

        let outcome = launcher.perform(.primary, source: ended)

        guard case .resumed(let launched) = outcome else {
            return XCTFail("expected a resume, got \(outcome)")
        }
        XCTAssertEqual(presenting.worklaneStore.worklanes.count, 2)
        XCTAssertEqual(presenting.worklaneStore.activeWorklaneID, launched.worklaneID)
        let pane = try XCTUnwrap(
            presenting.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == launched.paneID }
        )
        XCTAssertEqual(pane.sessionRequest.command, try expectedCommand(for: ended))
        XCTAssertEqual(pane.sessionRequest.workingDirectory, projectPath)
        XCTAssertFalse(pane.sessionRequest.replaysCommandOnRestore)
        XCTAssertEqual(presenting.toasts, ["Resuming Ship the release"])
        XCTAssertEqual(other.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(other.toasts.isEmpty)
        XCTAssertEqual(recorder.opens.map(\.rowID), [9])
    }

    func test_secondary_on_ended_session_opens_split_right_of_focused_pane() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        let ended = source(endedSessionID, rowID: 4)

        let outcome = launcher.perform(.secondary, source: ended)

        guard case .resumed(let launched) = outcome else {
            return XCTFail("expected a resume, got \(outcome)")
        }
        let worklane = try XCTUnwrap(host.worklaneStore.activeWorklane)
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)
        XCTAssertEqual(worklane.paneStripState.columns.map { $0.panes.map(\.id) }, [[shellPaneID], [launched.paneID]])
        let pane = try XCTUnwrap(worklane.paneStripState.panes.first { $0.id == launched.paneID })
        XCTAssertEqual(pane.sessionRequest.command, try expectedCommand(for: ended))
        XCTAssertEqual(pane.sessionRequest.workingDirectory, projectPath)
        XCTAssertEqual(host.toasts.count, 1)
    }

    func test_invalid_session_id_fails_with_copy_session_id_offer() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)

        let outcome = launcher.perform(.primary, source: source("not-a-session; rm -rf /", rowID: 5))

        XCTAssertEqual(
            outcome,
            .failed(message: AgentHistoryResumeCommandBuilder.invalidSessionIDReason, offerCopySessionID: true)
        )
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(host.toasts.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func test_missing_folder_returns_needsFolderChoice_without_launching() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)
        var gone = source(endedSessionID, rowID: 6)
        gone.workingDirectory = "/work/repo/gone"
        gone.repoRoot = "/work/repo"

        let outcome = launcher.perform(.primary, source: gone)

        XCTAssertEqual(
            outcome,
            .needsFolderChoice(
                options: [.repositoryRoot("/work/repo"), .copyResumeCommand],
                defaultChoice: .repositoryRoot("/work/repo")
            )
        )
        XCTAssertFalse(outcome.closesPalette)
        XCTAssertEqual(host.worklaneStore.worklanes.count, 1)
        XCTAssertTrue(host.toasts.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func test_folder_choice_repository_root_launches_there() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)
        var gone = source(endedSessionID, rowID: 6)
        gone.workingDirectory = "/work/repo/gone"

        let outcome = launcher.resume(gone, intent: .primary, folderChoice: .repositoryRoot("/work/repo"))

        guard case .resumed(let launched) = outcome else {
            return XCTFail("expected a resume, got \(outcome)")
        }
        let pane = try XCTUnwrap(
            host.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == launched.paneID }
        )
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/work/repo")
        XCTAssertEqual(host.toasts.count, 1)
        XCTAssertEqual(recorder.opens.map(\.rowID), [6])

        let missing = launcher.resume(gone, intent: .primary, folderChoice: .homeFolder("/Users/nobody"))
        XCTAssertEqual(missing, .failed(message: AgentHistoryLauncher.folderMissingMessage, offerCopySessionID: false))
        XCTAssertEqual(recorder.opens.count, 1)
    }

    // MARK: - Opens and toasts

    func test_no_open_recorded_without_row_id_or_on_failure() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)

        // Successful launches of sessions with no index row.
        XCTAssertTrue(launcher.perform(.primary, source: source(endedSessionID, rowID: nil)).closesPalette)
        XCTAssertTrue(launcher.perform(.primary, source: source(liveSessionID, rowID: nil)).closesPalette)
        // Failures with a row.
        host.splitUnavailable = true
        XCTAssertFalse(launcher.perform(.secondary, source: source(endedSessionID, rowID: 1)).closesPalette)
        XCTAssertFalse(launcher.perform(.primary, source: source("bogus id", rowID: 2)).closesPalette)

        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertEqual(
            launcher.perform(.secondary, source: source(endedSessionID, rowID: 1)),
            .failed(message: AgentHistoryLauncher.splitFailedMessage, offerCopySessionID: false)
        )
    }

    func test_each_launch_records_exactly_one_open_and_one_toast() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = LauncherFakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)
        let launches: [(AgentHistoryLaunchIntent, String)] = [
            (.primary, liveSessionID),
            (.secondary, liveSessionID),
            (.primary, endedSessionID),
            (.secondary, endedSessionID),
        ]

        for (offset, launch) in launches.enumerated() {
            let rowID = Int64(offset + 1)
            let outcome = launcher.perform(launch.0, source: source(launch.1, rowID: rowID))

            XCTAssertTrue(outcome.closesPalette, "launch \(offset) failed: \(outcome)")
            XCTAssertEqual(recorder.opens.map(\.rowID), Array(1...rowID), "launch \(offset)")
            XCTAssertEqual(host.toasts.count, offset + 1, "launch \(offset)")
        }
    }

    func test_long_titles_truncated_in_toasts() {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        let longTitle = String(repeating: "x", count: 100)

        _ = launcher.perform(.primary, source: source(endedSessionID, rowID: 1, title: longTitle))

        XCTAssertEqual(host.toasts, ["Resuming " + String(repeating: "x", count: 60) + "…"])
        XCTAssertEqual(AgentHistoryLauncher.truncatedTitle("short"), "short")
        XCTAssertEqual(AgentHistoryLauncher.truncatedTitle(String(repeating: "y", count: 60)), String(repeating: "y", count: 60))
        XCTAssertEqual(AgentHistoryLauncher.truncatedTitle("two\nlines"), "two lines")
        XCTAssertEqual(AgentHistoryLauncher.truncatedTitle("  \n "), "session")
    }

    // MARK: - Helpers

    func makeLauncher(
        hosts: [LauncherFakeHost],
        presenting: LauncherFakeHost?,
        recorder: LauncherFakeUsageRecorder? = nil,
        fileSystem: (any AgentHistoryFileSystemProbing)? = nil,
        creator: any AgentHistoryWorktreeCreating = LauncherFakeWorktreeCreator(result: .success(())),
        homeDirectory: String = "/Users/tester"
    ) -> AgentHistoryLauncher {
        makeLauncher(
            windows: LauncherWindows(hosts: hosts, presenting: presenting),
            recorder: recorder,
            fileSystem: fileSystem,
            creator: creator,
            homeDirectory: homeDirectory
        )
    }

    /// The launcher reads `windows` on every call, so a test can close windows mid-flight.
    func makeLauncher(
        windows: LauncherWindows,
        recorder: LauncherFakeUsageRecorder? = nil,
        fileSystem: (any AgentHistoryFileSystemProbing)? = nil,
        creator: any AgentHistoryWorktreeCreating = LauncherFakeWorktreeCreator(result: .success(())),
        homeDirectory: String = "/Users/tester"
    ) -> AgentHistoryLauncher {
        let sources = windows.hosts.map {
            MenuBarWorklaneSource(windowID: $0.windowID, windowTitle: $0.menuBarDisplayTitle, worklaneStore: $0.worklaneStore)
        }
        let liveIndex = LiveAgentSessionIndex(
            sources: { sources },
            preferredWindowID: { windows.presenting?.windowID },
            isProcessAlive: { _ in true }
        )
        let fixedNow = fixedNow
        return AgentHistoryLauncher(
            hosts: { windows.hosts },
            presentingHost: { windows.presenting },
            liveIndex: liveIndex,
            usageRecorder: recorder,
            fileSystem: fileSystem ?? baseFileSystem(),
            worktreeCreator: creator,
            worktreeReservations: AgentHistoryWorktreeReservations(),
            homeDirectory: homeDirectory,
            now: { fixedNow }
        )
    }

    func baseFileSystem() -> FakeHistoryFileSystem {
        var fileSystem = FakeHistoryFileSystem()
        fileSystem.makeDirectory(projectPath)
        fileSystem.makeDirectory("/work/repo")
        return fileSystem
    }

    func worktreeRecreation() -> AgentHistoryWorktreeRecreation {
        AgentHistoryWorktreeRecreation(
            mainRepoRoot: "/work/repo",
            worktreePath: "/work/repo-feature",
            branch: "feature",
            hasStaleRegistration: false,
            resumeDirectory: "/work/repo-feature/app",
            staleRegistrationRemovalArguments: nil,
            gitArguments: ["-C", "/work/repo", "worktree", "add", "--", "/work/repo-feature", "feature"]
        )
    }

    func source(_ sessionID: String, rowID: Int64?, title: String = "Session") -> AgentHistoryResumeSource {
        AgentHistoryResumeSource(
            sessionRowID: rowID,
            agent: .claude,
            nativeSessionID: sessionID,
            title: title,
            workingDirectory: projectPath,
            repoRoot: nil,
            mainRepoRoot: nil,
            branch: nil,
            model: nil,
            effort: nil,
            generation: nil,
            sourceRoot: nil
        )
    }

    func expectedCommand(for source: AgentHistoryResumeSource) throws -> String {
        guard case .available(let plan) = AgentHistoryResumeCommandBuilder.availability(for: source) else {
            throw XCTSkip("resume command unavailable")
        }
        return plan.command
    }

    func makeStore(_ windowID: WindowID, liveSession: Bool) -> WorklaneStore {
        let worklaneID = WorklaneID("wl-\(windowID.rawValue)")
        let paneID = liveSession ? livePaneID : shellPaneID
        let agentStatus = liveSession
            ? PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 1),
                trackedPID: 4242,
                workingDirectory: projectPath,
                sessionID: liveSessionID
            )
            : nil
        let auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(
                scope: .local,
                path: projectPath,
                home: "/Users/tester",
                user: "tester",
                host: nil
            ),
            agentStatus: agentStatus
        )
        let store = WorklaneStore(
            windowID: windowID,
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: paneID,
                                title: liveSession ? "claude" : "zsh",
                                sessionRequest: TerminalSessionRequest(workingDirectory: projectPath),
                                width: 420
                            ),
                        ],
                        focusedPaneID: paneID
                    ),
                    nextPaneNumber: 2,
                    auxiliaryStateByPaneID: [paneID: auxiliary]
                ),
            ],
            activeWorklaneID: worklaneID,
            gitContextResolver: LauncherTestGitResolver()
        )
        store.knownNonRepositoryPaths.formUnion([projectPath, "/work/repo", "/work/repo-feature/app"])
        return store
    }
}
