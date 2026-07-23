import AppKit
import XCTest

@testable import Zentty

/// Unit tests for the control-lease manager (spec §2.6): clamp + grant semantics,
/// heartbeat-driven expiry, resize debounce, supersede, and the release /
/// pane-closed / takeback / disconnect end paths. The takeover application is
/// behind the `CompanionLeaseTakeoverApplying` seam, and the 15s expiry / 300ms
/// resize debounce run on a virtual clock so nothing waits on wall time.
@MainActor
final class CompanionLeaseManagerTests: XCTestCase {
    // MARK: - Test doubles

    /// Records takeover applications and restores; hands back each pane's takeback
    /// closure so tests can fire the desktop "Take Back Control" path.
    private final class FakeApplier: CompanionLeaseTakeoverApplying {
        private(set) var applied: [(paneId: String, cols: Int, rows: Int, deviceName: String)] = []
        private(set) var restored: [String] = []
        var onTakeBackByPane: [String: () -> Void] = [:]
        var applyResult = true

        @discardableResult
        func companionApplyLeaseTakeover(
            paneId: String,
            cols: Int,
            rows: Int,
            deviceName: String,
            onTakeBack: @escaping () -> Void
        ) -> Bool {
            applied.append((paneId, cols, rows, deviceName))
            onTakeBackByPane[paneId] = onTakeBack
            return applyResult
        }

        func companionRestoreLeasedPane(paneId: String) {
            restored.append(paneId)
        }
    }

    /// A controllable clock + sleeper: `now()` is authoritative for elapsed time,
    /// and `sleep` parks a continuation the test releases to "tick" the manager's
    /// expiry loop and resize debounce.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: TimeInterval = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var requested: [TimeInterval] = []

