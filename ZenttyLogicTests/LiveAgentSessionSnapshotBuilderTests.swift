import XCTest
@testable import Zentty

@MainActor
final class LiveAgentSessionSnapshotBuilderTests: XCTestCase {
    private let windowA = WindowID("win-a")
    private let windowB = WindowID("win-b")
    private let claudeRawID = "0B6C1D8E-4B1A-4C55-9A1E-3F4B2C6D7E8F"
    private let claudeID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
    private let codexID = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"

    private var claudeKey: AgentHistorySessionKey {
        AgentHistorySessionKey(agent: .claude, nativeID: claudeID)
    }

    private var codexKey: AgentHistorySessionKey {
        AgentHistorySessionKey(agent: .codex, nativeID: codexID)
    }

    // MARK: - Liveness

    func test_status_session_with_live_pid_is_live() throws {
        let source = makeSource(windowA, title: "Main window", panes: [
            pane("pn-1", title: "claude", status: status(.claudeCode, id: claudeID, pid: 100, cwd: "/Users/test/src/zentty")),
        ])

        let snapshot = build([source], alive: [100])

        XCTAssertTrue(snapshot.isLive(claudeKey))
        XCTAssertEqual(snapshot.liveKeys, [claudeKey])
        let location = try XCTUnwrap(snapshot.primaryLocation(for: claudeKey))
        XCTAssertEqual(location.windowID, windowA)
        XCTAssertEqual(location.worklaneID, WorklaneID("wl-1"))
        XCTAssertEqual(location.paneID, PaneID("pn-1"))
        XCTAssertEqual(location.tool, .claudeCode)
        XCTAssertEqual(location.pid, 100)
        XCTAssertEqual(location.matchSource, .status)
        XCTAssertEqual(location.windowTitle, "Main window")
        XCTAssertEqual(location.workingDirectory, "/Users/test/src/zentty")
        XCTAssertEqual(snapshot.allPrimaryLocations, [location])
    }

    func test_status_session_with_dead_pid_is_not_live() {
        let source = makeSource(windowA, panes: [
            pane("pn-1", status: status(.claudeCode, id: claudeID, pid: 100)),
        ])

        let snapshot = build([source], alive: [])

        XCTAssertFalse(snapshot.isLive(claudeKey))
        XCTAssertTrue(snapshot.liveKeys.isEmpty)
        XCTAssertTrue(snapshot.allPrimaryLocations.isEmpty)
    }

    func test_metadata_only_session_is_live() throws {
        var auxiliary = PaneAuxiliaryState()
        auxiliary.raw.agentMetadata = PaneAgentMetadata(tool: .codex, sessionID: codexID, pid: 200)
        let source = makeSource(windowA, panes: [(PaneState(id: PaneID("pn-1"), title: "shell"), auxiliary)])

        let snapshot = build([source], alive: [200])

        let location = try XCTUnwrap(snapshot.primaryLocation(for: codexKey))
        XCTAssertEqual(location.matchSource, .metadata)
        XCTAssertEqual(location.pid, 200)
        XCTAssertEqual(location.tool, .codex)
    }

    func test_reducer_root_session_is_live_and_child_sessions_ignored() throws {
        let childID = "11111111-2222-4333-8444-555555555555"
        var reducer = PaneAgentReducerState()
        reducer.sessionsByID[claudeID] = reducerSession(id: claudeID, parent: nil, pid: 300)
        reducer.sessionsByID[childID] = reducerSession(id: childID, parent: claudeID, pid: 300)
        let auxiliary = PaneAuxiliaryState(agentReducerState: reducer)
        let source = makeSource(windowA, panes: [(PaneState(id: PaneID("pn-1"), title: "claude"), auxiliary)])

        let snapshot = build([source], alive: [300])

        let location = try XCTUnwrap(snapshot.primaryLocation(for: claudeKey))
        XCTAssertEqual(location.matchSource, .reducer)
        XCTAssertEqual(location.pid, 300)
        XCTAssertFalse(snapshot.isLive(AgentHistorySessionKey(agent: .claude, nativeID: childID)))
        XCTAssertEqual(snapshot.liveKeys, [claudeKey])
    }

