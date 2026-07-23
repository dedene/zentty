import CryptoKit
import Foundation
import OSLog

private let companionRelayLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionRelay")

// MARK: - Socket seam

/// A text-framed, full-duplex link to the relay. Relay framing is JSON text
/// (`CompanionRelayFrame`); the opaque session bytes ride base64url-encoded
/// inside `relay.frame`, so a text socket is sufficient and keeps the whole
/// relay path testable with an in-memory scripted double (no sockets).
protocol CompanionRelaySocket: AnyObject, Sendable {
    /// Sends one whole text frame.
    func send(_ text: String) async throws
    /// Awaits the next text frame, or `nil` once the relay closed the link.
    func receive() async throws -> String?
    /// Tears the link down. Idempotent.
    func close()
}

/// Builds a fresh socket for a relay URL. Injected so tests supply a fake.
typealias CompanionRelaySocketFactory = @Sendable (URL) async throws -> CompanionRelaySocket

/// Production socket over `URLSessionWebSocketTask`. Chosen over `NWConnection`
/// (used by the inbound listener) because this is an *outbound* client dialing an
/// arbitrary `ws`/`wss` URL, where `URLSession` gives TLS, redirects, and proxy
/// handling for free with far less setup than an `NWConnection` WebSocket stack.
final class CompanionURLSessionRelaySocket: CompanionRelaySocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return nil
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

// MARK: - Backoff

/// Full-cycle exponential backoff with jitter for relay reconnects: the ceiling
/// doubles from `base` up to `cap`, and `jitter` maps that ceiling to the actual
/// delay. Reset when a connection reaches `relay.ready`.
struct CompanionRelayBackoff: Sendable {
    let base: TimeInterval
    let cap: TimeInterval
    let jitter: @Sendable (TimeInterval) -> TimeInterval
    private var attempt = 0

    init(
        base: TimeInterval = 1,
        cap: TimeInterval = 60,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = CompanionRelayBackoff.equalJitter
    ) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    /// The next delay, advancing the attempt counter.
    mutating func next() -> TimeInterval {
        let ceiling = Swift.min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return jitter(ceiling)
    }

    /// The undecorated ceiling for `attempt` (no jitter) — the pure schedule.
    func ceiling(forAttempt attempt: Int) -> TimeInterval {
        Swift.min(cap, base * pow(2, Double(attempt)))
    }

    mutating func reset() {
        attempt = 0
    }

    /// Equal jitter: keep a floor of half the ceiling, randomize the top half.
    static let equalJitter: @Sendable (TimeInterval) -> TimeInterval = { ceiling in
        let half = ceiling / 2
        return half + Double.random(in: 0...half)
    }
}

// MARK: - Per-peer virtual connection

/// One demultiplexed peer's `CompanionTransportConnection` over the shared relay
/// socket. Inbound `relay.frame`s for this `from` are `deliver`ed here; outbound
/// frames are wrapped as `relay.frame{to:, sealed:}` by the transport. This is
/// the same seam the `NWListener` path presents, so `CompanionSession` runs
/// unchanged over the relay.
final class CompanionRelayPeerConnection: CompanionTransportConnection, @unchecked Sendable {
    let peerDeviceId: String

    private let lock = NSLock()
    private var inbound: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false
    private let outbound: @Sendable (Data) async throws -> Void

    init(peerDeviceId: String, outbound: @escaping @Sendable (Data) async throws -> Void) {
        self.peerDeviceId = peerDeviceId
        self.outbound = outbound
    }

    func send(_ frame: Data) async throws {
        guard !isClosedSnapshot() else { throw CompanionTransportError.closed }
        try await outbound(frame)
    }

