import Darwin
import XCTest
@testable import Zentty

final class PaneEventStreamTests: XCTestCase {
    private var clientDescriptors: [Int32] = []

    override func tearDown() {
        for descriptor in clientDescriptors {
            close(descriptor)
        }
        clientDescriptors = []
        super.tearDown()
    }

    func test_subscriber_receives_ready_then_broadcast_events() throws {
        let stream = PaneEventStream()
        let client = try connect(stream)

        stream.broadcast([PaneEvent(type: .paneCreated, worklane: "wl_1", pane: "pn_1")])

        XCTAssertEqual(try readEvent(client).type, "stream.ready")
        let created = try readEvent(client)
        XCTAssertEqual(created.type, "pane.created")
        XCTAssertEqual(created.pane, "pn_1")
        XCTAssertEqual(created.v, 1)
        XCTAssertFalse(created.ts.isEmpty)
    }

    func test_ready_comes_first_while_events_are_being_broadcast() throws {
        let stream = PaneEventStream()
        _ = try connect(stream)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<500 {
                stream.broadcast([PaneEvent(type: .paneFocused, pane: "pn_busy")])
            }
            finished.signal()
        }
        var clients: [Int32] = []
        for _ in 0..<20 {
            clients.append(try connect(stream))
        }
        finished.wait()
        for client in clients {
            XCTAssertEqual(try readEvent(client).type, "stream.ready")
        }
    }

    func test_filter_limits_types_per_subscriber() throws {
        let stream = PaneEventStream()
        let client = try connect(stream, filter: PaneEventTypeFilter(patterns: ["agent"]))

        stream.broadcast([
            PaneEvent(type: .paneCreated, pane: "pn_1"),
            PaneEvent(type: .agentPhase, pane: "pn_1", agent: "Codex", phase: "running"),
        ])

        XCTAssertEqual(try readEvent(client).type, "stream.ready")
        XCTAssertEqual(try readEvent(client).type, "agent.phase")
    }

    func test_client_disconnect_removes_subscriber() throws {
        let stream = PaneEventStream()
        let removed = expectation(description: "subscriber removed")
        stream.setSubscribersChangedHandler { hasSubscribers in
            if !hasSubscribers { removed.fulfill() }
        }
        let client = try connect(stream)
        XCTAssertEqual(stream.subscriberCount, 1)

        close(client)
        clientDescriptors.removeAll { $0 == client }

        wait(for: [removed], timeout: 5)
        XCTAssertEqual(stream.subscriberCount, 0)
        XCTAssertFalse(stream.hasSubscribers)
    }

    func test_broadcast_without_subscribers_is_a_no_op() {
        let stream = PaneEventStream()
        stream.broadcast([PaneEvent(type: .paneClosed, pane: "pn_1")])
        XCTAssertFalse(stream.hasSubscribers)
    }

    func test_slow_client_drops_events_and_is_told_how_many() throws {
        let writes = DispatchQueue(label: "test.pane-events.writes")
        writes.suspend()
        let stream = PaneEventStream(maxPendingLines: 2, writeTargetQueue: writes)
        let client = try connect(stream)

        // `stream.ready` plus one event fill the queue; the next two drop.
        stream.broadcast([
            PaneEvent(type: .paneCreated, pane: "pn_1"),
            PaneEvent(type: .paneCreated, pane: "pn_2"),
            PaneEvent(type: .paneCreated, pane: "pn_3"),
        ])
        writes.resume()
        XCTAssertEqual(try readEvent(client).type, "stream.ready")
        XCTAssertEqual(try readEvent(client).pane, "pn_1")

        waitUntilDrained(stream)
        stream.broadcast([PaneEvent(type: .paneCreated, pane: "pn_4")])

        let notice = try readEvent(client)
        XCTAssertEqual(notice.type, "stream.dropped")
        XCTAssertEqual(notice.count, 2)
        XCTAssertEqual(try readEvent(client).pane, "pn_4")
    }

    func test_close_all_disconnects_clients() throws {
        let stream = PaneEventStream()
        let removed = expectation(description: "subscriber removed")
        stream.setSubscribersChangedHandler { hasSubscribers in
            if !hasSubscribers { removed.fulfill() }
        }
        let client = try connect(stream)
        XCTAssertEqual(try readEvent(client).type, "stream.ready")

        stream.closeAll()

        wait(for: [removed], timeout: 5)
        var byte: UInt8 = 0
        XCTAssertEqual(recv(client, &byte, 1, 0), 0, "client sees EOF")
    }

    // MARK: - Helpers

    private func connect(_ stream: PaneEventStream, filter: PaneEventTypeFilter = PaneEventTypeFilter()) throws -> Int32 {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = descriptors[1]
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        clientDescriptors.append(client)
        stream.addSubscriber(fileDescriptor: descriptors[0], filter: filter)
        return client
    }

    private var pendingBytes: [Int32: Data] = [:]

    private func readEvent(_ descriptor: Int32, file: StaticString = #filePath, line: UInt = #line) throws -> PaneEvent {
        var buffer = pendingBytes[descriptor] ?? Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffer.firstIndex(of: UInt8(ascii: "\n")) == nil {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            guard count > 0 else {
                XCTFail("stream ended or timed out", file: file, line: line)
                throw POSIXError(.ETIMEDOUT)
            }
            buffer.append(chunk, count: count)
        }
        let newline = buffer.firstIndex(of: UInt8(ascii: "\n"))!
        let lineData = Data(buffer[buffer.startIndex..<newline])
        pendingBytes[descriptor] = Data(buffer[buffer.index(after: newline)...])
        return try JSONDecoder().decode(PaneEvent.self, from: lineData)
    }

    private func waitUntilDrained(_ stream: PaneEventStream) {
        let drained = expectation(description: "writes drained")
        DispatchQueue.global().async {
            // The subscriber decrements its pending count after each write;
            // poll briefly until the backlog is gone.
            for _ in 0..<200 {
                if PaneEventStreamTests.pendingCount(of: stream) == 0 { break }
                usleep(5_000)
            }
            drained.fulfill()
        }
        wait(for: [drained], timeout: 5)
    }

    private static func pendingCount(of stream: PaneEventStream) -> Int {
        stream.pendingLineCountForTesting
    }
}