    func test_session_without_pid_is_live_only_when_foreground_agent_matches_tool() throws {
        var matching = PaneAuxiliaryState(agentStatus: status(.claudeCode, id: claudeID, pid: nil))
        matching.raw.foregroundAgentSnapshot = foreground(.claudeCode, pid: 400)
        var mismatched = PaneAuxiliaryState(agentStatus: status(.codex, id: codexID, pid: nil))
        mismatched.raw.foregroundAgentSnapshot = foreground(.claudeCode, pid: 401)
        let reducerOnlyID = "22222222-3333-4444-8555-666666666666"
        var reducer = PaneAgentReducerState()
        reducer.sessionsByID[reducerOnlyID] = reducerSession(id: reducerOnlyID, parent: nil, pid: nil)
        var reducerOnly = PaneAuxiliaryState(agentReducerState: reducer)
        reducerOnly.raw.foregroundAgentSnapshot = foreground(.claudeCode, pid: 402)
        let source = makeSource(windowA, panes: [
            (PaneState(id: PaneID("pn-match"), title: "claude"), matching),
            (PaneState(id: PaneID("pn-mismatch"), title: "codex"), mismatched),
            (PaneState(id: PaneID("pn-reducer"), title: "claude"), reducerOnly),
        ])

        let snapshot = build([source], alive: [])

        let location = try XCTUnwrap(snapshot.primaryLocation(for: claudeKey))
        XCTAssertEqual(location.pid, 400)
        XCTAssertFalse(snapshot.isLive(codexKey))
        XCTAssertFalse(snapshot.isLive(AgentHistorySessionKey(agent: .claude, nativeID: reducerOnlyID)))
        XCTAssertEqual(snapshot.liveKeys, [claudeKey])
    }

    func test_restored_pending_pane_is_not_live() {
        var auxiliary = PaneAuxiliaryState(agentStatus: status(.claudeCode, id: claudeID, pid: 500))
        auxiliary.raw.restoredAgentRestoreDraft = PaneRestoreDraft(
            paneID: "pn-1",
            kind: .agentResume,
            toolName: AgentTool.claudeCode.displayName,
            sessionID: claudeID,
            workingDirectory: "/Users/test/src/zentty",
            trackedPID: 500
        )
        auxiliary.raw.restoredAgentAutoResumePending = true
        let source = makeSource(windowA, panes: [(PaneState(id: PaneID("pn-1"), title: "claude"), auxiliary)])

        let snapshot = build([source], alive: [500])

        XCTAssertFalse(snapshot.isLive(claudeKey))
        XCTAssertTrue(snapshot.liveKeys.isEmpty)
    }

    func test_placeholder_session_ids_ignored() {
        let placeholder = "pane-\(AgentTool.codex.displayName.lowercased())"
        XCTAssertNotNil(AgentHistoryAgent.codex.normalizedSessionID(placeholder), "placeholder must pass the id validator for this test to mean anything")
        let source = makeSource(windowA, panes: [
            pane("pn-1", status: status(.codex, id: placeholder, pid: 600)),
        ])

        let snapshot = build([source], alive: [600])

        XCTAssertTrue(snapshot.liveKeys.isEmpty)
    }

