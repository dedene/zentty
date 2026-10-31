import CoreGraphics
import XCTest
@testable import Zentty

/// Agent status, IPC, discovery and close-confirmation paths must see a
/// floated pane (float, PiP or pill) as a live pane (audit sweep B).
@MainActor
final class WorklaneStoreFloatStatusTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")
    private let tileID = PaneID("pn_tile")
    private let agentID = PaneID("pn_agent")
    private let sessionID = "5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"

    // MARK: - Fixtures

    /// Two tiles (`pn_tile`, `pn_agent`, the latter running Claude Code in
    /// /tmp/project); `pn_agent` is focused.
    private func makeStore(agentRunning: Bool = true) -> WorklaneStore {
        let shellContext = PaneShellContext(
            scope: .local,
            path: "/tmp/project",
            home: "/Users/peter",
            user: "peter",
            host: nil
        )
        let agentStatus = agentRunning
            ? PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                workingDirectory: "/tmp/project",
                sessionID: sessionID
            )
            : nil
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: tileID,
                                title: "shell",
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                                width: 420
                            ),
                            PaneState(
                                id: agentID,
                                title: "agent",
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                                width: 420
                            ),
                        ],
                        focusedPaneID: agentID
                    ),
                    nextPaneNumber: 3,
                    auxiliaryStateByPaneID: [
                        tileID: PaneAuxiliaryState(shellContext: shellContext),
                        agentID: PaneAuxiliaryState(shellContext: shellContext, agentStatus: agentStatus),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        return store
    }

    private func main(_ store: WorklaneStore) -> WorklaneState? {
        store.worklanes.first { $0.id == worklaneID }
    }

    private func floatAgent(_ store: WorklaneStore) {
        store.floatPane(agentID, canvas: canvas, tileFrame: nil)
        XCTAssertTrue(main(store)?.isFloating(agentID) ?? false, "precondition: agent pane floated")
    }

    private func needsInputPayload(
        _ paneID: PaneID,
        worklaneID: WorklaneID? = nil,
        windowID: WindowID? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: windowID,
            worklaneID: worklaneID ?? self.worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: .needsInput,
            origin: .explicitAPI,
            toolName: "Claude Code",
            text: "Approval requested: edit Sources/App.swift",
            interactionKind: .approval,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func recordChanges(_ store: WorklaneStore) -> (subscription: WorklaneChangeSubscription, changes: () -> [WorklaneChange]) {
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }
        return (subscription, { changes })
    }

    // MARK: - Agent status

    func test_agent_status_payload_lands_on_minimized_float() throws {
        let store = makeStore()
        floatAgent(store)
        store.minimizePane(agentID)
        let recorder = recordChanges(store)

        store.applyAgentStatusPayload(needsInputPayload(agentID))

        let aux = try XCTUnwrap(main(store)?.auxiliaryStateByPaneID[agentID])
        XCTAssertEqual(aux.agentStatus?.state, .needsInput)
        XCTAssertEqual(aux.agentStatus?.interactionKind, .approval)
        XCTAssertTrue(recorder.changes().contains(where: {
            if case .auxiliaryStateUpdated(let id, let paneID, _) = $0 {
                return id == worklaneID && paneID == agentID
            }
            return false
        }))
        let attention = try XCTUnwrap(WorklaneAttentionSummaryBuilder.summary(for: XCTUnwrap(main(store))))
        XCTAssertEqual(attention.paneID, agentID)
        withExtendedLifetime(recorder.subscription) {}
    }

    func test_agent_status_payload_for_float_from_another_window_id_still_lands() throws {
        let store = makeStore()
        floatAgent(store)
        store.pipPane(agentID)

        store.applyAgentStatusPayload(
            needsInputPayload(agentID, worklaneID: WorklaneID("wl_stale"), windowID: WindowID("wd_other"))
        )

        XCTAssertEqual(main(store)?.auxiliaryStateByPaneID[agentID]?.agentStatus?.state, .needsInput)
    }

    func test_metadata_and_title_updates_reach_a_float() throws {
        let store = makeStore(agentRunning: false)
        floatAgent(store)

        store.updateMetadata(
            paneID: agentID,
            metadata: TerminalMetadata(title: "vim notes.md", currentWorkingDirectory: "/tmp/project", processName: "vim")
        )
        XCTAssertEqual(main(store)?.auxiliaryStateByPaneID[agentID]?.metadata?.processName, "vim")

        let recorder = recordChanges(store)
        XCTAssertTrue(store.setPaneCustomTitle("  notes  ", on: agentID))
        XCTAssertEqual(main(store)?.pane(id: agentID)?.customTitle, "notes")
        XCTAssertTrue(recorder.changes().contains(.floats(worklaneID)))
        XCTAssertFalse(store.setPaneCustomTitle("notes", on: agentID), "unchanged title is a no-op")
        withExtendedLifetime(recorder.subscription) {}
    }

    func test_check_back_on_focused_float_counts_as_current_visit() throws {
        let store = makeStore(agentRunning: false)
        floatAgent(store)
        let worklaneIndex = try XCTUnwrap(store.worklanes.firstIndex { $0.id == worklaneID })
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[agentID]?.agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .idle,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            sessionID: sessionID
        )
        store.recomputePresentation(for: agentID, in: &store.worklanes[worklaneIndex])
        XCTAssertEqual(main(store)?.focusedPaneID, agentID, "precondition: float owns focus")
        guard store.unreadToggle(for: agentID) == .markUnread else {
            throw XCTSkip("idle Claude pane does not offer Mark as Unread in this configuration")
        }

        XCTAssertTrue(store.toggleUnread(paneID: agentID))

        XCTAssertEqual(
            main(store)?.auxiliaryStateByPaneID[agentID]?.raw.checkBackReminder,
            PaneCheckBackReminder(hasLeftPane: false)
        )
    }

    // MARK: - Events, discovery, IPC

    func test_pane_event_snapshot_includes_floats() throws {
        let store = makeStore()
        let before = PaneEventSnapshot.make(windows: [
            (windowID: WindowID("wd_1"), activeWorklaneID: worklaneID, worklanes: store.worklanes),
        ])

        floatAgent(store)
        let after = PaneEventSnapshot.make(windows: [
            (windowID: WindowID("wd_1"), activeWorklaneID: worklaneID, worklanes: store.worklanes),
        ])

        XCTAssertNotNil(after.panes[agentID.rawValue])
        XCTAssertEqual(after.worklanes[worklaneID.rawValue]?.focusedPaneID, agentID.rawValue)
        let types = PaneEventSnapshot.diff(from: before, to: after).map(\.type)
        XCTAssertFalse(types.contains("pane.closed"), "floating a pane is not a close")
        XCTAssertFalse(types.contains("pane.created"), "floating a pane is not a create")
    }

    func test_discovery_lists_floated_pane() throws {
        let store = makeStore()
        floatAgent(store)
        store.minimizePane(agentID)
        let executor = makeExecutor(store: store)

        let entries = executor.paneListEntries(for: worklaneID)

        XCTAssertEqual(entries.map(\.id), [tileID.rawValue, agentID.rawValue])
        XCTAssertEqual(entries.map(\.index), [1, 2])
        XCTAssertEqual(entries.map(\.column), [1, 0])
        XCTAssertEqual(entries.map(\.mode), [nil, "minimized"])
        XCTAssertEqual(executor.resolvePaneID("2", in: worklaneID), agentID)
        XCTAssertEqual(executor.resolvePaneID(agentID.rawValue, in: worklaneID), agentID)
        XCTAssertNil(executor.resolvePaneID("3", in: worklaneID))
    }

    func test_pane_list_entry_mode_is_optional_on_the_wire() throws {
        let legacy = #"{"index":1,"id":"pn_a","column":1,"title":"a","isFocused":true}"#
        let decoded = try JSONDecoder().decode(PaneListEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.mode)

        let float = PaneListEntry(
            index: 2, id: "pn_b", column: 0, title: "b", workingDirectory: nil,
            isFocused: false, agentTool: nil, agentStatus: nil, mode: "pip"
        )
        let roundTrip = try JSONDecoder().decode(PaneListEntry.self, from: JSONEncoder().encode(float))
        XCTAssertEqual(roundTrip, float)
    }

    // MARK: - Close confirmation

    func test_close_confirmation_counts_running_float() throws {
        let store = makeStore(agentRunning: false)
        floatAgent(store)
        let worklaneIndex = try XCTUnwrap(store.worklanes.firstIndex { $0.id == worklaneID })
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[agentID]?.shellActivityState = .commandRunning

        let paneContext = try XCTUnwrap(store.paneCloseConfirmationContext(agentID))
        XCTAssertEqual(paneContext.reason, .runningProcess)

        let worklaneContext = try XCTUnwrap(store.worklaneCloseConfirmationContext(worklaneID))
        XCTAssertEqual(worklaneContext.runningPaneCount, 1)
        XCTAssertEqual(worklaneContext.paneCount, 2)
    }

    func test_close_confirmation_selection_restores_focus_to_float() throws {
        let store = makeStore()
        floatAgent(store)
        let snapshot = try XCTUnwrap(
            CloseConfirmationSelectionSnapshot.capture(worklanes: store.worklanes, activeWorklaneID: worklaneID)
        )
        XCTAssertEqual(snapshot.paneID, agentID)

        store.focusPane(id: tileID)

        XCTAssertEqual(
            snapshot.restoreAction(worklanes: store.worklanes, activeWorklaneID: worklaneID),
            .selectWorklaneAndFocusPane(worklaneID, agentID)
        )
    }

    // MARK: - Fork

    func test_fork_from_floated_agent_pane() throws {
        let store = makeStore()
        floatAgent(store)
        let stripBefore = main(store)?.paneStripState

        let result = try store.forkAgentConversation(paneID: agentID, destination: .splitRight)

        let worklane = try XCTUnwrap(main(store))
        XCTAssertEqual(result.worklaneID, worklaneID)
        XCTAssertEqual(worklane.paneStripState, stripBefore, "a float fork never touches the strip")
        let fork = try XCTUnwrap(worklane.floatingPane(id: result.paneID))
        XCTAssertEqual(fork.mode, .floating)
        XCTAssertEqual(fork.pane.sessionRequest.workingDirectory, "/tmp/project")
        XCTAssertEqual(
            fork.pane.sessionRequest.command,
            "claude --resume \(sessionID) --fork-session"
        )
        XCTAssertFalse(fork.pane.sessionRequest.replaysCommandOnRestore)
        XCTAssertEqual(worklane.focusedPaneID, result.paneID)
        let source = try XCTUnwrap(worklane.floatingPane(id: agentID))
        XCTAssertNotEqual(fork.floatFrame, source.floatFrame, "fork opens offset from the source")
        XCTAssertNotNil(store.agentForkAvailability(for: agentID))
    }

    // MARK: - Helpers

    private func makeExecutor(store: WorklaneStore) -> PaneCommandExecutor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorklaneStoreFloatStatusTests-\(UUID().uuidString).toml")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PaneCommandExecutor(
            worklaneStore: store,
            configStore: AppConfigStore(fileURL: url),
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            canvas: FloatStatusStubCanvas(),
            hooks: PaneCommandExecutor.UIHooks(
                presentClosePaneConfirmation: { _, _ in },
                showToast: { _ in },
                requestWindowClose: {}
            )
        )
    }
}

@MainActor
private final class FloatStatusStubCanvas: PaneCanvasGeometry {
    var boundsSize = CGSize(width: 1200, height: 800)
    var leadingVisibleInset: CGFloat = 0

    func settlePaneStripPresentationNow() {}
    func centerFocusedInteriorPaneOnNextRender() {}
    func clearPendingPaneStripTargetOffsetOverride() {}
    func shiftPaneStripTargetOffsetOnNextRender(by: CGFloat) {}
}
