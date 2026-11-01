import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryLauncherTests: XCTestCase {
    private let windowA = WindowID("win-launch-a")
    private let windowB = WindowID("win-launch-b")
    private let liveSessionID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
    private let endedSessionID = "11111111-2222-4333-8444-555555555555"
    private let livePaneID = PaneID("pn-live")
    private let shellPaneID = PaneID("pn-shell")
    private let projectPath = "/work/project"
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Live sessions

    func test_primary_on_live_session_navigates_toasts_and_records_open() throws {
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = FakeUsageRecorder()
        let launcher = makeLauncher(hosts: [host], presenting: host, recorder: recorder)

        let outcome = launcher.perform(.primary, source: source(liveSessionID, rowID: 7))

        guard case .jumped(let location) = outcome else {
            return XCTFail("expected a jump, got \(outcome)")
        }
        XCTAssertEqual(location.paneID, livePaneID)
        XCTAssertEqual(host.navigations, [Navigation(worklaneID: location.worklaneID, paneID: livePaneID)])
        XCTAssertEqual(host.toasts, ["Jumped to \(location.paneDisplayName)"])
        XCTAssertEqual(recorder.opens, [RecordedOpen(rowID: 7, at: fixedNow)])
        XCTAssertTrue(outcome.closesPalette)
        XCTAssertEqual(host.worklaneStore.activeWorklane?.paneStripState.panes.count, 1, "a jump opens nothing")
    }

    func test_secondary_on_live_session_forks_with_session_override_in_sessions_window() throws {
        let presenting = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let sessionHost = FakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
        let recorder = FakeUsageRecorder()
        let launcher = makeLauncher(hosts: [presenting, sessionHost], presenting: presenting, recorder: recorder)

        let outcome = launcher.perform(.secondary, source: source(liveSessionID, rowID: 3, title: "Fix the parser"))

        guard case .forked(let result) = outcome else {
            return XCTFail("expected a fork, got \(outcome)")
        }
        XCTAssertEqual(sessionHost.forkRequests, [
            ForkRequest(
                paneID: livePaneID,
                destination: .splitRight,
                sessionOverride: AgentForkSessionOverride(tool: .claudeCode, sessionID: liveSessionID)
            ),
        ])
        let forkPane = try XCTUnwrap(
            sessionHost.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID }
        )
        XCTAssertEqual(forkPane.sessionRequest.command, "claude --resume \(liveSessionID) --fork-session")
        XCTAssertEqual(sessionHost.navigations, [Navigation(worklaneID: result.worklaneID, paneID: result.paneID)])
        XCTAssertEqual(sessionHost.toasts, ["Forked Fix the parser into a split"])
        XCTAssertTrue(presenting.toasts.isEmpty)
        XCTAssertTrue(presenting.forkRequests.isEmpty)
        XCTAssertEqual(presenting.worklaneStore.activeWorklane?.paneStripState.panes.count, 1)
        XCTAssertEqual(recorder.opens.map(\.rowID), [3])
    }

    func test_live_session_in_other_window_jumps_and_toasts_in_that_window() {
        let presenting = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let sessionHost = FakeHost(windowID: windowB, store: makeStore(windowB, liveSession: true))
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        host.forkError = WorklaneStore.AgentForkError.unavailable("This agent can't fork sessions.")
        let recorder = FakeUsageRecorder()
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
        let presenting = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let other = FakeHost(windowID: windowB, store: makeStore(windowB, liveSession: false))
        let recorder = FakeUsageRecorder()
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = FakeUsageRecorder()
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = FakeUsageRecorder()
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = FakeUsageRecorder()
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

    func test_folder_choice_recreate_runs_creator_then_resumes_on_success() throws {
        let fileSystem = MutableFakeFileSystem(base: baseFileSystem())
        let recreation = worktreeRecreation()
        let creator = FakeWorktreeCreator(result: .success(())) { recreation in
            fileSystem.makeDirectory(recreation.resumeDirectory)
        }
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = FakeUsageRecorder()
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
        let creator = FakeWorktreeCreator(
            result: .failure(AgentHistoryWorktreeError(exitCode: 128, message: longLine + "\nhint: second line"))
        )
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
        let recorder = FakeUsageRecorder()
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

    // MARK: - Opens and toasts

    func test_no_open_recorded_without_row_id_or_on_failure() {
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = FakeUsageRecorder()
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let recorder = FakeUsageRecorder()
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
        let host = FakeHost(windowID: windowA, store: makeStore(windowA, liveSession: false))
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

    private func makeLauncher(
        hosts: [FakeHost],
        presenting: FakeHost?,
        recorder: FakeUsageRecorder? = nil,
        fileSystem: (any AgentHistoryFileSystemProbing)? = nil,
        creator: FakeWorktreeCreator = FakeWorktreeCreator(result: .success(()))
    ) -> AgentHistoryLauncher {
        let sources = hosts.map {
            MenuBarWorklaneSource(windowID: $0.windowID, windowTitle: $0.menuBarDisplayTitle, worklaneStore: $0.worklaneStore)
        }
        let liveIndex = LiveAgentSessionIndex(
            sources: { sources },
            preferredWindowID: { presenting?.windowID },
            isProcessAlive: { _ in true }
        )
        let fixedNow = fixedNow
        return AgentHistoryLauncher(
            hosts: { hosts },
            presentingHost: { presenting },
            liveIndex: liveIndex,
            usageRecorder: recorder,
            fileSystem: fileSystem ?? baseFileSystem(),
            worktreeCreator: creator,
            now: { fixedNow }
        )
    }

    private func baseFileSystem() -> FakeHistoryFileSystem {
        var fileSystem = FakeHistoryFileSystem()
        fileSystem.makeDirectory(projectPath)
        fileSystem.makeDirectory("/work/repo")
        return fileSystem
    }

    private func worktreeRecreation() -> AgentHistoryWorktreeRecreation {
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

    private func source(_ sessionID: String, rowID: Int64?, title: String = "Session") -> AgentHistoryResumeSource {
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

    private func expectedCommand(for source: AgentHistoryResumeSource) throws -> String {
        guard case .available(let plan) = AgentHistoryResumeCommandBuilder.availability(for: source) else {
            throw XCTSkip("resume command unavailable")
        }
        return plan.command
    }

    private func makeStore(_ windowID: WindowID, liveSession: Bool) -> WorklaneStore {
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

// MARK: - Fakes

private struct Navigation: Equatable {
    let worklaneID: WorklaneID
    let paneID: PaneID
}

private struct ForkRequest: Equatable {
    let paneID: PaneID
    let destination: AgentForkDestination?
    let sessionOverride: AgentForkSessionOverride?
}

private struct RecordedOpen: Equatable {
    let rowID: Int64
    let at: Date
}

/// A window host over a real worklane store; mirrors `MainWindowController`'s forwarding.
@MainActor
private final class FakeHost: AgentHistoryWindowHost {
    let windowID: WindowID
    let worklaneStore: WorklaneStore
    var menuBarDisplayTitle: String { "Window \(windowID.rawValue)" }
    var forkError: Error?
    var splitUnavailable = false
    var onToast: ((String) -> Void)?
    private(set) var toasts: [String] = []
    private(set) var navigations: [Navigation] = []
    private(set) var forkRequests: [ForkRequest] = []

    init(windowID: WindowID, store: WorklaneStore) {
        self.windowID = windowID
        worklaneStore = store
    }

    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID) {
        navigations.append(Navigation(worklaneID: worklaneID, paneID: paneID))
    }

    func forkAgentConversation(
        paneID: PaneID,
        destination: AgentForkDestination?,
        sessionOverride: AgentForkSessionOverride?
    ) throws -> WorklaneStore.AgentForkResult {
        forkRequests.append(ForkRequest(paneID: paneID, destination: destination, sessionOverride: sessionOverride))
        if let forkError {
            throw forkError
        }
        return try worklaneStore.forkAgentConversation(
            paneID: paneID,
            destination: destination ?? .splitRight,
            sessionOverride: sessionOverride
        )
    }

    func launchInNewWorklane(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane {
        worklaneStore.openWorklane(request, anchorWorklaneID: worklaneStore.activeWorklane?.id)
    }

    func launchInSplitRight(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane? {
        guard !splitUnavailable, let worklane = worklaneStore.activeWorklane else {
            return nil
        }
        return worklaneStore.openSplit(
            in: worklane.id,
            targetPaneID: worklane.paneStripState.focusedPaneID,
            isHorizontal: true,
            request
        )
    }

    func showToast(message: String) {
        toasts.append(message)
        onToast?(message)
    }
}

private final class FakeUsageRecorder: AgentHistoryUsageRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedOpen] = []

    var opens: [RecordedOpen] {
        lock.withLock { recorded }
    }

    func recordOpen(sessionRowID: Int64, at date: Date) {
        lock.withLock { recorded.append(RecordedOpen(rowID: sessionRowID, at: date)) }
    }
}

/// Completes on a background queue, like `GitWorktreeCreator`.
private final class FakeWorktreeCreator: AgentHistoryWorktreeCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [AgentHistoryWorktreeRecreation] = []
    private let result: Result<Void, AgentHistoryWorktreeError>
    private let onRecreate: @Sendable (AgentHistoryWorktreeRecreation) -> Void

    init(
        result: Result<Void, AgentHistoryWorktreeError>,
        onRecreate: @escaping @Sendable (AgentHistoryWorktreeRecreation) -> Void = { _ in }
    ) {
        self.result = result
        self.onRecreate = onRecreate
    }

    var requests: [AgentHistoryWorktreeRecreation] {
        lock.withLock { received }
    }

    func recreate(
        _ recreation: AgentHistoryWorktreeRecreation,
        completion: @escaping @Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void
    ) {
        lock.withLock { received.append(recreation) }
        let result = result
        let onRecreate = onRecreate
        DispatchQueue.global(qos: .userInitiated).async {
            if case .success = result {
                onRecreate(recreation)
            }
            completion(result)
        }
    }
}

/// An in-memory tree the fake worktree creator can add folders to.
private final class MutableFakeFileSystem: AgentHistoryFileSystemProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: FakeHistoryFileSystem

    init(base: FakeHistoryFileSystem) {
        tree = base
    }

    func makeDirectory(_ path: String) {
        lock.withLock { tree.makeDirectory(path) }
    }

    func isDirectory(_ path: String) -> Bool {
        lock.withLock { tree.isDirectory(path) }
    }

    func fileExists(_ path: String) -> Bool {
        lock.withLock { tree.fileExists(path) }
    }

    func contents(_ path: String) -> String? {
        lock.withLock { tree.contents(path) }
    }

    func directoryEntries(_ path: String) -> [String] {
        lock.withLock { tree.directoryEntries(path) }
    }
}

private struct LauncherTestGitResolver: PaneGitContextResolving {
    func resolve(for workingDirectory: String) async -> PaneGitContext {
        PaneGitContext(workingDirectory: workingDirectory, repositoryRoot: nil, reference: nil)
    }
}