    func test_remote_panes_ignored() {
        let auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .remote, path: "/project", home: nil, user: nil, host: "server"),
            agentStatus: status(.claudeCode, id: claudeID, pid: 700)
        )
        let source = makeSource(windowA, panes: [(PaneState(id: PaneID("pn-1"), title: "claude"), auxiliary)])

        let snapshot = build([source], alive: [700])

        XCTAssertTrue(snapshot.liveKeys.isEmpty)
    }

    func test_unsupported_tools_ignored() {
        let source = makeSource(windowA, panes: [
            pane("pn-gemini", status: status(.gemini, id: claudeID, pid: 800)),
            pane("pn-bad-id", status: status(.claudeCode, id: "not-a-session-id", pid: 801)),
        ])

        let snapshot = build([source], alive: [800, 801])

        XCTAssertTrue(snapshot.liveKeys.isEmpty)
    }

    // MARK: - Matching and ordering

    func test_matches_across_multiple_windows() throws {
        let sourceA = makeSource(windowA, title: "Window A", panes: [
            pane("pn-a", status: status(.claudeCode, id: claudeID, pid: 10)),
        ])
        let sourceB = makeSource(windowB, title: "Window B", panes: [
            pane("pn-b", status: status(.codex, id: codexID, pid: 20)),
        ])

        let snapshot = build([sourceA, sourceB], alive: [10, 20])

        XCTAssertEqual(snapshot.liveKeys, [claudeKey, codexKey])
        XCTAssertEqual(snapshot.primaryLocation(for: claudeKey)?.windowID, windowA)
        XCTAssertEqual(snapshot.primaryLocation(for: claudeKey)?.windowTitle, "Window A")
        XCTAssertEqual(snapshot.primaryLocation(for: codexKey)?.windowID, windowB)
        XCTAssertEqual(snapshot.primaryLocation(for: codexKey)?.paneID, PaneID("pn-b"))
    }

    func test_multiple_matching_panes_prefer_presenting_window_then_status_then_recent() throws {
        // Presenting window beats stronger evidence elsewhere.
        var metadataOnly = PaneAuxiliaryState()
        metadataOnly.raw.agentMetadata = PaneAgentMetadata(tool: .claudeCode, sessionID: claudeID, pid: 31)
        let otherWindow = makeSource(windowA, panes: [
            pane("pn-status", status: status(.claudeCode, id: claudeID, pid: 30, updatedAt: 50)),
        ])
        let presentingWindow = makeSource(windowB, panes: [
            (PaneState(id: PaneID("pn-metadata"), title: "claude"), metadataOnly),
        ])

        let byWindow = build([otherWindow, presentingWindow], preferred: windowB, alive: [30, 31])

        XCTAssertEqual(byWindow.primaryLocation(for: claudeKey)?.paneID, PaneID("pn-metadata"))
        XCTAssertEqual(byWindow.locationsByKey[claudeKey]?.map(\.paneID), [PaneID("pn-metadata"), PaneID("pn-status")])

        // Same window: status beats a newer metadata match.
        var newerMetadata = PaneAuxiliaryState()
        newerMetadata.raw.agentMetadata = PaneAgentMetadata(tool: .claudeCode, sessionID: claudeID, pid: 41)
        newerMetadata.presentation.updatedAt = Date(timeIntervalSince1970: 900)
        let sameWindow = makeSource(windowA, panes: [
            (PaneState(id: PaneID("pn-a-metadata"), title: "claude"), newerMetadata),
            pane("pn-b-status", status: status(.claudeCode, id: claudeID, pid: 40, updatedAt: 10)),
        ])

        let byEvidence = build([sameWindow], preferred: windowA, alive: [40, 41])

        XCTAssertEqual(byEvidence.primaryLocation(for: claudeKey)?.paneID, PaneID("pn-b-status"))

        // Same window and evidence: the most recent update wins.
        let recency = makeSource(windowA, panes: [
            pane("pn-a-old", status: status(.claudeCode, id: claudeID, pid: 50, updatedAt: 10)),
            pane("pn-b-new", status: status(.claudeCode, id: claudeID, pid: 51, updatedAt: 20)),
        ])

        let byRecency = build([recency], preferred: nil, alive: [50, 51])

        XCTAssertEqual(byRecency.primaryLocation(for: claudeKey)?.paneID, PaneID("pn-b-new"))
        XCTAssertEqual(byRecency.allPrimaryLocations.count, 1)
    }

    func test_one_pane_reports_one_location_per_session_with_the_strongest_source() throws {
        var reducer = PaneAgentReducerState()
        reducer.sessionsByID[claudeID] = reducerSession(id: claudeID, parent: nil, pid: 60)
        var auxiliary = PaneAuxiliaryState(
            agentStatus: status(.claudeCode, id: claudeID, pid: 60),
            agentReducerState: reducer
        )
        auxiliary.raw.agentMetadata = PaneAgentMetadata(tool: .claudeCode, sessionID: claudeID, pid: 60)
        let source = makeSource(windowA, panes: [(PaneState(id: PaneID("pn-1"), title: "claude"), auxiliary)])

        let snapshot = build([source], alive: [60])

        XCTAssertEqual(snapshot.locationsByKey[claudeKey]?.count, 1)
        XCTAssertEqual(snapshot.primaryLocation(for: claudeKey)?.matchSource, .status)
    }

    func test_uuid_case_differences_still_match() throws {
        let source = makeSource(windowA, panes: [
            pane("pn-1", status: status(.claudeCode, id: claudeRawID, pid: 70)),
        ])

        let snapshot = build([source], alive: [70])

        let location = try XCTUnwrap(snapshot.primaryLocation(for: claudeKey))
        XCTAssertEqual(location.key.nativeID, claudeID)
        XCTAssertEqual(location.rawSessionID, claudeRawID)
    }

    func test_display_names_come_from_menu_bar_primary_text() throws {
        let worklanes = [
            WorklaneState(
                id: WorklaneID("wl-named"),
                title: "Release work",
                paneStripState: PaneStripState(panes: [PaneState(id: PaneID("pn-named"), title: "shell")], focusedPaneID: nil),
                auxiliaryStateByPaneID: [PaneID("pn-named"): PaneAuxiliaryState()]
            ),
            WorklaneState(
                id: WorklaneID("wl-unnamed"),
                title: nil,
                paneStripState: PaneStripState(panes: [PaneState(id: PaneID("pn-agent"), title: "claude")], focusedPaneID: nil),
                auxiliaryStateByPaneID: [
                    PaneID("pn-agent"): PaneAuxiliaryState(
                        agentStatus: status(.claudeCode, id: claudeID, pid: 80, cwd: "/Users/test/src/zentty")
                    ),
                ]
            ),
        ]
        let source = MenuBarWorklaneSource(
            windowID: windowA,
            windowTitle: "Zentty",
            worklaneStore: WorklaneStore(windowID: windowA, worklanes: worklanes)
        )
        let menuText = try XCTUnwrap(
            MenuBarPaneSnapshotBuilder.snapshots(from: [source]).first { $0.paneID == PaneID("pn-agent") }?.primaryText
        )

        let snapshot = build([source], alive: [80])

        let location = try XCTUnwrap(snapshot.primaryLocation(for: claudeKey))
        XCTAssertEqual(location.paneDisplayName, menuText)
        XCTAssertNotEqual(location.paneDisplayName, "claude", "the agent name is not a useful pane name")
        XCTAssertEqual(location.worklaneDisplayName, "Worklane 2")
    }

    func test_resume_source_from_live_location_has_no_row_and_keeps_pane_context() throws {
        let source = makeSource(windowA, panes: [
            pane("pn-1", title: "Fix the sidebar", status: status(.claudeCode, id: claudeRawID, pid: 90, cwd: "/Users/test/src/zentty")),
        ])
        let location = try XCTUnwrap(build([source], alive: [90]).primaryLocation(for: claudeKey))

        let resume = AgentHistoryResumeSource(live: location)

        XCTAssertNil(resume.sessionRowID)
        XCTAssertEqual(resume.key, claudeKey)
        XCTAssertEqual(resume.title, "Fix the sidebar")
        XCTAssertEqual(resume.workingDirectory, "/Users/test/src/zentty")
        XCTAssertNil(resume.sourceRoot)
        XCTAssertNil(resume.model)
    }

    // MARK: - Helpers

    private func build(
        _ sources: [MenuBarWorklaneSource],
        preferred: WindowID? = nil,
        alive: Set<Int32>
    ) -> LiveAgentSessionSnapshot {
        LiveAgentSessionSnapshotBuilder.snapshot(
            from: sources,
            preferredWindowID: preferred,
            isProcessAlive: { alive.contains($0) }
        )
    }

    private func makeSource(
        _ windowID: WindowID,
        title: String = "Zentty",
        panes: [(PaneState, PaneAuxiliaryState)]
    ) -> MenuBarWorklaneSource {
        let worklane = WorklaneState(
            id: WorklaneID("wl-1"),
            title: nil,
            paneStripState: PaneStripState(panes: panes.map(\.0), focusedPaneID: panes.first?.0.id),
            auxiliaryStateByPaneID: Dictionary(uniqueKeysWithValues: panes.map { ($0.0.id, $0.1) })
        )
        return MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: title,
            worklaneStore: WorklaneStore(windowID: windowID, worklanes: [worklane])
        )
    }

    private func pane(
        _ id: String,
        title: String = "claude",
        status: PaneAgentStatus
    ) -> (PaneState, PaneAuxiliaryState) {
        (PaneState(id: PaneID(id), title: title), PaneAuxiliaryState(agentStatus: status))
    }

    private func status(
        _ tool: AgentTool,
        id: String,
        pid: Int32?,
        updatedAt: TimeInterval = 1,
        cwd: String? = nil
    ) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: tool,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            trackedPID: pid,
            workingDirectory: cwd,
            sessionID: id
        )
    }

    private func reducerSession(id: String, parent: String?, pid: Int32?) -> PaneAgentSessionState {
        PaneAgentSessionState(
            sessionID: id,
            parentSessionID: parent,
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 5),
            source: .explicit,
            origin: .explicitHook,
            interactionKind: .none,
            confidence: .explicit,
            shellActivityState: .unknown,
            trackedPID: pid,
            hasObservedRunning: true,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )
    }

    private func foreground(_ tool: AgentTool, pid: Int32) -> PaneForegroundAgentSnapshot {
        PaneForegroundAgentSnapshot(
            agent: PaneForegroundAgent(tool: tool, pid: pid, launchPIDs: [pid]),
            foregroundPIDs: [pid]
        )
    }
}
