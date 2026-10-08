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

    // MARK: - Helpers

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
        sessionID: String = "claude-session"
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
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
