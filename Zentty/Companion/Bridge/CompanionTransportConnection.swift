import Foundation
import Network
import OSLog

private let companionTransportLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionTransport")

// MARK: - Transport seam

/// A single bidirectional, message-framed link to one companion peer.
///
/// The bridge speaks only in whole frames (`Data`): plaintext JSON during
/// pairing / crypto handshake, sealed binary afterwards. Keeping the network
/// specifics behind this protocol lets `ZenttyLogicTests` drive a full session
/// over an in-memory pipe with no real sockets.
protocol CompanionTransportConnection: AnyObject, Sendable {
    /// Sends one whole frame to the peer.
    func send(_ frame: Data) async throws

    /// Awaits the next whole frame, or `nil` once the peer closed the link.
    func receive() async throws -> Data?

    /// Tears the link down. Idempotent.
    func close()
}

enum CompanionTransportError: Error, Equatable {
    /// The link was closed before the operation could complete.
    case closed
    /// The underlying network stack reported a failure.
    case network(String)
}

// MARK: - In-memory pipe (tests)

/// A loopback `CompanionTransportConnection` pair. `makePair()` returns the two
/// ends of one link; a frame sent on one surfaces on the other's `receive()`.
/// Used by tests to run a real `CompanionSession` with no sockets.
final class CompanionInMemoryConnection: CompanionTransportConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false
    fileprivate weak var peer: CompanionInMemoryConnection?

    private init() {}

    static func makePair() -> (CompanionInMemoryConnection, CompanionInMemoryConnection) {
        let a = CompanionInMemoryConnection()
        let b = CompanionInMemoryConnection()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ frame: Data) async throws {
        guard let peer else { throw CompanionTransportError.closed }
        peer.deliver(frame)
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if !inbound.isEmpty {
                let frame = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: nil) }
        peer?.close()
    }

    private func deliver(_ frame: Data) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            inbound.append(frame)
            lock.unlock()
        }
    }
}

// MARK: - Network.framework connection

/// Wraps an `NWConnection` running the WebSocket protocol, exposing whole
/// WebSocket messages as frames. Binary messages carry sealed session frames;
/// text messages carry plaintext handshake / pairing JSON.
final class CompanionNetworkConnection: CompanionTransportConnection, @unchecked Sendable {
    /// Fires its guarded action at most once, under a lock, so a connection's
    /// serially-delivered state updates resume a continuation exactly once.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let startLock = NSLock()
    private var didStart = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Returns `true` if the connection had already been started. Synchronous, so
    /// the lock is never held across a suspension.
    private func consumeStartFlag() -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        let alreadyStarted = didStart
        didStart = true
        return alreadyStarted
    }

    private func startIfNeeded() async throws {
        guard !consumeStartFlag() else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { continuation.resume() }
                case .failed(let error):
                    if once.fire() {
                        continuation.resume(throwing: CompanionTransportError.network(String(describing: error)))
                    }
                case .cancelled:
                    if once.fire() { continuation.resume(throwing: CompanionTransportError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ frame: Data) async throws {
        try await startIfNeeded()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "companion-frame", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: CompanionTransportError.network(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func receive() async throws -> Data? {
        try await startIfNeeded()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: CompanionTransportError.network(String(describing: error)))
                    return
                }
                guard let data, !data.isEmpty else {
                    // A complete, empty message or EOF: treat as closed.
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
