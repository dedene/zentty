import Darwin
import Foundation
import os

private let paneEventStreamLogger = Logger(subsystem: "be.zenjoy.zentty", category: "PaneEvents")

/// Writes `zentty events` lines to connected clients.
///
/// Broadcasting never blocks the caller: each subscriber owns a serial
/// queue that does the socket writes, with a bounded number of lines in
/// flight. A client that falls behind loses events (counted, logged, and
/// reported in-band as `stream.dropped`) instead of growing an unbounded
/// buffer. A client that disconnects is noticed through a read source on
/// its socket and removed; so is one whose socket stops accepting writes.
final class PaneEventStream: @unchecked Sendable {
    static let shared = PaneEventStream()

    /// Lines queued per subscriber before new ones are dropped.
    static let defaultMaxPendingLines = 512
    /// How long one write may block before the client counts as gone.
    static let writeTimeoutSeconds = 10
    private static let sendBufferBytes: Int32 = 256 * 1024

    private let lock = NSLock()
    private var subscribers: [UUID: PaneEventSubscriber] = [:]
    private let maxPendingLines: Int
    private let now: @Sendable () -> Date
    private let writeTargetQueue: DispatchQueue?

    private var subscribersChangedHandler: (@Sendable (_ hasSubscribers: Bool) -> Void)?

    /// `writeTargetQueue` lets tests hold writes back to exercise backpressure.
    init(
        maxPendingLines: Int = PaneEventStream.defaultMaxPendingLines,
        now: @escaping @Sendable () -> Date = { Date() },
        writeTargetQueue: DispatchQueue? = nil
    ) {
        self.maxPendingLines = maxPendingLines
        self.now = now
        self.writeTargetQueue = writeTargetQueue
    }

    /// `handler` runs (on an arbitrary thread) whenever the subscriber count
    /// goes between zero and non-zero, so the monitor only diffs while
    /// someone is listening.
    func setSubscribersChangedHandler(_ handler: @escaping @Sendable (_ hasSubscribers: Bool) -> Void) {
        lock.withLock { subscribersChangedHandler = handler }
    }

    var hasSubscribers: Bool {
        lock.withLock { !subscribers.isEmpty }
    }

    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    /// Lines queued but not yet written, across all subscribers.
    var pendingLineCountForTesting: Int {
        lock.withLock { Array(subscribers.values) }.reduce(0) { $0 + $1.pendingLineCount }
    }

    /// Takes ownership of `fileDescriptor`: it is closed when the client goes
    /// away or the stream shuts down. Writes `stream.ready` first.
    @discardableResult
    func addSubscriber(fileDescriptor: Int32, filter: PaneEventTypeFilter) -> UUID {
        Self.configureStreamSocket(fileDescriptor)
        let subscriber = PaneEventSubscriber(
            fileDescriptor: fileDescriptor,
            filter: filter,
            maxPendingLines: maxPendingLines,
            now: now,
            targetQueue: writeTargetQueue,
            onClose: { [weak self] id in
                self?.removeSubscriber(id: id)
            }
        )
        // Registering, watching, and queueing `stream.ready` happen under the
        // lock that `broadcast` takes to pick its targets, so no event can be
        // queued ahead of `stream.ready`, and a client that hangs up at once
        // is already registered when its removal runs.
        let handler = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            subscribers[subscriber.id] = subscriber
            subscriber.start()
            subscriber.enqueue(PaneEvent(type: .streamReady))
            return subscribers.count == 1 ? subscribersChangedHandler : nil
        }
        handler?(true)
        return subscriber.id
    }

    /// Delivers `events` to every subscriber whose filter matches. Safe to
    /// call from the main thread: it only encodes and enqueues.
    func broadcast(_ events: [PaneEvent]) {
        guard !events.isEmpty else { return }
        let targets = lock.withLock { Array(subscribers.values) }
        guard !targets.isEmpty else { return }
        let date = now()
        for event in events {
            let stamped = event.stamped(date)
            guard let line = try? stamped.encodedLine() else {
                paneEventStreamLogger.error("Failed to encode event \(event.type, privacy: .public)")
                continue
            }
            for subscriber in targets where subscriber.filter.matches(event.type) {
                subscriber.enqueue(line: line)
            }
        }
    }

    /// Disconnects every client (app shutdown).
    func closeAll() {
        let targets = lock.withLock { Array(subscribers.values) }
        for subscriber in targets {
            subscriber.close()
        }
    }

    private func removeSubscriber(id: UUID) {
        let handler = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return nil }
            return subscribersChangedHandler
        }
        handler?(false)
    }

    private static func configureStreamSocket(_ fileDescriptor: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var bufferSize = sendBufferBytes
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// One connected `zentty events` client.
final class PaneEventSubscriber: @unchecked Sendable {
    let id = UUID()
    let filter: PaneEventTypeFilter

    private let fileDescriptor: Int32
    private let maxPendingLines: Int
    private let now: @Sendable () -> Date
    private let onClose: @Sendable (UUID) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingLines = 0
    private var droppedLines = 0
    private var isClosed = false
    private var readSource: DispatchSourceRead?

    init(
        fileDescriptor: Int32,
        filter: PaneEventTypeFilter,
        maxPendingLines: Int,
        now: @escaping @Sendable () -> Date,
        targetQueue: DispatchQueue?,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.filter = filter
        self.maxPendingLines = max(1, maxPendingLines)
        self.now = now
        self.onClose = onClose
        self.queue = DispatchQueue(label: "be.zenjoy.zentty.pane-events.subscriber", target: targetQueue)
    }

    /// Watches the socket for EOF so a client that goes quiet and then
    /// disconnects is released without waiting for the next event.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainInput()
        }
        source.setCancelHandler { [fileDescriptor] in
            Darwin.close(fileDescriptor)
        }
        lock.withLock { readSource = source }
        source.resume()
    }

    func enqueue(_ event: PaneEvent) {
        guard let line = try? event.stamped(now()).encodedLine() else { return }
        enqueue(line: line)
    }

    func enqueue(line: Data) {
        let notice: Data? = lock.withLock {
            guard !isClosed else { return nil }
            guard pendingLines < maxPendingLines else {
                droppedLines += 1
                if droppedLines == 1 {
                    paneEventStreamLogger.warning("events client is falling behind; dropping events")
                }
                return nil
            }
            var notice: Data?
            if droppedLines > 0 {
                notice = try? PaneEvent(type: .streamDropped, count: droppedLines).stamped(now()).encodedLine()
                droppedLines = 0
            }
            pendingLines += 1
            return notice ?? Data()
        }
        guard let notice else { return }
        let payload = notice.isEmpty ? line : notice + line
        queue.async { [weak self] in
            self?.write(payload)
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.shutDown()
        }
    }

    var pendingLineCount: Int {
        lock.withLock { pendingLines }
    }

    private func write(_ payload: Data) {
        defer { lock.withLock { pendingLines -= 1 } }
        guard !lock.withLock({ isClosed }) else { return }
        let succeeded = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: written), rawBuffer.count - written, 0)
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
        if !succeeded {
            // A broken pipe or a write that timed out: either way the framing
            // can no longer be trusted, so the client is let go.
            shutDown()
        }
    }

    private func drainInput() {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fileDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
        if count > 0 {
            return
        }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return
        }
        shutDown()
    }

    /// Runs on `queue`. Idempotent.
    private func shutDown() {
        let source: DispatchSourceRead? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            let source = readSource
            readSource = nil
            return source
        }
        guard let source else { return }
        // The cancel handler closes the descriptor, after any in-flight
        // handler has finished with it.
        source.cancel()
        onClose(id)
    }
}