    private func isClosedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
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
    }

    /// Hands one decoded inbound frame to this peer's session run loop.
    func deliver(_ frame: Data) {
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

// MARK: - Relay transport

/// The Mac's outbound relay leg: one WebSocket to the configured relay, an
/// auth handshake signed with this Mac's identity, then bidirectional
/// `relay.frame` pumping demultiplexed into one `CompanionSession` per remote
/// peer. Reconnects with jittered exponential backoff and surfaces peer presence.
///
/// `@MainActor`-isolated to match `CompanionSession` and the bridge services it
/// shares; only the socket send/receive and backoff sleep suspend.
@MainActor
final class CompanionRelayTransport {
    /// Outbound `relay.frame.sealed` byte ceiling. Frames larger than this are
    /// refused locally rather than tripping the relay's `frame_too_large` /
    /// bytes-per-second limits and getting the whole connection dropped.
    static let maxOutboundFrameBytes = 256 * 1024

    /// Upper bound on concurrent peer sessions, so a spamming relay cannot make
    /// the Mac spawn unbounded sessions before auth rejects them.
    static let maxPeerSessions = 32

    private let url: URL
    private weak var services: (any CompanionSessionServicing)?
    private let makeSocket: CompanionRelaySocketFactory
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var backoff: CompanionRelayBackoff

    private var runTask: Task<Void, Never>?
    private var isStopping = false
    private var socket: CompanionRelaySocket?
    private var peers: [String: CompanionRelayPeerConnection] = [:]

    private(set) var isConnected = false

    /// Fired on the main actor when a peer's relay presence changes.
    var onPeerStatus: ((_ deviceId: String, _ online: Bool) -> Void)?
    /// Fired on the main actor when the relay link comes up (`true`) or drops.
    var onConnectionStateChanged: ((Bool) -> Void)?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(
        url: URL,
        services: any CompanionSessionServicing,
        makeSocket: @escaping CompanionRelaySocketFactory = { url in CompanionURLSessionRelaySocket(url: url) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        backoff: CompanionRelayBackoff = CompanionRelayBackoff()
    ) {
        self.url = url
        self.services = services
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.backoff = backoff
    }

    // MARK: - Lifecycle

    /// Starts the reconnect loop. Idempotent.
    func start() {
        guard runTask == nil else { return }
        isStopping = false
        runTask = Task { @MainActor [weak self] in await self?.runReconnectLoop() }
    }

    /// Stops the loop, drops the socket, and tears down every peer session.
    func stop() {
        isStopping = true
        runTask?.cancel()
        runTask = nil
        teardownConnection()
    }

    private func runReconnectLoop() async {
        backoff.reset()
        while !isStopping {
            do {
                try await connectAndPump()
            } catch is CancellationError {
                break
            } catch {
                companionRelayLogger.error(
                    "Relay connection ended: \(String(describing: error), privacy: .public)"
                )
            }
            if isStopping { break }
            let delay = backoff.next()
            companionRelayLogger.info("Relay reconnecting in \(delay, format: .fixed(precision: 2))s")
            do {
                try await sleep(delay)
            } catch {
                break
            }
        }
        teardownConnection()
    }

    // MARK: - One connection

    private func connectAndPump() async throws {
        let socket = try await makeSocket(url)
        self.socket = socket
        defer { teardownConnection() }

        try await performAuthHandshake(on: socket)
        backoff.reset()
        isConnected = true
        onConnectionStateChanged?(true)

        while let text = try await socket.receive() {
            try Task.checkCancellation()
            guard let frame = decodeFrame(text) else { continue }
            handleInbound(frame)
        }
    }

    /// `relay.challenge` → signed `relay.auth` → `relay.ready`/`relay.denied`.
    private func performAuthHandshake(on socket: CompanionRelaySocket) async throws {
        guard let identity = services?.identity else { throw CompanionTransportError.closed }

        guard let challengeText = try await socket.receive() else {
            throw CompanionTransportError.closed
        }
        guard case .challenge(let challenge)? = decodeFrame(challengeText) else {
            throw CompanionTransportError.network("expected relay.challenge")
        }
        guard CompanionBase64URL.isValidUnpadded(challenge.nonce) else {
            throw CompanionTransportError.network("malformed challenge nonce")
        }

        let signature = try identity.signingPrivateKey.signature(
            for: CompanionRelayAuthProof.message(nonce: challenge.nonce)
        )
        let auth = CompanionRelayAuth(
            deviceId: identity.deviceId,
            pubKey: identity.deviceId,
            sig: CompanionBase64URL.encode(signature)
        )
        try await send(.auth(auth), on: socket)

        guard let replyText = try await socket.receive() else {
            throw CompanionTransportError.closed
        }
        switch decodeFrame(replyText) {
        case .ready?:
            companionRelayLogger.info("Relay authenticated")
        case .denied(let denied)?:
            throw CompanionTransportError.network("relay denied: \(denied.reason)")
        default:
            throw CompanionTransportError.network("expected relay.ready")
        }
    }

    // MARK: - Inbound routing

    private func handleInbound(_ frame: CompanionRelayFrame) {
        switch frame {
        case .frame(let sealed):
            routeSealed(sealed)
        case .peerStatus(let status):
            handlePeerStatus(status)
        case .error(let error):
            companionRelayLogger.error(
                "Relay error \(error.code, privacy: .public): \(error.message, privacy: .public)"
            )
        case .challenge, .ready, .denied, .auth, .watch:
            // Unexpected mid-stream control frames — ignore.
            break
        }
    }

    private func routeSealed(_ sealed: CompanionRelaySealedFrame) {
        guard let data = CompanionBase64URL.decode(sealed.sealed) else {
            companionRelayLogger.error("Dropping relay.frame with undecodable sealed payload")
            return
        }
        let peer = peer(for: sealed.from)
        peer?.deliver(data)
    }

    /// Returns the peer connection for `deviceId`, spawning its session on first
    /// contact (bounded by `maxPeerSessions`).
    private func peer(for deviceId: String) -> CompanionRelayPeerConnection? {
        if let existing = peers[deviceId] { return existing }
        guard let services else { return nil }
        guard peers.count < Self.maxPeerSessions else {
            companionRelayLogger.error("Refusing new relay peer; session cap reached")
            return nil
        }

        let connection = CompanionRelayPeerConnection(
            peerDeviceId: deviceId,
            outbound: { [weak self] data in
                guard let self else { throw CompanionTransportError.closed }
                try await self.sendSealed(data, to: deviceId)
            }
        )
        peers[deviceId] = connection

        let session = CompanionSession(connection: connection, services: services)
        Task { @MainActor [weak self] in
            await session.run()
            self?.removePeer(deviceId, ifIdentical: connection)
        }
        return connection
    }

    private func handlePeerStatus(_ status: CompanionRelayPeerStatus) {
        onPeerStatus?(status.deviceId, status.online)
        guard !status.online, let connection = peers[status.deviceId] else { return }
        // No store-and-forward: an offline peer's session is dead weight. Drop it;
        // the phone re-initiates (pairing/handshake) when it returns.
        connection.close()
        removePeer(status.deviceId, ifIdentical: connection)
    }

    /// Drops a peer's live session immediately (e.g. its device was revoked in
    /// Settings), mirroring the listener path's active-session teardown.
    func closePeerSession(deviceId: String) {
        guard let connection = peers[deviceId] else { return }
        connection.close()
        removePeer(deviceId, ifIdentical: connection)
    }

    private func removePeer(_ deviceId: String, ifIdentical connection: CompanionRelayPeerConnection) {
        if peers[deviceId] === connection {
            peers[deviceId] = nil
        }
    }

    // MARK: - Outbound

    /// Wraps one opaque session frame as `relay.frame` and sends it. Enforces the
    /// outbound size cap so an oversized frame never trips the relay's limits.
    /// Internal (not private) so `ZenttyLogicTests` can assert the cap directly.
    func sendSealed(_ data: Data, to deviceId: String) async throws {
        guard data.count <= Self.maxOutboundFrameBytes else {
            companionRelayLogger.error("Refusing oversized relay frame (\(data.count) bytes)")
            throw CompanionTransportError.network("frame_too_large")
        }
        guard let socket, let from = services?.identity.deviceId else {
            throw CompanionTransportError.closed
        }
        let frame = CompanionRelaySealedFrame(
            to: deviceId,
            from: from,
            sealed: CompanionBase64URL.encode(data)
        )
        try await send(.frame(frame), on: socket)
    }

    private func send(_ frame: CompanionRelayFrame, on socket: CompanionRelaySocket) async throws {
        let data = try encoder.encode(frame)
        try await socket.send(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Teardown

    private func teardownConnection() {
        let wasConnected = isConnected
        isConnected = false
        socket?.close()
        socket = nil
        let live = peers
        peers.removeAll()
        live.values.forEach { $0.close() }
        if wasConnected { onConnectionStateChanged?(false) }
    }

    // MARK: - Decode

    private func decodeFrame(_ text: String) -> CompanionRelayFrame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(CompanionRelayFrame.self, from: data)
    }
}
