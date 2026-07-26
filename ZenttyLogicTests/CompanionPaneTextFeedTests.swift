import XCTest

@testable import Zentty

/// Unit tests for the pane text lane: `CompanionPaneTextFeed`'s debounce/dedupe/
/// fan-out and `CompanionInputRouter`'s key map. The readText/surface dependency
/// is behind the `CompanionPaneTextProviding` seam, and the 150ms debounce is
/// driven by a manual sleeper (virtual clock) so nothing waits on wall time.
@MainActor
final class CompanionPaneTextFeedTests: XCTestCase {
    // MARK: - Test doubles

    /// Fakes the readText/grid-size chain. Records the scrollback line limits it
    /// was asked for so the one-shot path can be asserted.
    private final class FakePaneTextProvider: CompanionPaneTextProviding {
        var viewport: [String: CompanionPaneTextReadout] = [:]
        var scrollback: [String: CompanionPaneTextReadout] = [:]
        private(set) var scrollbackLineLimits: [Int?] = []
        /// Ordered log of render-keepalive toggles, so the occlusion gate seam can
        /// be asserted without a live surface.
        private(set) var keepAliveLog: [(paneId: String, active: Bool)] = []

        func companionReadPaneText(
            paneId: String,
            includeScrollback: Bool,
            lineLimit: Int?
        ) -> CompanionPaneTextReadout? {
            if includeScrollback {
                scrollbackLineLimits.append(lineLimit)
                return scrollback[paneId]
            }
            return viewport[paneId]
        }

        func companionSetPaneRenderKeepAlive(paneId: String, active: Bool) {
            keepAliveLog.append((paneId, active))
        }
    }

    /// A controllable debounce clock: every `sleep` parks a continuation and
    /// records the requested delay; the test releases them to fire the trailing
    /// edge deterministically.
    private final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var requested: [TimeInterval] = []

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

