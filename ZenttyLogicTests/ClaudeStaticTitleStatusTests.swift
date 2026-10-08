import XCTest
@testable import Zentty

/// Claude Code stops animating its terminal title when it sees a terminal
/// multiplexer (`TMUX`, `STY` or `ZELLIJ`) and writes "✳ <subject>" for the
/// whole session. Agent teams injects `TMUX` into every pane, so the idle
/// glyph must not be read as an Escape interrupt unless the title has been
/// seen animating (dedene/zentty#122). Captured from Claude Code 2.1.292:
///
///   no TMUX:  "✳ Claude Code" → "◐ Claude Code" → "◐/◑ Sleep 6" … → "✳ Sleep 6"
///   TMUX set: "✳ Claude Code" → "✳ Sleep command test"
@MainActor
final class ClaudeStaticTitleStatusTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 100)
    private var pendingTasks: [PendingTask] = []

    func test_static_idle_glyph_title_keeps_a_running_turn_running() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Sleep command test"))
        assertWorking(store, paneID: paneID)

        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()
        store.updateMetadata(
            paneID: paneID,
            metadata: claudeMetadata(title: "✳ Sleep command test", cwd: "/tmp/project/src")
        )

        assertWorking(store, paneID: paneID)
        XCTAssertFalse(try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]).raw.claudeCodeTitleHasAnimated)
    }

    func test_static_title_turn_still_completes_through_the_stop_hook() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Sleep command test"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle))

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(auxiliaryState.agentStatus?.state, .idle)
        XCTAssertEqual(auxiliaryState.presentation.runtimePhase, .idle)
        XCTAssertEqual(auxiliaryState.presentation.statusText, "Agent ready")
    }

    func test_animation_from_an_earlier_claude_session_does_not_carry_over() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // A plain Claude session animates its title...
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◐ Earlier task"))
        XCTAssertTrue(try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]).raw.claudeCodeTitleHasAnimated)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running, sessionID: "earlier"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle, sessionID: "earlier"))

        // ...then exits to the shell, and a later session runs under a
        // multiplexer with a static title.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "~/project",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )
        XCTAssertFalse(try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]).raw.claudeCodeTitleHasAnimated)

        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running, sessionID: "later"))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Later task"))
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertWorking(store, paneID: paneID)
    }

    func test_animated_title_still_reads_the_idle_glyph_as_an_interrupt() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◐ Sleep 6"))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◑ Sleep 6"))
        XCTAssertTrue(try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]).raw.claudeCodeTitleHasAnimated)

        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Sleep 6"))
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()
        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(auxiliaryState.agentStatus?.state, .idle)
        XCTAssertEqual(auxiliaryState.presentation.runtimePhase, .idle)
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Agent ready")
    }

    // MARK: - Interrupts under a static title
    //
    // Claude Code 2.1.292 with TMUX set: OSC 9;4;3 when a turn starts, 9;4;0
    // when it ends, ~80 ms after Escape or Ctrl-C mid-response. Escape that
    // only closes the `/btw` overlay sends nothing and the turn keeps going.

    func test_progress_cleared_on_a_static_title_ends_the_turn_without_agent_ready() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)

        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)
        reportProgress(store, paneID: paneID, .remove)
        // A short grace lets a hook that shows Claude still working win.
        assertWorking(store, paneID: paneID)

        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertInterrupted(store, paneID: paneID)
    }

    func test_escape_that_only_closes_an_overlay_keeps_the_turn_running() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)

        // `/btw`, then Escape to close it: progress stays on.
        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertWorking(store, paneID: paneID)
    }

    func test_natural_completion_keeps_agent_ready_when_progress_clears_before_stop() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)

        reportProgress(store, paneID: paneID, .remove)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle))
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
    }

    func test_hook_within_the_grace_window_keeps_the_turn_running() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)

        reportProgress(store, paneID: paneID, .remove)
        now = now.addingTimeInterval(1)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertWorking(store, paneID: paneID)
    }

    func test_progress_cleared_on_an_animated_title_is_left_to_the_title() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◐ Sleep 6"))
        reportProgress(store, paneID: paneID, .indeterminate)

        reportProgress(store, paneID: paneID, .remove)
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertWorking(store, paneID: paneID)
    }

    func test_progress_cleared_without_earlier_progress_is_ignored() throws {
        // Claude also sends 9;4;0 at startup, before any turn.
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))

        reportProgress(store, paneID: paneID, .remove)
        now = now.addingTimeInterval(PaneAgentReducerState.stopGraceWindow + 0.1)
        runPendingTasks()

        assertWorking(store, paneID: paneID)
    }

    func test_interrupt_hook_on_a_static_title_ends_the_turn_without_agent_ready() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)

        store.applyAgentStatusPayload(
            claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .interrupt)
        )

        assertInterrupted(store, paneID: paneID)
    }

    func test_turn_after_an_interrupt_still_completes_with_agent_ready() throws {
        let store = makeStore()
        let paneID = try startStaticTitleTurn(store)
        store.applyAgentStatusPayload(
            claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .interrupt)
        )

        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle))

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText,
            "Agent ready"
        )
    }

    // MARK: - Helpers

    private func startStaticTitleTurn(_ store: WorklaneStore) throws -> PaneID {
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        reportProgress(store, paneID: paneID, .remove)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        reportProgress(store, paneID: paneID, .indeterminate)
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Lighthouse keeper story"))
        assertWorking(store, paneID: paneID)
        return paneID
    }

    private func reportProgress(_ store: WorklaneStore, paneID: PaneID, _ state: TerminalProgressReport.State) {
        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: state, progress: nil))
        )
    }

    private func assertInterrupted(
        _ store: WorklaneStore,
        paneID: PaneID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let auxiliaryState = store.activeWorklane?.auxiliaryStateByPaneID[paneID]
        XCTAssertEqual(auxiliaryState?.agentStatus?.state, .idle, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.runtimePhase, .idle, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.raw.wantsReadyStatus, false, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.raw.showsReadyStatus, false, file: file, line: line)
        XCTAssertNotEqual(auxiliaryState?.presentation.statusText, "Agent ready", file: file, line: line)
    }

    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            currentDateProvider: { [unowned self] in now },
            readyStatusScheduler: { [unowned self] _, operation in
                let task = PendingTask(operation: operation)
                pendingTasks.append(task)
                return task
            }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        store.knownNonRepositoryPaths.insert("/tmp/project/src")
        return store
    }

    private func runPendingTasks() {
        let tasks = pendingTasks
        pendingTasks.removeAll()
        tasks.forEach { $0.run() }
    }

    private func assertWorking(
        _ store: WorklaneStore,
        paneID: PaneID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let auxiliaryState = store.activeWorklane?.auxiliaryStateByPaneID[paneID]
        XCTAssertEqual(auxiliaryState?.agentStatus?.state, .running, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.runtimePhase, .running, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.isWorking, true, file: file, line: line)
    }

    private func claudeMetadata(title: String, cwd: String = "/tmp/project") -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: cwd,
            processName: "claude",
            gitBranch: "main"
        )
    }

    private func claudePayload(
        _ store: WorklaneStore,
        paneID: PaneID,
        state: PaneAgentState,
        sessionID: String = "claude-session",
        lifecycleEvent: AgentLifecycleEvent? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            lifecycleEvent: lifecycleEvent,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}

@MainActor
private final class PendingTask: WorklaneStoreScheduledHandle {
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
        isCancelled = true
        operation()
    }
}
