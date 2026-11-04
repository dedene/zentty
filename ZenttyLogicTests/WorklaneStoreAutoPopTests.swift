import CoreGraphics
import XCTest
@testable import Zentty

/// Auto-pop: a pill whose agent needs input pops up as a bottom-trailing PiP
/// (active worklane, floats shown, setting on) and goes back to its pill when
/// the agent moves on, unless the user touched it.
@MainActor
final class WorklaneStoreAutoPopTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")
    private let otherWorklaneID = WorklaneID("wl_other")
    private let tileID = PaneID("pn_tile")
    private let agentID = PaneID("pn_agent")
    private let otherTileID = PaneID("pn_other")
    private let sessionID = "5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"

    // MARK: - Fixtures

    /// `wl_main`: a tile and a Claude Code pane (`pn_agent`, running) that is
    /// floated and minimized to a pill. `wl_other`: one tile.
    private func makeStore(autoPop: Bool = true) -> WorklaneStore {
        let shellContext = PaneShellContext(
            scope: .local,
            path: "/tmp/project",
            home: "/Users/peter",
            user: "peter",
            host: nil
        )
        let agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            workingDirectory: "/tmp/project",
            sessionID: sessionID
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [
                            makePane(tileID, title: "shell"),
                            makePane(agentID, title: "agent"),
                        ],
                        focusedPaneID: agentID
                    ),
                    nextPaneNumber: 3,
                    auxiliaryStateByPaneID: [
                        tileID: PaneAuxiliaryState(shellContext: shellContext),
                        agentID: PaneAuxiliaryState(shellContext: shellContext, agentStatus: agentStatus),
                    ]
                ),
                WorklaneState(
                    id: otherWorklaneID,
                    title: nil,
                    paneStripState: PaneStripState(panes: [makePane(otherTileID, title: "other")], focusedPaneID: otherTileID),
                    nextPaneNumber: 2,
                    auxiliaryStateByPaneID: [otherTileID: PaneAuxiliaryState(shellContext: shellContext)]
                ),
            ],
            activeWorklaneID: worklaneID,
            autoPopNeedsInputProvider: { autoPop }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        store.floatPane(agentID, canvas: canvas, tileFrame: nil)
        store.minimizePane(agentID)
        return store
    }

    private func makePane(_ id: PaneID, title: String) -> PaneState {
        PaneState(
            id: id,
            title: title,
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
            width: 420
        )
    }

    private func main(_ store: WorklaneStore) -> WorklaneState? {
        store.worklanes.first { $0.id == worklaneID }
    }

    private func mode(_ store: WorklaneStore) -> FloatingPaneMode? {
        main(store)?.floatingPane(id: agentID)?.mode
    }

    private func autoPopped(_ store: WorklaneStore) -> Bool {
        main(store)?.auxiliaryStateByPaneID[agentID]?.autoPopped ?? false
    }

    private func payload(_ state: PaneAgentState) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: nil,
            worklaneID: worklaneID,
            paneID: agentID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitAPI,
            toolName: "Claude Code",
            text: state == .needsInput ? "Approval requested: edit Sources/App.swift" : nil,
            interactionKind: state == .needsInput ? .approval : nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func needsInput(_ store: WorklaneStore) {
        store.applyAgentStatusPayload(payload(.needsInput))
        XCTAssertTrue(
            WorklaneStore.floatNeedsInput(agentID, in: try! XCTUnwrap(main(store))),
            "precondition: the agent reads as needing input"
        )
    }

    private func resume(_ store: WorklaneStore) {
        store.applyAgentStatusPayload(payload(.running))
        XCTAssertFalse(
            WorklaneStore.floatNeedsInput(agentID, in: try! XCTUnwrap(main(store))),
            "precondition: the agent no longer needs input"
        )
    }

    // MARK: - Pop and return

    func test_needs_input_pops_pill_to_bottom_trailing_pip() {
        let store = makeStore()
        XCTAssertEqual(mode(store), .minimized(order: 0), "precondition: pill")
        let focusBefore = main(store)?.focusedPaneID

        needsInput(store)

        XCTAssertEqual(mode(store), .pip(corner: .bottomRight, order: 0))
        XCTAssertTrue(autoPopped(store))
        XCTAssertEqual(main(store)?.focusedPaneID, focusBefore, "a PiP never takes focus")
    }

    func test_pop_notifies_floats_before_subscribers_see_the_status_change() {
        let store = makeStore()
        var modesSeen: [FloatingPaneMode?] = []
        let subscription = store.subscribe { change in
            if case .auxiliaryStateUpdated = change {
                modesSeen.append(self.mode(store))
            }
        }

        needsInput(store)

        XCTAssertEqual(modesSeen.first, .pip(corner: .bottomRight, order: 0))
        withExtendedLifetime(subscription) {}
    }

    func test_resume_returns_untouched_pip_to_its_pill() {
        let store = makeStore()
        needsInput(store)

        resume(store)

        XCTAssertEqual(mode(store), .minimized(order: 0))
        XCTAssertFalse(autoPopped(store))
    }

    func test_repeated_needs_input_updates_pop_once() {
        let store = makeStore()
        needsInput(store)
        store.minimizePane(agentID)

        needsInput(store)

        XCTAssertEqual(mode(store), .minimized(order: 0), "putting a popped PiP away sticks while it still needs input")
    }

    func test_pops_again_on_the_next_needs_input() {
        let store = makeStore()
        needsInput(store)
        resume(store)

        needsInput(store)

        XCTAssertEqual(mode(store), .pip(corner: .bottomRight, order: 0))
        XCTAssertTrue(autoPopped(store))
    }

    func test_minimizing_a_float_that_already_needs_input_does_not_pop() {
        let store = makeStore()
        store.restoreFloat(agentID)
        needsInput(store)
        XCTAssertEqual(mode(store), .floating, "precondition: a float is left alone")

        store.minimizePane(agentID)

        XCTAssertEqual(mode(store), .minimized(order: 0))
    }

    // MARK: - Where it does not pop

    func test_hidden_floats_keep_the_pill_and_stay_hidden() {
        let store = makeStore()
        store.setFloatsHidden(true)

        needsInput(store)

        XCTAssertEqual(mode(store), .minimized(order: 0))
        XCTAssertEqual(main(store)?.floatsHidden, true, "auto-pop never un-hides")
        XCTAssertFalse(autoPopped(store))
    }

    func test_inactive_worklane_keeps_the_pill() {
        let store = makeStore()
        store.selectWorklane(id: otherWorklaneID)

        needsInput(store)

        XCTAssertEqual(mode(store), .minimized(order: 0))
        XCTAssertEqual(store.activeWorklaneID, otherWorklaneID)
    }

    func test_no_pop_on_switching_back_to_a_worklane_that_needs_input() {
        let store = makeStore()
        store.selectWorklane(id: otherWorklaneID)
        needsInput(store)

        store.selectWorklane(id: worklaneID)

        XCTAssertEqual(mode(store), .minimized(order: 0))
    }

    func test_setting_off_keeps_the_pill() {
        let store = makeStore(autoPop: false)

        needsInput(store)

        XCTAssertEqual(mode(store), .minimized(order: 0))
    }

    func test_pip_and_float_are_not_moved_by_needs_input() {
        let store = makeStore()
        store.pipPane(agentID, corner: .topLeft)

        needsInput(store)
        resume(store)

        XCTAssertEqual(mode(store), .pip(corner: .topLeft, order: 0), "only pills pop; a user's PiP stays")
    }

    // MARK: - User touched it

    func test_moved_pip_stays_when_agent_resumes() {
        let store = makeStore()
        needsInput(store)
        store.movePip(agentID, to: .topLeft)

        resume(store)

        XCTAssertEqual(mode(store), .pip(corner: .topLeft, order: 0))
    }

    func test_restored_float_stays_when_agent_resumes() {
        let store = makeStore()
        needsInput(store)
        store.restoreFloat(agentID)

        resume(store)

        XCTAssertEqual(mode(store), .floating)
    }

    func test_touched_pip_stays_when_agent_resumes() {
        let store = makeStore()
        needsInput(store)
        store.markFloatTouched(agentID)

        resume(store)

        XCTAssertEqual(mode(store), .pip(corner: .bottomRight, order: 0))
    }

    func test_popped_pip_returns_even_after_switching_worklanes() {
        let store = makeStore()
        needsInput(store)
        store.selectWorklane(id: otherWorklaneID)
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }

        resume(store)

        XCTAssertEqual(mode(store), .minimized(order: 0))
        XCTAssertFalse(autoPopped(store))
        XCTAssertTrue(changes.contains(.floats(worklaneID)))
        XCTAssertEqual(store.activeWorklaneID, otherWorklaneID)
        withExtendedLifetime(subscription) {}
    }

    func test_closed_float_leaves_the_tracking_set() {
        let store = makeStore()
        needsInput(store)
        XCTAssertTrue(store.autoPopNeedsInputPaneIDs.contains(agentID))

        _ = store.closePane(id: agentID)

        XCTAssertFalse(store.autoPopNeedsInputPaneIDs.contains(agentID))
    }
}
