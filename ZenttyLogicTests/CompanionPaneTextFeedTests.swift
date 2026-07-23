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

    private final class FakeInputSink: CompanionInputSink {
        var sends: [(text: String, paneId: String)] = []
        func companionSendText(_ text: String, toPaneId paneId: String) -> Bool {
            sends.append((text, paneId))
            return true
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
        provider.viewport["p1"] = readout("hello world", cols: 120, rows: 40)
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "p1")

        for _ in 0..<5 { feed.handleContentChanged(paneId: "p1") }
        await sleeper.waitForWaiters(5)
        sleeper.releaseAll()
        await drainTasks()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.paneId, "p1")
        XCTAssertEqual(received.first?.seq, 1)
        XCTAssertEqual(received.first?.viewport, "hello world")
        XCTAssertEqual(received.first?.gridCols, 120)
        XCTAssertEqual(received.first?.gridRows, 40)
        XCTAssertFalse(received.first?.truncatedScrollback ?? true)
        // Every pulse in the burst asked for the same debounce delay.
        XCTAssertEqual(sleeper.requested, Array(repeating: 0.15, count: 5))
    }

    func testUnchangedTextIsSuppressedAndSeqAdvancesOnlyOnChange() async {
        let provider = FakePaneTextProvider()
        provider.viewport["p1"] = readout("same")
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "p1")

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
        provider.viewport["p1"] = readout("hello")
        let sleeper = ManualSleeper()
        let feed = CompanionPaneTextFeed(
            provider: provider,
            debounceInterval: 0.15,
            sleep: { await sleeper.sleep($0) }
        )

        var received: [CompanionPaneText] = []
        let token = feed.addWatcher { received.append($0) }
        feed.watch(token: token, paneId: "p1")

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
        provider.viewport["p1"] = readout("shared")
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
        feed.watch(token: firstToken, paneId: "p1")
        feed.watch(token: secondToken, paneId: "p1")

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
        provider.viewport["p1"] = readout("hello")
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
        feed.watch(token: token, paneId: "p1")
        XCTAssertEqual(observationLog, [true])

        feed.handlePaneClosed(paneId: "p1")
        XCTAssertEqual(observationLog, [true, false])

        feed.handleContentChanged(paneId: "p1")
        await drainTasks()
        XCTAssertEqual(sleeper.parkedCount, 0)
        XCTAssertTrue(received.isEmpty)
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

    // MARK: - Input key map (input.key)

    func testInputKeyMapCoversFullDraftSet() {
        let expected: [CompanionInputKey: String] = [
            .enter: "\r",
            .escape: "\u{1b}",
            .tab: "\t",
            .up: "\u{1b}[A",
            .down: "\u{1b}[B",
            .right: "\u{1b}[C",
            .left: "\u{1b}[D",
            .ctrlC: "\u{03}",
            .ctrlD: "\u{04}",
            .ctrlZ: "\u{1a}",
            .ctrlR: "\u{12}"
        ]
        for (key, bytes) in expected {
            XCTAssertEqual(CompanionInputRouter.bytes(for: key), bytes, "mismatch for \(key)")
        }
    }

    func testInputKeyRoutesArrowsAsStandardCSIThroughSink() {
        let sink = FakeInputSink()
        let router = CompanionInputRouter(sink: sink)

        let arrows: [(CompanionInputKey, String)] = [
            (.up, "\u{1b}[A"), (.down, "\u{1b}[B"), (.right, "\u{1b}[C"), (.left, "\u{1b}[D")
        ]
        for (key, expected) in arrows {
            let ack = router.handle(.inputKey(CompanionInputKeyMessage(paneId: "p1", key: key)))
            XCTAssertEqual(ack?.ok, true)
            XCTAssertEqual(sink.sends.last?.text, expected)
            XCTAssertEqual(sink.sends.last?.paneId, "p1")
        }
        XCTAssertEqual(sink.sends.count, arrows.count)
    }

    func testInputKeyControlBytesRouteThroughSink() {
        let sink = FakeInputSink()
        let router = CompanionInputRouter(sink: sink)

        let ack = router.handle(.inputKey(CompanionInputKeyMessage(paneId: "p9", key: .ctrlC)))
        XCTAssertEqual(ack?.ok, true)
        XCTAssertEqual(sink.sends.last?.text, "\u{03}")
        XCTAssertEqual(sink.sends.last?.paneId, "p9")
    }
}