        /// Suspends until at least `count` sleepers are parked.
        func waitForWaiters(_ count: Int) async {
            while parkedCount < count {
                await Task.yield()
            }
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

    private func readout(_ text: String, cols: Int = 80, rows: Int = 24) -> CompanionPaneTextReadout {
        CompanionPaneTextReadout(text: text, gridCols: cols, gridRows: rows, cursorRow: nil)
    }

    /// Lets already-scheduled main-actor tasks run to completion.
    private func drainTasks(_ rounds: Int = 30) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    // MARK: - Debounced streaming

    func testContentChangeBurstYieldsSingleDebouncedText() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        // The pane has not painted yet at watch time (no initial snapshot); this
        // test exercises the debounced pulse path in isolation.
        feed.watch(token: token, paneId: "p1")
        provider.viewport["p1"] = readout("hello world", cols: 120, rows: 40)

        for _ in 0..<5 { feed.handleContentChanged(paneId: "p1") }
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.paneId, "p1")
        XCTAssertEqual(received.first?.seq, 1)
        XCTAssertEqual(received.first?.viewport, "hello world")
        XCTAssertEqual(received.first?.gridCols, 120)
        XCTAssertEqual(received.first?.gridRows, 40)
        XCTAssertFalse(received.first?.truncatedScrollback ?? true)
        // Throttle: only the window-opening pulse schedules a timer; the rest
        // of the burst coalesces into it instead of stacking timers.
        XCTAssertEqual(sleeper.requested, [0.15])
    }

    /// Regression: a debounce here would starve the phone — pulses arriving
    /// faster than the interval kept resetting the timer, so continuous agent
    /// output produced ZERO frames until it paused. The throttle must emit one
    /// frame per window while pulses keep arriving.
    func testContinuousOutputKeepsEmittingEachWindow() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "p1")

        provider.viewport["p1"] = readout("chunk one")
        feed.handleContentChanged(paneId: "p1")
        // Output keeps flowing while the first window is open — these pulses
        // must coalesce, not postpone the pending emit.
        feed.handleContentChanged(paneId: "p1")
        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()

        provider.viewport["p1"] = readout("chunk one\nchunk two")
        feed.handleContentChanged(paneId: "p1")
        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()

        XCTAssertEqual(received.map(\.viewport), ["chunk one", "chunk one\nchunk two"])
        XCTAssertEqual(received.map(\.seq), [1, 2])
        // Exactly one timer per window, regardless of pulse rate.
        XCTAssertEqual(sleeper.requested, [0.15, 0.15])
    }

    func testUnchangedTextIsSuppressedAndSeqAdvancesOnlyOnChange() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        // Pane unpainted at watch (no initial snapshot) so the dedupe path is
        // exercised purely through content pulses.
        feed.watch(token: token, paneId: "p1")
        provider.viewport["p1"] = readout("same")

        // First change → emits seq 1.
        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.seq, 1)

        // Second change with identical text → suppressed.
        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()
        XCTAssertEqual(received.count, 1)

        // Text actually changes → emits seq 2.
        provider.viewport["p1"] = readout("different")
        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.seq, 2)
        XCTAssertEqual(received.last?.viewport, "different")
    }

    func testUnwatchStopsStreaming() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "p1")
        provider.viewport["p1"] = readout("hello")

        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()
        XCTAssertEqual(received.count, 1)

        feed.unwatch(token: token, paneId: "p1")
        // A change after unwatch never even schedules a debounce.
        feed.handleContentChanged(paneId: "p1")
        await drainTasks()
        XCTAssertEqual(sleeper.parkedCount, 0)
        XCTAssertEqual(received.count, 1)
    }

    func testMultipleWatchersEachReceiveText() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var firstReceived: [CompanionPaneText] = []
        var secondReceived: [CompanionPaneText] = []
        let firstToken = feed.addWatcher { firstReceived.append($0) }
        let secondToken = feed.addWatcher { secondReceived.append($0) }
        // Pane unpainted at watch time so both watchers only see the shared
        // debounced fan-out (no per-watcher initial snapshot).
        feed.watch(token: firstToken, paneId: "p1")
        feed.watch(token: secondToken, paneId: "p1")
        provider.viewport["p1"] = readout("shared")

        feed.handleContentChanged(paneId: "p1")
        await sleeper.waitForWaiters(1)
        sleeper.releaseAll()
        await drainTasks()

        XCTAssertEqual(firstReceived.count, 1)
        XCTAssertEqual(secondReceived.count, 1)
        XCTAssertEqual(firstReceived.first?.viewport, "shared")
        XCTAssertEqual(secondReceived.first?.viewport, "shared")
        XCTAssertEqual(firstReceived.first?.seq, secondReceived.first?.seq)
    }

    func testPaneClosedStopsAndClearsState() async {
        let provider = FakePaneTextProvider()
        let sleeper = ManualSleeper()
        var observationLog: [Bool] = []
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) },
            setObservationEnabled: { observationLog.append($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        // Pane unpainted at watch so no initial snapshot lands before the close.
        feed.watch(token: token, paneId: "p1")
        provider.viewport["p1"] = readout("hello")
        XCTAssertEqual(observationLog, [true])

        feed.handlePaneClosed(paneId: "p1")
        XCTAssertEqual(observationLog, [true, false])

        feed.handleContentChanged(paneId: "p1")
        await drainTasks()
        XCTAssertEqual(sleeper.parkedCount, 0)
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - Initial snapshot on watch

    func testWatchSendsImmediateSnapshotForReadablePane() {
        let provider = FakePaneTextProvider()
        provider.viewport["p1"] = readout("live buffer", cols: 100, rows: 30)
        let feed = CompanionPaneTextFeed(provider: provider)

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        // A watcher joining an idle pane (no render pulse coming) must still see the
        // current viewport straight away.
        feed.watch(token: token, paneId: "p1")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.paneId, "p1")
        XCTAssertEqual(received.first?.seq, 1)
        XCTAssertEqual(received.first?.viewport, "live buffer")
        XCTAssertEqual(received.first?.gridCols, 100)
        XCTAssertEqual(received.first?.gridRows, 30)
        XCTAssertFalse(received.first?.truncatedScrollback ?? true)
    }

    func testSecondWatcherOnPrimedPaneStillGetsSnapshot() {
        let provider = FakePaneTextProvider()
        provider.viewport["p1"] = readout("shared")
        let feed = CompanionPaneTextFeed(provider: provider)

        var first: [CompanionPaneText] = []
        var second: [CompanionPaneText] = []
        let firstToken = feed.addWatcher { first.append($0) }
        feed.watch(token: firstToken, paneId: "p1")
        XCTAssertEqual(first.count, 1)

        // The pane is already primed and unchanged; a second watcher must still be
        // handed the current viewport — the shared dedupe is bypassed for the
        // per-watcher initial snapshot.
        let secondToken = feed.addWatcher { second.append($0) }
        feed.watch(token: secondToken, paneId: "p1")

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.viewport, "shared")
        // Per-pane seq stays monotonic across watchers.
        XCTAssertEqual(second.first?.seq, 2)
        // The first watcher is not re-sent to when the second joins.
        XCTAssertEqual(first.count, 1)
    }

    func testWatchOnPaneWithoutSurfaceSendsNothing() {
        let provider = FakePaneTextProvider() // no viewport registered → no live surface
        let feed = CompanionPaneTextFeed(provider: provider)

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "ghost")

        // No crash, no frame; the next content pulse would deliver the first frame.
        XCTAssertTrue(received.isEmpty)
        // Keepalive is still requested so the surface starts rendering once it exists.
        XCTAssertEqual(provider.keepAliveLog.count, 1)
        XCTAssertEqual(provider.keepAliveLog.first?.paneId, "ghost")
        XCTAssertTrue(provider.keepAliveLog.first?.active ?? false)
    }

    // MARK: - Render keepalive gating (occlusion seam)

    func testRenderKeepAliveTogglesOnFirstAndLastWatchPerPane() {
        let provider = FakePaneTextProvider()
        provider.viewport["p1"] = readout("hi")
        let feed = CompanionPaneTextFeed(provider: provider)

        let firstToken = feed.addWatcher { _ in }
        let secondToken = feed.addWatcher { _ in }

        // 0→1: pin the surface un-occluded so a leased/backgrounded pane keeps
        // rendering (the frames the phone mirrors).
        feed.watch(token: firstToken, paneId: "p1")
        XCTAssertEqual(provider.keepAliveLog.map { $0.active }, [true])

        // A second watcher on the same pane is not a fresh 0→1 edge → no re-toggle.
        feed.watch(token: secondToken, paneId: "p1")
        XCTAssertEqual(provider.keepAliveLog.count, 1)

        // One of two watchers leaving keeps the pane watched → no release.
        feed.unwatch(token: firstToken, paneId: "p1")
        XCTAssertEqual(provider.keepAliveLog.count, 1)

        // Last watcher gone → release, restoring the pane's occlusion behavior.
        feed.unwatch(token: secondToken, paneId: "p1")
        XCTAssertEqual(provider.keepAliveLog.map { $0.active }, [true, false])
    }

    func testDisconnectReleasesRenderKeepAlive() {
        let provider = FakePaneTextProvider()
        provider.viewport["p1"] = readout("hi")
        let feed = CompanionPaneTextFeed(provider: provider)

        let token = feed.addWatcher { _ in }
        feed.watch(token: token, paneId: "p1")
        XCTAssertEqual(provider.keepAliveLog.map { $0.active }, [true])

        // A full disconnect drops every watch and releases the keepalive.
        feed.removeWatcher(token)
        XCTAssertEqual(provider.keepAliveLog.map { $0.active }, [true, false])
    }

    // MARK: - Scrollback one-shot

    func testScrollbackReadsFullBufferWithLineLimit() {
        let provider = FakePaneTextProvider()
        provider.scrollback["p1"] = readout("line1\nline2\nline3")
        let feed = CompanionPaneTextFeed(provider: provider)

        let reply = feed.scrollback(paneId: "p1", lineLimit: 500)
        XCTAssertEqual(reply.paneId, "p1")
        XCTAssertEqual(reply.text, "line1\nline2\nline3")
        XCTAssertNil(reply.lineLimit)
        XCTAssertEqual(provider.scrollbackLineLimits, [500])
    }

    func testScrollbackForUnknownPaneRepliesEmpty() {
        let provider = FakePaneTextProvider()
        let feed = CompanionPaneTextFeed(provider: provider)

        let reply = feed.scrollback(paneId: "ghost", lineLimit: nil)
        XCTAssertEqual(reply.paneId, "ghost")
        XCTAssertEqual(reply.text, "")
    }

    // MARK: - Observation gating

    func testObservationTogglesOnFirstAndLastWatch() {
        let provider = FakePaneTextProvider()
        var observationLog: [Bool] = []
        let feed = CompanionPaneTextFeed(
            provider: provider,
            setObservationEnabled: { observationLog.append($0) }
        )

        let token = feed.addWatcher { _ in }
        feed.watch(token: token, paneId: "p1")
        feed.watch(token: token, paneId: "p2")
        // Only the 0→1 transition retains.
        XCTAssertEqual(observationLog, [true])

        feed.unwatch(token: token, paneId: "p1")
        XCTAssertEqual(observationLog, [true])
        feed.unwatch(token: token, paneId: "p2")
        // Last watch gone → release.
        XCTAssertEqual(observationLog, [true, false])
    }

    // input.key routing is covered by CompanionInputRouterTests (keys go through
    // the key-event path, not the paste/text path).
}
