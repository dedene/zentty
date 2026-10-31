import XCTest
@testable import Zentty

@MainActor
final class LiveAgentSessionIndexTests: XCTestCase {
    private let windowA = WindowID("win-index-a")
    private let windowB = WindowID("win-index-b")
    private let worklaneID = WorklaneID("wl-1")
    private let firstID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
    private let secondID = "11111111-2222-4333-8444-555555555555"

    func test_start_builds_snapshot_and_change_notifies_once_per_runloop() {
        let store = makeStore(windowA, sessions: [(pane: "pn-1", id: firstID, pid: 10)])
        let index = makeIndex(sources: [source(windowA, store)], alive: [10, 11])

        index.start()
        addTeardownBlock { @MainActor in index.stop() }

        XCTAssertEqual(index.snapshot.liveKeys, [key(firstID)])

        var notifications: [LiveAgentSessionSnapshot] = []
        let notified = expectation(description: "onChange")
        notified.assertForOverFulfill = true
        index.onChange = { snapshot in
            notifications.append(snapshot)
            notified.fulfill()
        }

        addSession(to: store, pane: "pn-2", id: secondID, pid: 11)
        store.notify(.paneStructure(worklaneID))
        store.notify(.auxiliaryStateUpdated(worklaneID, PaneID("pn-2"), [.sidebar]))
        store.notify(.worklaneListChanged)
        store.notify(.activeWorklaneChanged)

        XCTAssertEqual(index.snapshot.liveKeys, [key(firstID)], "rebuild waits for the next main-queue turn")
        wait(for: [notified], timeout: 2)
        drainMainQueue()

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(index.snapshot.liveKeys, [key(firstID), key(secondID)])
        XCTAssertEqual(notifications.first, index.snapshot)

        // A relevant change that moves nothing does not notify.
        store.notify(.auxiliaryStateUpdated(worklaneID, PaneID("pn-1"), [.sidebar]))
        drainMainQueue()
        XCTAssertEqual(notifications.count, 1)
    }

    func test_irrelevant_changes_do_not_refresh() {
        let store = makeStore(windowA, sessions: [(pane: "pn-1", id: firstID, pid: 10)])
        let index = makeIndex(sources: [source(windowA, store)], alive: [10, 11])
        index.start()
        addTeardownBlock { @MainActor in index.stop() }
        var notificationCount = 0
        index.onChange = { _ in notificationCount += 1 }

        addSession(to: store, pane: "pn-2", id: secondID, pid: 11)
        store.notify(.focusChanged(worklaneID))
        store.notify(.layoutResized(worklaneID, animation: .immediate))
        store.notify(.volatileAgentTitleUpdated(worklaneID: worklaneID, paneID: PaneID("pn-2")))
        store.notify(.teamAnchorsChanged(worklaneID))
        store.notify(.historyChanged)
        drainMainQueue()

        XCTAssertEqual(notificationCount, 0)
        XCTAssertEqual(index.snapshot.liveKeys, [key(firstID)])

        index.refreshNow()

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(index.snapshot.liveKeys, [key(firstID), key(secondID)])
    }

    func test_stop_unsubscribes_from_all_stores() {
        let storeA = makeStore(windowA, sessions: [(pane: "pn-1", id: firstID, pid: 10)])
        let storeB = makeStore(windowB, sessions: [])
        let baselineA = storeA.subscriberCountForTesting
        let baselineB = storeB.subscriberCountForTesting
        let index = makeIndex(sources: [source(windowA, storeA), source(windowB, storeB)], alive: [10, 11])

        index.start()

        XCTAssertEqual(storeA.subscriberCountForTesting, baselineA + 1)
        XCTAssertEqual(storeB.subscriberCountForTesting, baselineB + 1)

        var notificationCount = 0
        index.onChange = { _ in notificationCount += 1 }
        addSession(to: storeB, pane: "pn-2", id: secondID, pid: 11)
        storeB.notify(.paneStructure(worklaneID))
        index.stop()
        drainMainQueue()

        XCTAssertEqual(storeA.subscriberCountForTesting, baselineA)
        XCTAssertEqual(storeB.subscriberCountForTesting, baselineB)
        XCTAssertEqual(notificationCount, 0, "a refresh scheduled before stop must not run")
    }

