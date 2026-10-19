import XCTest
@testable import Zentty

private let firstSessionID = "8b0b8c2e-1d1f-4c3a-9a51-3c1b8f0f6a11"
private let secondSessionID = "5f7e3a90-2b4d-4e8e-8f0c-9d6a1b2c3d44"

/// A pane's resume draft must follow the agent process, not the sidebar
/// badge: the idle badge hides after `idleVisibilityWindow`, but a quit while
/// the agent still sits at its prompt has to bring the session back.
@MainActor
final class AgentResumeDraftLifecycleTests: XCTestCase {
    private let agentPID: Int32 = 999_999
    // Payloads reach the reducer stamped with the wall clock; sweeps use the
    // store's clock, so it starts there and only moves forward.
    private var now = Date()
    private var livePIDs: Set<Int32> = []

    override func setUp() {
        super.setUp()
        now = Date()
        livePIDs = [agentPID]
    }

    func test_claude_stop_keeps_resume_draft_past_grace_and_idle_window() throws {
        let store = makeStore()
        let paneID = try startClaudeTurn(store)
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle))

        advanceAndSweep(store, by: PaneAgentReducerState.stopGraceWindow + 1)
        XCTAssertEqual(agentStatus(store, paneID)?.state, .idle)
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)

        advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
        XCTAssertNil(agentStatus(store, paneID), "the idle badge still hides after its window")
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)
        XCTAssertEqual(draft(store)?.trackedPID, agentPID)
    }

    func test_stop_candidate_keeps_resume_draft_past_grace_and_idle_window() throws {
        let store = makeStore()
        let paneID = try startClaudeTurn(store)
        store.applyAgentStatusPayload(
            claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .stopCandidate)
        )

        advanceAndSweep(store, by: PaneAgentReducerState.stopGraceWindow + 1)
        XCTAssertEqual(agentStatus(store, paneID)?.state, .idle)
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)

        advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
        XCTAssertNil(agentStatus(store, paneID), "the idle badge still hides after its window")
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)
    }

    func test_idle_title_keeps_resume_draft_past_grace_and_idle_window() throws {
        let store = makeStore()
        let paneID = try startClaudeTurn(store)
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◐ Sleep 6"))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "◑ Sleep 6"))
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Sleep 6"))

        advanceAndSweep(store, by: PaneAgentReducerState.stopGraceWindow + 1)
        XCTAssertEqual(agentStatus(store, paneID)?.state, .idle)
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)

        // The Stop hook can land after the title's grace already expired.
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .idle))
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)

        advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
        XCTAssertNil(agentStatus(store, paneID), "the idle badge still hides after its window")
        XCTAssertEqual(draft(store)?.sessionID, firstSessionID)
    }

    func test_dead_agent_process_drops_resume_draft() throws {
        let store = makeStore()
        let paneID = try startClaudeTurn(store)
        store.applyAgentStatusPayload(
            claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .stopCandidate)
        )
        advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
        XCTAssertNotNil(draft(store))

        livePIDs = []
        advanceAndSweep(store, by: 1)

        XCTAssertNil(draft(store))
        XCTAssertTrue(try XCTUnwrap(auxiliaryState(store, paneID)).agentReducerState.sessionsByID.isEmpty)
    }

    func test_new_session_in_same_pane_replaces_resume_draft_session() throws {
        // `/clear` sends SessionEnd before the new SessionStart; a start
        // without it must still replace the old session in the same process.
        for sendsSessionEnd in [true, false] {
            let store = makeStore()
            let paneID = try startClaudeTurn(store)
            store.applyAgentStatusPayload(
                claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .stopCandidate)
            )
            advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
            XCTAssertEqual(draft(store)?.sessionID, firstSessionID)

            if sendsSessionEnd {
                for payload in sessionEndPayloads(store, paneID: paneID, sessionID: firstSessionID) {
                    store.applyAgentStatusPayload(payload)
                }
            }
            store.applyAgentStatusPayload(sessionStartPayload(store, paneID: paneID, sessionID: secondSessionID))
            XCTAssertEqual(draft(store)?.sessionID, secondSessionID, "sendsSessionEnd=\(sendsSessionEnd)")

            store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running, sessionID: secondSessionID))
            store.applyAgentStatusPayload(
                claudePayload(store, paneID: paneID, state: .idle, sessionID: secondSessionID, lifecycleEvent: .stopCandidate)
            )
            advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)

            XCTAssertEqual(draft(store)?.sessionID, secondSessionID, "sendsSessionEnd=\(sendsSessionEnd)")
            XCTAssertEqual(
                try XCTUnwrap(auxiliaryState(store, paneID)).agentReducerState.sessionsByID.keys.sorted(),
                [secondSessionID]
            )
        }
    }

    func test_agent_exit_to_shell_drops_resume_draft() throws {
        let store = makeStore()
        let paneID = try startClaudeTurn(store)
        store.applyAgentStatusPayload(
            claudePayload(store, paneID: paneID, state: .idle, lifecycleEvent: .stopCandidate)
        )
        advanceAndSweep(store, by: PaneAgentReducerState.idleVisibilityWindow + 1)
        XCTAssertNotNil(draft(store))

        for payload in sessionEndPayloads(store, paneID: paneID, sessionID: firstSessionID) {
            store.applyAgentStatusPayload(payload)
        }
        XCTAssertNil(draft(store), "SessionEnd releases the pane even before the process is reaped")

        livePIDs = []
        store.handleTerminalEvent(paneID: paneID, event: .commandFinished(exitCode: 0, durationNanoseconds: 1_000_000))
        advanceAndSweep(store, by: 1)
        XCTAssertNil(draft(store))
    }

    // MARK: - Helpers

    private func startClaudeTurn(_ store: WorklaneStore) throws -> PaneID {
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(paneID: paneID, metadata: claudeMetadata(title: "✳ Claude Code"))
        store.applyAgentStatusPayload(sessionStartPayload(store, paneID: paneID, sessionID: firstSessionID))
        store.applyAgentStatusPayload(claudePayload(store, paneID: paneID, state: .running))
        XCTAssertEqual(agentStatus(store, paneID)?.trackedPID, agentPID)
        return paneID
    }

    private func advanceAndSweep(_ store: WorklaneStore, by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        store.clearStaleAgentSessions(sweepContext: AgentSessionSweepContext(
            processAliveResolver: { [unowned self] in livePIDs.contains($0) },
            workingDirectoryResolver: { _ in nil },
            foregroundAgentResolver: { _ in nil }
        ))
    }

    private func draft(_ store: WorklaneStore) -> PaneRestoreDraft? {
        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: store.worklanes,
            isProcessAlive: { [unowned self] in livePIDs.contains($0) },
            resolveLiveAgentPID: { _, _ in nil }
        )
        return drafts?.paneDrafts.first
    }

    private func auxiliaryState(_ store: WorklaneStore, _ paneID: PaneID) -> PaneAuxiliaryState? {
        store.activeWorklane?.auxiliaryStateByPaneID[paneID]
    }

    private func agentStatus(_ store: WorklaneStore, _ paneID: PaneID) -> PaneAgentStatus? {
        auxiliaryState(store, paneID)?.agentStatus
    }

    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            currentDateProvider: { [unowned self] in now },
            // Sweeps run explicitly through `advanceAndSweep`.
            readyStatusScheduler: { _, _ in InertScheduledTask() }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        return store
    }

    private func claudeMetadata(title: String) -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: "main"
        )
    }

    /// Mirrors `ClaudeEventAdapter`'s SessionStart: a pid attach that also
    /// carries the root session's metadata.
    private func sessionStartPayload(_ store: WorklaneStore, paneID: PaneID, sessionID: String) -> AgentStatusPayload {
        var payload = AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: agentPID,
            pidEvent: .attach,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        payload.carriesRootMetadata = true
        payload.agentMetadataPID = agentPID
        return payload
    }

    /// Mirrors `ClaudeEventAdapter.claudeClearPayloads` for SessionEnd.
    private func sessionEndPayloads(_ store: WorklaneStore, paneID: PaneID, sessionID: String) -> [AgentStatusPayload] {
        let clear = AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            state: nil,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let pidClear = AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: nil,
            pidEvent: .clear,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        return [clear, pidClear].map { payload in
            var payload = payload
            payload.carriesRootMetadata = true
            payload.agentMetadataPID = agentPID
            return payload
        }
    }

    private func claudePayload(
        _ store: WorklaneStore,
        paneID: PaneID,
        state: PaneAgentState,
        sessionID: String = firstSessionID,
        lifecycleEvent: AgentLifecycleEvent? = .update
    ) -> AgentStatusPayload {
        var payload = AgentStatusPayload(
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
        payload.carriesRootMetadata = true
        payload.agentMetadataPID = agentPID
        return payload
    }
}

@MainActor
private final class InertScheduledTask: WorklaneStoreScheduledHandle {
    func cancel() {}
}
