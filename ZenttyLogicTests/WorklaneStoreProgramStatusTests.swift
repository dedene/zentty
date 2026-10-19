import XCTest
@testable import Zentty

/// The store side of program status: which pane events set and clear it,
/// the stale timeout, the setting, and attention for unfocused panes.
@MainActor
final class WorklaneStoreProgramStatusTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var pendingTasks: [ProgramStatusPendingTask] = []
    private var programStatusEnabled = true

    override func tearDown() {
        pendingTasks.removeAll()
        super.tearDown()
    }

    func test_progress_report_sets_and_remove_clears_program_status() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.set, 30)))
        XCTAssertEqual(programStatus(store, paneID)?.state, .working)
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .running)
        XCTAssertEqual(presentation(store, paneID)?.taskProgress?.doneCount, 30)

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.remove)))
        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .idle)
    }

    func test_command_finished_clears_working_but_keeps_error_until_next_input() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.indeterminate)))
        store.handleTerminalEvent(paneID: paneID, event: .commandFinished(exitCode: 0, durationNanoseconds: 1))
        XCTAssertNil(programStatus(store, paneID))

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))
        store.handleTerminalEvent(paneID: paneID, event: .commandFinished(exitCode: 1, durationNanoseconds: 1))
        XCTAssertEqual(programStatus(store, paneID)?.state, .error)
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .unresolvedStop)

        store.handleTerminalEvent(paneID: paneID, event: .userSubmittedInput)
        XCTAssertNil(programStatus(store, paneID))
    }

    func test_shell_prompt_signal_clears_working_status() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.pause)))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .needsInput)

        store.applyAgentStatusPayload(shellStatePayload(store, paneID: paneID, activity: .promptIdle))
        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .idle)
    }

    func test_command_started_signal_keeps_a_report_that_raced_ahead_of_it() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.indeterminate)))
        store.applyAgentStatusPayload(
            shellStatePayload(store, paneID: paneID, activity: .commandRunning, command: "cargo build")
        )

        XCTAssertEqual(programStatus(store, paneID)?.state, .working)
    }

    func test_command_started_signal_keeps_an_error_that_raced_ahead_of_it() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))
        store.applyAgentStatusPayload(
            shellStatePayload(store, paneID: paneID, activity: .commandRunning, command: "cargo check")
        )

        XCTAssertEqual(programStatus(store, paneID)?.state, .error)
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .unresolvedStop)
    }

    func test_next_command_clears_the_previous_runs_error() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))
        store.applyAgentStatusPayload(shellStatePayload(store, paneID: paneID, activity: .promptIdle))
        XCTAssertEqual(programStatus(store, paneID)?.state, .error)

        store.applyAgentStatusPayload(
            shellStatePayload(store, paneID: paneID, activity: .commandRunning, command: "cargo check")
        )
        XCTAssertNil(programStatus(store, paneID))
    }

    func test_ctrl_c_clears_program_status() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.set, 50)))
        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)

        XCTAssertNil(programStatus(store, paneID))
    }

    func test_working_status_without_updates_goes_stale() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.indeterminate)))
        XCTAssertEqual(pendingTasks.count, 1)

        now = now.addingTimeInterval(PaneProgramStatus.staleInterval)
        runPendingTasks()

        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .idle)
    }

    func test_fresh_report_keeps_a_working_status_alive() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.set, 10)))
        now = now.addingTimeInterval(PaneProgramStatus.staleInterval - 1)
        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.set, 20)))
        now = now.addingTimeInterval(2)
        runPendingTasks()

        XCTAssertEqual(programStatus(store, paneID)?.percent, 20)
    }

    func test_working_status_outlives_the_timeout_while_the_local_command_runs() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        store.applyAgentStatusPayload(
            shellStatePayload(store, paneID: paneID, activity: .commandRunning, command: "make test")
        )

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.indeterminate)))
        now = now.addingTimeInterval(PaneProgramStatus.staleInterval)
        runPendingTasks()

        XCTAssertEqual(programStatus(store, paneID)?.state, .working)
        XCTAssertEqual(pendingTasks.count, 1, "The check is re-armed while the command runs")

        store.applyAgentStatusPayload(shellStatePayload(store, paneID: paneID, activity: .promptIdle))
        XCTAssertNil(programStatus(store, paneID))
    }

    func test_stale_check_follows_a_pane_moved_to_another_worklane() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        let sourceWorklaneID = store.activeWorklaneID
        store.send(.splitAfterFocusedPane)
        let targetWorklaneID = store.createWorklane()
        store.selectWorklaneAndFocusPane(worklaneID: sourceWorklaneID, paneID: paneID)

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.indeterminate)))
        store.transferPaneToWorklane(
            paneID: paneID,
            targetWorklaneID: targetWorklaneID,
            singleColumnWidth: store.layoutContext.singlePaneWidth
        )
        let targetWorklane = try XCTUnwrap(store.worklanes.first { $0.id == targetWorklaneID })
        XCTAssertEqual(targetWorklane.auxiliaryStateByPaneID[paneID]?.raw.programStatus?.state, .working)

        now = now.addingTimeInterval(PaneProgramStatus.staleInterval)
        runPendingTasks()

        let movedWorklane = try XCTUnwrap(store.worklanes.first { $0.id == targetWorklaneID })
        XCTAssertNil(movedWorklane.auxiliaryStateByPaneID[paneID]?.raw.programStatus)
        XCTAssertEqual(movedWorklane.auxiliaryStateByPaneID[paneID]?.presentation.runtimePhase, .idle)
    }

    func test_turning_the_setting_off_clears_statuses_already_showing() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))

        store.clearProgramStatusesIfDisabled()
        XCTAssertEqual(programStatus(store, paneID)?.state, .error, "Still enabled: nothing to clear")

        programStatusEnabled = false
        store.clearProgramStatusesIfDisabled()

        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .idle)
    }

    func test_disabled_setting_records_no_program_status() throws {
        programStatusEnabled = false
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))

        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .idle)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.terminalProgress?.state, .error)
    }

    func test_agent_pane_ignores_program_status() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: nil,
                confidence: .explicit,
                sessionID: "claude-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))

        XCTAssertNil(programStatus(store, paneID))
        XCTAssertEqual(presentation(store, paneID)?.runtimePhase, .running)
    }

    func test_error_raises_attention_owned_by_the_program() throws {
        let (store, paneID) = try makeStoreWithPlainPane()

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))

        let worklane = try XCTUnwrap(store.activeWorklane)
        let attention = try XCTUnwrap(WorklaneAttentionSummaryBuilder.summary(for: worklane))
        XCTAssertEqual(attention.paneID, paneID)
        XCTAssertEqual(attention.state, .unresolvedStop)
        XCTAssertEqual(attention.tool, .custom("cargo"))
        XCTAssertEqual(attention.statusText, "Error")
    }

    func test_error_on_an_unfocused_pane_notifies_and_lands_in_the_inbox() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        store.send(.splitAfterFocusedPane)
        XCTAssertNotEqual(store.activeWorklane?.paneStripState.focusedPaneID, paneID)
        let notificationStore = NotificationStore()
        let center = RecordingProgramStatusNotificationCenter()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: center,
            notificationStore: notificationStore
        )

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))
        update(coordinator, with: store, windowIsKey: true)

        let notification = try XCTUnwrap(notificationStore.notifications.first)
        XCTAssertEqual(notification.paneID, paneID)
        XCTAssertEqual(notification.tool, .custom("cargo"))
        XCTAssertEqual(notification.state, .unresolvedStop)
        XCTAssertEqual(center.titles, ["Error"])
    }

    func test_error_on_the_focused_pane_of_a_key_window_posts_no_banner() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        let center = RecordingProgramStatusNotificationCenter()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: center,
            notificationStore: NotificationStore()
        )

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.error)))
        update(coordinator, with: store, windowIsKey: true)

        XCTAssertEqual(center.titles, [])
    }

    func test_paused_program_notifies_as_paused_not_as_needing_input() throws {
        let (store, paneID) = try makeStoreWithPlainPane()
        store.send(.splitAfterFocusedPane)
        let notificationStore = NotificationStore(debounceInterval: 0.01)
        let committed = expectation(description: "paused notification committed")
        notificationStore.onChange = { committed.fulfill() }
        let center = RecordingProgramStatusNotificationCenter()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: center,
            notificationStore: notificationStore
        )

        store.handleTerminalEvent(paneID: paneID, event: .progressReport(report(.pause)))
        update(coordinator, with: store, windowIsKey: true)

        XCTAssertEqual(center.titles, ["cargo paused"])
        XCTAssertFalse(center.bodies.contains { $0.localizedCaseInsensitiveContains("input") })
        wait(for: [committed], timeout: 1)
        let notification = try XCTUnwrap(notificationStore.notifications.first)
        XCTAssertEqual(notification.state, .needsInput)
        XCTAssertEqual(notification.statusText, "Paused")
    }

    // MARK: - Helpers

    private func makeStoreWithPlainPane() throws -> (WorklaneStore, PaneID) {
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            currentDateProvider: { [unowned self] in now },
            readyStatusScheduler: { [unowned self] _, operation in
                let task = ProgramStatusPendingTask(operation: operation)
                pendingTasks.append(task)
                return task
            },
            programStatusEnabledProvider: { [unowned self] in programStatusEnabled }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "cargo build",
                currentWorkingDirectory: "/tmp/project",
                processName: "cargo",
                gitBranch: nil
            )
        )
        return (store, paneID)
    }

    private func update(
        _ coordinator: WorklaneAttentionNotificationCoordinator,
        with store: WorklaneStore,
        windowIsKey: Bool
    ) {
        coordinator.update(
            windowID: store.windowID,
            worklanes: store.worklanes,
            activeWorklaneID: store.activeWorklaneID,
            windowIsKey: windowIsKey
        )
    }

    private func runPendingTasks() {
        let tasks = pendingTasks
        pendingTasks.removeAll()
        tasks.forEach { $0.run() }
    }

    private func programStatus(_ store: WorklaneStore, _ paneID: PaneID) -> PaneProgramStatus? {
        store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.programStatus
    }

    private func presentation(_ store: WorklaneStore, _ paneID: PaneID) -> PanePresentationState? {
        store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation
    }

    private func report(_ state: TerminalProgressReport.State, _ progress: UInt8? = nil) -> TerminalProgressReport {
        TerminalProgressReport(state: state, progress: progress)
    }

    private func shellStatePayload(
        _ store: WorklaneStore,
        paneID: PaneID,
        activity: PaneShellActivityState,
        command: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .shellState,
            state: nil,
            shellActivityState: activity,
            shellCommand: command,
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}

@MainActor
private final class ProgramStatusPendingTask: WorklaneStoreScheduledHandle {
    private var isCancelled = false
    private let operation: @MainActor () -> Void

    init(operation: @escaping @MainActor () -> Void) {
        self.operation = operation
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled else { return }
        operation()
    }
}

@MainActor
private final class RecordingProgramStatusNotificationCenter: WorklaneAttentionUserNotificationCenter {
    private(set) var titles: [String] = []
    private(set) var bodies: [String] = []

    func requestAuthorizationIfNeeded() {}

    func add(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String?
    ) {
        titles.append(title)
        bodies.append(body)
    }
}