    func test_refresh_follows_windows_that_open_after_start() {
        let storeA = makeStore(windowA, sessions: [(pane: "pn-1", id: firstID, pid: 10)])
        let storeB = makeStore(windowB, sessions: [])
        var sources = [source(windowA, storeA)]
        let index = LiveAgentSessionIndex(
            sources: { sources },
            preferredWindowID: { nil },
            isProcessAlive: { [10, 11].contains($0) }
        )
        index.start()
        addTeardownBlock { @MainActor in index.stop() }
        let baselineB = storeB.subscriberCountForTesting

        sources.append(source(windowB, storeB))
        index.refreshNow()

        XCTAssertEqual(storeB.subscriberCountForTesting, baselineB + 1)
        addSession(to: storeB, pane: "pn-2", id: secondID, pid: 11)
        let notified = expectation(description: "onChange")
        index.onChange = { _ in notified.fulfill() }
        storeB.notify(.paneStructure(worklaneID))
        wait(for: [notified], timeout: 2)
        XCTAssertEqual(index.snapshot.primaryLocation(for: key(secondID))?.windowID, windowB)
    }

    func test_relevance_matches_changes_that_can_move_a_session() {
        XCTAssertTrue(LiveAgentSessionIndex.isRelevant(.paneStructure(worklaneID)))
        XCTAssertTrue(LiveAgentSessionIndex.isRelevant(.auxiliaryStateUpdated(worklaneID, PaneID("pn-1"), [.sidebar])))
        XCTAssertTrue(LiveAgentSessionIndex.isRelevant(.worklaneListChanged))
        XCTAssertTrue(LiveAgentSessionIndex.isRelevant(.activeWorklaneChanged))
        XCTAssertFalse(LiveAgentSessionIndex.isRelevant(.focusChanged(worklaneID)))
        XCTAssertFalse(LiveAgentSessionIndex.isRelevant(.historyChanged))
    }

    // MARK: - Helpers

    private func key(_ id: String) -> AgentHistorySessionKey {
        AgentHistorySessionKey(agent: .claude, nativeID: id)
    }

    private func makeIndex(sources: [MenuBarWorklaneSource], alive: Set<Int32>) -> LiveAgentSessionIndex {
        LiveAgentSessionIndex(
            sources: { sources },
            preferredWindowID: { nil },
            isProcessAlive: { alive.contains($0) }
        )
    }

    private func source(_ windowID: WindowID, _ store: WorklaneStore) -> MenuBarWorklaneSource {
        MenuBarWorklaneSource(windowID: windowID, windowTitle: "Zentty", worklaneStore: store)
    }

    private func makeStore(_ windowID: WindowID, sessions: [(pane: String, id: String, pid: Int32)]) -> WorklaneStore {
        let panes = sessions.map { PaneState(id: PaneID($0.pane), title: "claude") }
        let auxiliary = Dictionary(uniqueKeysWithValues: sessions.map {
            (PaneID($0.pane), PaneAuxiliaryState(agentStatus: status(id: $0.id, pid: $0.pid)))
        })
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(panes: panes, focusedPaneID: panes.first?.id),
            auxiliaryStateByPaneID: auxiliary
        )
        return WorklaneStore(windowID: windowID, worklanes: [worklane])
    }

    private func addSession(to store: WorklaneStore, pane: String, id: String, pid: Int32) {
        let paneID = PaneID(pane)
        var worklane = store.worklanes[0]
        worklane.paneStripState = PaneStripState(
            panes: worklane.paneStripState.panes + [PaneState(id: paneID, title: "claude")],
            focusedPaneID: worklane.paneStripState.panes.first?.id ?? paneID
        )
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(agentStatus: status(id: id, pid: pid))
        store.worklanes[0] = worklane
    }

    private func status(id: String, pid: Int32) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            trackedPID: pid,
            sessionID: id
        )
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}
