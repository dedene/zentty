import Darwin
import XCTest
@testable import Zentty

@MainActor
final class PaneEventMonitorTests: XCTestCase {
    private var client: Int32 = -1
    private var buffered = Data()

    override func tearDown() {
        if client >= 0 {
            close(client)
            client = -1
        }
        buffered = Data()
        super.tearDown()
    }

    func test_store_changes_reach_subscribers_as_events() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        try subscribe(monitor)
        XCTAssertEqual(try nextEvent().type, "stream.ready")

        let store = WorklaneStore()
        let windowID = WindowID("wd_test")
        monitor.attach(windowID: windowID, store: store)
        let originalPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        // A window attached while someone listens announces what it brings.
        XCTAssertEqual(
            try (0..<4).map { _ in try nextEvent().type },
            ["worklane.created", "pane.created", "pane.focused", "worklane.activated"]
        )

        store.send(.splitAfterFocusedPane)
        let newPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertNotEqual(newPaneID, originalPaneID)

        let created = try nextEvent()
        XCTAssertEqual(created.type, "pane.created")
        XCTAssertEqual(created.pane, newPaneID.rawValue)
        XCTAssertEqual(created.window, windowID.rawValue)
        let focused = try nextEvent()
        XCTAssertEqual(focused.type, "pane.focused")
        XCTAssertEqual(focused.pane, newPaneID.rawValue)

        _ = store.closePane(id: newPaneID)
        var closedTypes: [String] = []
        while closedTypes.last != "pane.closed" {
            closedTypes.append(try nextEvent().type)
        }
        XCTAssertEqual(closedTypes, ["pane.focused", "pane.closed"])
    }

    func test_windows_present_before_subscribing_are_the_baseline() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        let store = WorklaneStore()
        monitor.attach(windowID: WindowID("wd_existing"), store: store)

        try subscribe(monitor)
        XCTAssertEqual(try nextEvent().type, "stream.ready")

        // No main-queue turn in between: a change made right after
        // `stream.ready` is reported, and what existed before is not.
        store.send(.splitAfterFocusedPane)
        XCTAssertEqual(try nextEvent().type, "pane.created", "existing panes are not re-announced")
    }

    func test_late_subscriber_sees_stream_ready_first_and_only_later_changes() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        let store = WorklaneStore()
        monitor.attach(windowID: WindowID("wd_shared"), store: store)
        try subscribe(monitor)

        store.send(.splitAfterFocusedPane)
        let first = try subscribe(monitor)
        defer { close(first) }
        XCTAssertEqual(try nextEvent().type, "stream.ready")
        store.send(.splitAfterFocusedPane)
        let created = try nextEvent()
        XCTAssertEqual(created.type, "pane.created")
        XCTAssertEqual(created.pane, store.activeWorklane?.paneStripState.focusedPaneID?.rawValue)
    }

    func test_switching_worklanes_reports_the_activated_worklane() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        let store = WorklaneStore()
        monitor.attach(windowID: WindowID("wd_switch"), store: store)
        let firstWorklaneID = try XCTUnwrap(store.activeWorklane?.id)
        _ = store.createWorklane()
        XCTAssertNotEqual(store.activeWorklane?.id, firstWorklaneID)
        try subscribe(monitor)
        XCTAssertEqual(try nextEvent().type, "stream.ready")

        store.selectWorklane(id: firstWorklaneID)

        let activated = try nextEvent()
        XCTAssertEqual(activated.type, "worklane.activated")
        XCTAssertEqual(activated.worklane, firstWorklaneID.rawValue)
        XCTAssertEqual(activated.pane, store.activeWorklane?.paneStripState.focusedPaneID?.rawValue)
    }

    func test_detaching_a_window_reports_its_panes_closed() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        try subscribe(monitor)
        XCTAssertEqual(try nextEvent().type, "stream.ready")

        let store = WorklaneStore()
        let windowID = WindowID("wd_closing")
        monitor.attach(windowID: windowID, store: store)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        _ = try (0..<4).map { _ in try nextEvent() }

        monitor.detach(windowID: windowID)

        let closed = try nextEvent()
        XCTAssertEqual(closed.type, "pane.closed")
        XCTAssertEqual(closed.pane, paneID.rawValue)
        XCTAssertEqual(try nextEvent().type, "worklane.closed")
    }

    func test_without_subscribers_nothing_is_captured() throws {
        let stream = PaneEventStream()
        let monitor = PaneEventMonitor(stream: stream, schedule: { work in work() })
        let store = WorklaneStore()
        monitor.attach(windowID: WindowID("wd_idle"), store: store)
        store.send(.splitAfterFocusedPane)
        monitor.flush()
        XCTAssertEqual(monitor.snapshotCountForTesting, 0)

        try subscribe(monitor)
        XCTAssertEqual(monitor.snapshotCountForTesting, 1, "subscribing takes the baseline")
        XCTAssertEqual(try nextEvent().type, "stream.ready")
    }

    // MARK: - Helpers

    /// Subscribes through the monitor. The previous client, if any, is
    /// handed back so it stays connected; `nextEvent` reads the new one.
    @discardableResult
    private func subscribe(_ monitor: PaneEventMonitor) throws -> Int32 {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let previous = client
        client = descriptors[1]
        buffered = Data()
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        monitor.addSubscriber(fileDescriptor: descriptors[0], filter: PaneEventTypeFilter())
        return previous
    }

    private func nextEvent(file: StaticString = #filePath, line: UInt = #line) throws -> PaneEvent {
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffered.firstIndex(of: UInt8(ascii: "\n")) == nil {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else {
                XCTFail("no event arrived", file: file, line: line)
                throw POSIXError(.ETIMEDOUT)
            }
            buffered.append(chunk, count: count)
        }
        let newline = buffered.firstIndex(of: UInt8(ascii: "\n"))!
        let lineData = Data(buffered[buffered.startIndex..<newline])
        buffered = Data(buffered[buffered.index(after: newline)...])
        return try JSONDecoder().decode(PaneEvent.self, from: lineData)
    }
}
