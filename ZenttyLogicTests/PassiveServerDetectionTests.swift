import XCTest
@testable import Zentty

@MainActor
final class PassiveServerDetectionTests: XCTestCase {
    func test_snapshot_includesPaneRootPIDInScannerContext() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        applyPaneContext(path: "/tmp/project", paneID: paneID, to: store)
        applyRootPID(4242, paneID: paneID, to: store)

        let snapshot = PassiveServerDetectionSnapshot(worklanes: store.worklanes)

        let context = try XCTUnwrap(snapshot.contexts.single)
        let pane = try XCTUnwrap(context.scanner.panes.single)
        XCTAssertEqual(pane.paneID, paneID)
        XCTAssertEqual(pane.workingDirectory, "/tmp/project")
        XCTAssertEqual(pane.shellPID, 4242)
    }

    func test_snapshot_continuesPollingWhileLocalPaneCommandIsRunning() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        applyPaneContext(path: "/tmp/project", paneID: paneID, to: store)
        applyShellActivity(.commandRunning, paneID: paneID, to: store)

        let snapshot = PassiveServerDetectionSnapshot(worklanes: store.worklanes)

        XCTAssertTrue(snapshot.shouldContinuePolling)
    }

    func test_snapshot_stopsPollingWhenLocalPaneReturnsToPrompt() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        applyPaneContext(path: "/tmp/project", paneID: paneID, to: store)
        applyShellActivity(.promptIdle, paneID: paneID, to: store)

        let snapshot = PassiveServerDetectionSnapshot(worklanes: store.worklanes)

        XCTAssertFalse(snapshot.shouldContinuePolling)
    }

    func test_snapshot_excludesRemotePaneFromPassiveDetection() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        applyPaneContext(scope: .remote, path: "/tmp/project", paneID: paneID, to: store)
        applyShellActivity(.commandRunning, paneID: paneID, to: store)

        let snapshot = PassiveServerDetectionSnapshot(worklanes: store.worklanes)

        XCTAssertTrue(snapshot.contexts.isEmpty)
        XCTAssertFalse(snapshot.shouldContinuePolling)
    }

    func test_snapshot_tracksWorklanesWithoutPassiveDetectionContexts() throws {
        let localStore = WorklaneStore()
        let localWorklaneID = localStore.worklanes[0].id
        let localPaneID = try XCTUnwrap(localStore.activeWorklane?.paneStripState.focusedPaneID)
        applyPaneContext(path: "/tmp/project", paneID: localPaneID, to: localStore)

        let remoteStore = WorklaneStore()
        let remotePaneID = try XCTUnwrap(remoteStore.activeWorklane?.paneStripState.focusedPaneID)
        applyPaneContext(scope: .remote, path: "/tmp/remote-project", paneID: remotePaneID, to: remoteStore)

        let remoteWorklane = WorklaneState(
            id: WorklaneID("worklane-remote"),
            title: "Remote",
            paneStripState: remoteStore.worklanes[0].paneStripState,
            auxiliaryStateByPaneID: remoteStore.worklanes[0].auxiliaryStateByPaneID
        )

        let snapshot = PassiveServerDetectionSnapshot(worklanes: [localStore.worklanes[0], remoteWorklane])

        XCTAssertEqual(snapshot.contexts.map(\.worklaneID), [localWorklaneID])
        XCTAssertEqual(snapshot.worklaneIDsWithoutContexts, [WorklaneID("worklane-remote")])
    }

    func test_dockerCadenceRunsImmediatelyThenEveryConfiguredRunningPoll() {
        var cadence = PassiveServerDetectionDockerCadence(pollEveryRunningScanCount: 3)

        XCTAssertTrue(cadence.shouldDiscoverDocker())
        XCTAssertFalse(cadence.shouldDiscoverDocker())
        XCTAssertFalse(cadence.shouldDiscoverDocker())
        XCTAssertTrue(cadence.shouldDiscoverDocker())
        XCTAssertFalse(cadence.shouldDiscoverDocker())
    }

    func test_resultTrackerAppliesInitialEmptyScannerResult() {
        var tracker = PassiveServerDetectionResultTracker()

        XCTAssertTrue(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: []))
        XCTAssertFalse(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: []))
    }

    func test_resultTrackerSkipsUnchangedScannerResultIgnoringUpdatedAt() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var tracker = PassiveServerDetectionResultTracker()

        let first = try detectedServer(origin: "http://localhost:3000", paneID: paneID, updatedAt: Date(timeIntervalSince1970: 100))
        let later = try detectedServer(origin: "http://localhost:3000", paneID: paneID, updatedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: [first]))
        XCTAssertFalse(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: [later]))
    }

    func test_resultTrackerAppliesWhenScannerResultChanges() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        var tracker = PassiveServerDetectionResultTracker()

        let first = try detectedServer(origin: "http://localhost:3000", paneID: paneID, updatedAt: Date(timeIntervalSince1970: 100))
        let changed = try detectedServer(origin: "http://localhost:5173", paneID: paneID, updatedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: [first]))
        XCTAssertTrue(tracker.shouldApplyScannerResult(worklaneID: WorklaneID("worklane-main"), servers: [changed]))
    }

    private func applyPaneContext(
        scope: PaneShellContextScope = .local,
        path: String,
        paneID: PaneID,
        to store: WorklaneStore
    ) {
        store.applyAgentStatusPayload(payload(
            paneID: paneID,
            signalKind: .paneContext,
            paneContext: PaneShellContext(
                scope: scope,
                path: path,
                home: "/tmp",
                user: "peter",
                host: "mac"
            )
        ))
    }

    private func applyRootPID(_ pid: Int32, paneID: PaneID, to store: WorklaneStore) {
        store.applyAgentStatusPayload(payload(
            paneID: paneID,
            signalKind: .paneRootPID,
            pid: pid,
            pidEvent: .attach
        ))
    }

    private func applyShellActivity(
        _ state: PaneShellActivityState,
        paneID: PaneID,
        to store: WorklaneStore
    ) {
        store.applyAgentStatusPayload(payload(
            paneID: paneID,
            signalKind: .shellState,
            shellActivityState: state
        ))
    }

    private func payload(
        paneID: PaneID,
        signalKind: AgentSignalKind,
        shellActivityState: PaneShellActivityState? = nil,
        pid: Int32? = nil,
        pidEvent: AgentPIDSignalEvent? = nil,
        paneContext: PaneShellContext? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: paneID,
            signalKind: signalKind,
            state: nil,
            shellActivityState: shellActivityState,
            pid: pid,
            pidEvent: pidEvent,
            paneContext: paneContext,
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func detectedServer(
        origin: String,
        paneID: PaneID?,
        updatedAt: Date
    ) throws -> DetectedServer {
        let url = try XCTUnwrap(URL(string: origin))
        return DetectedServer(
            id: "scanner:\(origin)",
            origin: origin,
            url: url,
            display: origin,
            worklaneID: WorklaneID("worklane-main"),
            paneID: paneID,
            source: .scanner,
            ports: [try XCTUnwrap(url.port)],
            confidence: .cwd,
            updatedAt: updatedAt
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