        func now() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ delta: TimeInterval) {
            lock.lock(); current += delta; lock.unlock()
        }

        func sleep(_ seconds: TimeInterval) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                requested.append(seconds)
                waiters.append(continuation)
                lock.unlock()
            }
        }

        var parkedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return waiters.count
        }

        func waitForWaiters(_ count: Int) async {
            while parkedCount < count { await Task.yield() }
        }

        func releaseAll() {
            lock.lock()
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    // MARK: - Helpers

    private func makeManager(applier: FakeApplier, clock: VirtualClock) -> CompanionLeaseManager {
        CompanionLeaseManager(
            applier: applier,
            sleep: { await clock.sleep($0) },
            now: { clock.now() }
        )
    }

    private func drainTasks(_ rounds: Int = 40) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    // MARK: - Grant + clamp

    func testGrantPassesInRangeGridThroughAndFlagsClientLimiting() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        let grant = manager.request(token: token, paneId: "p1", cols: 45, rows: 30, deviceName: "iPhone")

        XCTAssertEqual(grant.effective, CompanionGrid(cols: 45, rows: 30))
        XCTAssertEqual(grant.client, CompanionGrid(cols: 45, rows: 30))
        XCTAssertTrue(grant.isCurrentClientLimiting) // clamp changed nothing
        XCTAssertEqual(grant.heartbeatIntervalMs, 5000)
        XCTAssertEqual(grant.expiryMs, 15000)
        XCTAssertEqual(applier.applied.count, 1)
        XCTAssertEqual(applier.applied.first?.cols, 45)
        XCTAssertEqual(applier.applied.first?.rows, 30)
        XCTAssertEqual(applier.applied.first?.deviceName, "iPhone")
        XCTAssertTrue(revocations.isEmpty)
        await drainTasks()
    }

    func testGrantClampsOutOfRangeGridAndClearsClientLimiting() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        let token = manager.addClient { _ in }

        // cols above max (500) and rows below min (5) are both clamped.
        let grant = manager.request(token: token, paneId: "p1", cols: 900, rows: 2, deviceName: "iPad")

        XCTAssertEqual(grant.client, CompanionGrid(cols: 900, rows: 2))
        XCTAssertEqual(grant.effective, CompanionGrid(cols: 500, rows: 5))
        XCTAssertFalse(grant.isCurrentClientLimiting) // clamp changed the grid
        XCTAssertEqual(applier.applied.first?.cols, 500)
        XCTAssertEqual(applier.applied.first?.rows, 5)
        await drainTasks()
    }

    // MARK: - Heartbeat + expiry

    func testHeartbeatBeforeExpiryKeepsLeaseAliveThenExpiresWhenMissed() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        let grant = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        await clock.waitForWaiters(1) // expiry loop parked

        // Heartbeat lands at t=5.
        clock.advance(5)
        manager.heartbeat(token: token, leaseId: grant.leaseId)

        // A tick at t=15: only 10s since the heartbeat → re-arms, no expiry.
        clock.advance(10)
        clock.releaseAll()
        await drainTasks()
        XCTAssertTrue(revocations.isEmpty)
        XCTAssertTrue(applier.restored.isEmpty)
        await clock.waitForWaiters(1) // re-armed

        // A tick at t=25: 20s since the heartbeat → expires exactly once.
        clock.advance(10)
        clock.releaseAll()
        await drainTasks()
        XCTAssertEqual(revocations.count, 1)
        XCTAssertEqual(revocations.first?.reason, .expired)
        XCTAssertEqual(revocations.first?.leaseId, grant.leaseId)
        XCTAssertEqual(applier.restored, ["p1"])

        // No further ticks re-fire the expiry.
        clock.releaseAll()
        await drainTasks()
        XCTAssertEqual(revocations.count, 1)
        XCTAssertEqual(applier.restored, ["p1"])
    }

    // MARK: - Resize debounce

    func testResizeDebouncesToASingleReapply() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        let token = manager.addClient { _ in }

        let grant = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        await clock.waitForWaiters(1) // expiry loop

        manager.resize(leaseId: grant.leaseId, cols: 50, rows: 35)
        manager.resize(leaseId: grant.leaseId, cols: 60, rows: 45)
        await clock.waitForWaiters(3) // expiry + two resize debounces parked

        clock.releaseAll()
        await drainTasks()

        // Only the trailing resize applied (initial grant + one debounced resize).
        XCTAssertEqual(applier.applied.count, 2)
        XCTAssertEqual(applier.applied.last?.cols, 60)
        XCTAssertEqual(applier.applied.last?.rows, 45)
        // The two debounce sleeps both requested the 300ms delay.
        XCTAssertTrue(clock.requested.contains(0.3))
    }

    // MARK: - Supersede

    func testNewRequestSupersedesCurrentHolder() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)

        var revocationsA: [CompanionLeaseRevoked] = []
        var revocationsB: [CompanionLeaseRevoked] = []
        let tokenA = manager.addClient { revocationsA.append($0) }
        let tokenB = manager.addClient { revocationsB.append($0) }

        let grantA = manager.request(token: tokenA, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone A")
        let grantB = manager.request(token: tokenB, paneId: "p1", cols: 45, rows: 35, deviceName: "iPhone B")

        XCTAssertNotEqual(grantA.leaseId, grantB.leaseId)
        // Old holder was revoked as superseded; new holder got no revocation.
        XCTAssertEqual(revocationsA.count, 1)
        XCTAssertEqual(revocationsA.first?.reason, .superseded)
        XCTAssertEqual(revocationsA.first?.leaseId, grantA.leaseId)
        XCTAssertTrue(revocationsB.isEmpty)
        // Both grids were applied; supersede does NOT restore in between.
        XCTAssertEqual(applier.applied.count, 2)
        XCTAssertTrue(applier.restored.isEmpty)
        await drainTasks()
    }

    // MARK: - Release / pane-closed / takeback

    func testReleaseRestoresWithoutRevoking() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        let grant = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        manager.release(leaseId: grant.leaseId)

        // Phone-initiated release restores but sends no lease.revoked.
        XCTAssertTrue(revocations.isEmpty)
        XCTAssertEqual(applier.restored, ["p1"])
        await drainTasks()
    }

    func testPaneClosedRevokesAndRestores() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        let grant = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        manager.handlePaneClosed(paneId: "p1")

        XCTAssertEqual(revocations.count, 1)
        XCTAssertEqual(revocations.first?.reason, .paneClosed)
        XCTAssertEqual(revocations.first?.leaseId, grant.leaseId)
        XCTAssertEqual(applier.restored, ["p1"])
        await drainTasks()
    }

    func testTakebackRevokesAndRestores() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        let grant = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")

        // Fire the desktop "Take Back Control" closure the applier was handed.
        XCTAssertNotNil(applier.onTakeBackByPane["p1"])
        applier.onTakeBackByPane["p1"]?()

        XCTAssertEqual(revocations.count, 1)
        XCTAssertEqual(revocations.first?.reason, .takeback)
        XCTAssertEqual(revocations.first?.leaseId, grant.leaseId)
        XCTAssertEqual(applier.restored, ["p1"])
        await drainTasks()
    }

    // MARK: - Disconnect grace

    func testDisconnectDoesNotRevokeInstantlyButLeaseStillExpires() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        _ = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        await clock.waitForWaiters(1)

        // Disconnect: no instant revoke, no restore — the lease is untouched.
        manager.removeClient(token)
        await drainTasks()
        XCTAssertTrue(revocations.isEmpty)
        XCTAssertTrue(applier.restored.isEmpty)

        // The expiry timer keeps running: after 15s idle the pane restores.
        clock.advance(15)
        clock.releaseAll()
        await drainTasks()
        XCTAssertEqual(applier.restored, ["p1"])
        // The client was detached, so no revocation is delivered — but the pane is
        // never stranded.
        XCTAssertTrue(revocations.isEmpty)
    }

    // MARK: - revokeAll (app teardown)

    func testRevokeAllRestoresEveryLeasedPane() async {
        let applier = FakeApplier()
        let clock = VirtualClock()
        let manager = makeManager(applier: applier, clock: clock)
        var revocations: [CompanionLeaseRevoked] = []
        let token = manager.addClient { revocations.append($0) }

        _ = manager.request(token: token, paneId: "p1", cols: 40, rows: 30, deviceName: "iPhone")
        _ = manager.request(token: token, paneId: "p2", cols: 45, rows: 35, deviceName: "iPhone")

        manager.revokeAll()

        XCTAssertEqual(Set(applier.restored), ["p1", "p2"])
        XCTAssertEqual(Set(revocations.map(\.reason)), [.takeback])
        XCTAssertEqual(revocations.count, 2)
        await drainTasks()
    }
}

/// Detached AppKit component test for the desktop placeholder: it builds without
/// a window and its Take Back Control button fires the injected callback.
@MainActor
final class CompanionLeasePlaceholderViewTests: XCTestCase {
    func testPlaceholderBuildsAndNamesTheControllingDevice() {
        let view = CompanionLeasePlaceholderView(deviceName: "Peter's iPhone", onTakeBack: {})
        XCTAssertTrue(view.messageTextForTesting.contains("Peter's iPhone"))
        XCTAssertFalse(view.subviews.isEmpty)
    }

    func testBlankDeviceNameFallsBackToGenericLabel() {
        let view = CompanionLeasePlaceholderView(deviceName: "   ", onTakeBack: {})
        XCTAssertTrue(view.messageTextForTesting.contains("another device"))
    }

    func testUpdateDeviceNameRewritesTheMessage() {
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", onTakeBack: {})
        view.updateDeviceName("iPad Pro")
        XCTAssertTrue(view.messageTextForTesting.contains("iPad Pro"))
    }

    func testTakeBackButtonFiresCallback() {
        var fired = 0
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", onTakeBack: { fired += 1 })
        view.simulateTakeBackTapForTesting()
        XCTAssertEqual(fired, 1)
    }
}
