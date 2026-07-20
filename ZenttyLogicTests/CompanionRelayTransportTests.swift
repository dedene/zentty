import CryptoKit
import XCTest

@testable import Zentty

/// Protocol-seam tests for the outbound relay transport, driven entirely by a
/// scripted in-memory relay socket (no real network). Covers the auth handshake
/// signing contract, per-peer demultiplexing, the jittered reconnect schedule,
/// the outbound frame-size cap, and peer-offline surfacing.
@MainActor
final class CompanionRelayTransportTests: XCTestCase {
    // MARK: - Fixture

    private var macIdentity: CompanionDeviceIdentity!
    private var services: FakeRelayServices!

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        macIdentity = CompanionDeviceIdentity(
            signingPrivateKey: Curve25519.Signing.PrivateKey(),
            isPersistent: false
        )
        services = FakeRelayServices(identity: macIdentity)
    }

    // MARK: - Auth handshake signing

    func testAuthSignsContractStringOverTransmittedNonce() async throws {
        let socket = ScriptedRelaySocket()
        let transport = makeTransport(socket: socket)
        transport.start()

        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let nonceString = CompanionBase64URL.encode(nonce)
        socket.pushInbound(try relayFrameText(.challenge(
            CompanionRelayChallenge(nonce: nonceString, ts: 1)
        )))

        let authText = await socket.nextSent()
        guard case .auth(let auth) = try decodeRelay(authText) else {
            return XCTFail("Expected relay.auth")
        }

        // Identity binding: deviceId == pubKey == base64url(raw Ed25519 pubkey).
        XCTAssertEqual(auth.deviceId, macIdentity.deviceId)
        XCTAssertEqual(auth.pubKey, macIdentity.deviceId)

        // Signature verifies against the UTF-8 bytes of "zentty-relay-auth:" +
        // the base64url nonce string exactly as transmitted (relay contract —
        // the relay verifies over the transmitted spelling, never decoded bytes).
        let signature = try XCTUnwrap(CompanionBase64URL.decode(auth.sig))
        let expectedMessage = Data(("zentty-relay-auth:" + nonceString).utf8)
        XCTAssertTrue(
            macIdentity.signingPublicKey.isValidSignature(signature, for: expectedMessage)
        )

        transport.stop()
    }

    func testDeniedAuthDoesNotSurfaceConnected() async throws {
        let socket = ScriptedRelaySocket()
        var connectedStates: [Bool] = []
        let transport = makeTransport(socket: socket)
        transport.onConnectionStateChanged = { connectedStates.append($0) }
        transport.start()

        socket.pushInbound(try relayFrameText(.challenge(
            CompanionRelayChallenge(nonce: CompanionBase64URL.encode(Data(repeating: 7, count: 16)), ts: 1)
        )))
        _ = await socket.nextSent() // auth
        socket.pushInbound(try relayFrameText(.denied(CompanionRelayDenied(reason: "unknown_device"))))

        // Give the run loop a few hops to process the denial.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(connectedStates.contains(true))
        transport.stop()
    }

    // MARK: - Demux by `from`

    func testDemuxRoutesFramesToPerPeerSessions() async throws {
        let socket = ScriptedRelaySocket()
        let transport = makeTransport(socket: socket)
        transport.start()
        try await completeHandshake(on: socket)

        let phoneA = PhoneRelayPeer()
        let phoneB = PhoneRelayPeer()

        socket.pushInbound(try pairingRelayFrame(from: phoneA, macId: macIdentity.deviceId))
        socket.pushInbound(try pairingRelayFrame(from: phoneB, macId: macIdentity.deviceId))

        // Two independent sessions must answer with a pairing.confirm each,
        // addressed back to the originating peer.
        let first = try await nextConfirm(on: socket)
        let second = try await nextConfirm(on: socket)

        XCTAssertEqual(Set([first.to, second.to]), Set([phoneA.deviceId, phoneB.deviceId]))
        XCTAssertEqual(Set(services.recordedPairings), Set([phoneA.deviceId, phoneB.deviceId]))

        transport.stop()
    }

    // MARK: - Peer offline surfacing

    func testPeerOfflineSurfacesAndDropsSession() async throws {
        let socket = ScriptedRelaySocket()
        var statuses: [(String, Bool)] = []
        let transport = makeTransport(socket: socket)
        transport.onPeerStatus = { statuses.append(($0, $1)) }
        transport.start()
        try await completeHandshake(on: socket)

        let phone = PhoneRelayPeer()
        socket.pushInbound(try pairingRelayFrame(from: phone, macId: macIdentity.deviceId))
        _ = try await nextConfirm(on: socket) // first session lived

        socket.pushInbound(try relayFrameText(.peerStatus(
            CompanionRelayPeerStatus(deviceId: phone.deviceId, online: false)
        )))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(statuses.contains { $0 == (phone.deviceId, false) })

        // The offline peer's session was dropped: a fresh frame spins up a new
        // session that pairs again (proving the old one is gone, not reused).
        services.recordedPairings.removeAll()
        socket.pushInbound(try pairingRelayFrame(from: phone, macId: macIdentity.deviceId))
        _ = try await nextConfirm(on: socket)
        XCTAssertEqual(services.recordedPairings, [phone.deviceId])

        transport.stop()
    }

    // MARK: - Frame size cap

    func testOutboundFrameCapRejectsOversizeButNotNormal() async throws {
        let socket = ScriptedRelaySocket()
        let transport = makeTransport(socket: socket)
        transport.start()
        try await completeHandshake(on: socket)

        let oversize = Data(repeating: 0xAB, count: CompanionRelayTransport.maxOutboundFrameBytes + 1)
        do {
            try await transport.sendSealed(oversize, to: "peer")
            XCTFail("Expected oversize frame to be refused")
        } catch let CompanionTransportError.network(reason) {
            XCTAssertEqual(reason, "frame_too_large")
        }

        // A within-cap frame passes the cap gate and reaches the socket.
        let normal = Data(repeating: 0xCD, count: 1024)
        try await transport.sendSealed(normal, to: "peer")
        let sentText = await socket.nextSent()
        guard case .frame(let sealed) = try decodeRelay(sentText) else {
            return XCTFail("Expected relay.frame")
        }
        XCTAssertEqual(sealed.to, "peer")
        XCTAssertEqual(sealed.from, macIdentity.deviceId)
        XCTAssertEqual(CompanionBase64URL.decode(sealed.sealed), normal)

        transport.stop()
    }

    // MARK: - Reconnect backoff schedule (virtual clock)

    func testReconnectBackoffSchedule() async throws {
        let recorder = SleepRecorder(stopAfter: 8)
        let backoff = CompanionRelayBackoff(base: 1, cap: 60, jitter: { $0 })
        let transport = CompanionRelayTransport(
            url: URL(string: "wss://relay.test")!,
            services: services,
            makeSocket: { _ in throw CompanionTransportError.network("boom") },
            sleep: { seconds in try recorder.record(seconds) },
            backoff: backoff
        )
        transport.start()

        await recorder.waitUntilFull()
        transport.stop()

        XCTAssertEqual(recorder.delays, [1, 2, 4, 8, 16, 32, 60, 60])
    }

    func testBackoffEqualJitterStaysWithinCeiling() {
        var backoff = CompanionRelayBackoff(base: 1, cap: 60)
        for attempt in 0..<10 {
            let ceiling = backoff.ceiling(forAttempt: attempt)
            let delay = backoff.next()
            XCTAssertGreaterThanOrEqual(delay, ceiling / 2)
            XCTAssertLessThanOrEqual(delay, ceiling)
        }
    }

    // MARK: - Helpers

    private func makeTransport(socket: ScriptedRelaySocket) -> CompanionRelayTransport {
        CompanionRelayTransport(
            url: URL(string: "wss://relay.test")!,
            services: services,
            makeSocket: { _ in socket },
            sleep: { _ in },
            backoff: CompanionRelayBackoff(jitter: { $0 })
        )
    }

    /// Pushes a challenge, consumes+discards the auth, and pushes ready so the
    /// transport enters its frame-pumping state.
    private func completeHandshake(on socket: ScriptedRelaySocket) async throws {
        socket.pushInbound(try relayFrameText(.challenge(
            CompanionRelayChallenge(nonce: CompanionBase64URL.encode(Data(repeating: 3, count: 16)), ts: 1)
        )))
        _ = await socket.nextSent() // auth
        socket.pushInbound(try relayFrameText(.ready(
            CompanionRelayReady(deviceId: macIdentity.deviceId)
        )))
    }

    private func relayFrameText(_ frame: CompanionRelayFrame) throws -> String {
        String(decoding: try encoder.encode(frame), as: UTF8.self)
    }

    private func decodeRelay(_ text: String) throws -> CompanionRelayFrame {
        try decoder.decode(CompanionRelayFrame.self, from: Data(text.utf8))
    }

    /// Builds a `relay.frame` carrying a `pairing.request` envelope from `peer`.
    private func pairingRelayFrame(from peer: PhoneRelayPeer, macId: String) throws -> String {
        let request = CompanionPairingRequest(
            phoneDeviceId: peer.deviceId,
            phonePubKey: peer.deviceId,
            phoneName: "Phone \(peer.deviceId.prefix(4))",
            proof: "accepted"
        )
        let envelope = CompanionEnvelope(id: UUID().uuidString, message: .pairingRequest(request))
        let sealed = CompanionBase64URL.encode(try encoder.encode(envelope))
        return try relayFrameText(.frame(
            CompanionRelaySealedFrame(to: macId, from: peer.deviceId, sealed: sealed)
        ))
    }

    /// Awaits the next outbound `relay.frame` and decodes its sealed payload as a
    /// `pairing.confirm`, returning the wrapping sealed frame (for its `to`).
    private func nextConfirm(on socket: ScriptedRelaySocket) async throws -> CompanionRelaySealedFrame {
        let text = await socket.nextSent()
        guard case .frame(let sealed) = try decodeRelay(text) else {
            throw CompanionTransportError.network("expected relay.frame, got \(text)")
        }
        let inner = try XCTUnwrap(CompanionBase64URL.decode(sealed.sealed))
        let envelope = try decoder.decode(CompanionEnvelope.self, from: inner)
        guard case .pairingConfirm = envelope.message else {
            throw CompanionTransportError.network("expected pairing.confirm, got \(envelope.type)")
        }
        return sealed
    }
}

// MARK: - Scripted relay socket

/// An in-memory `CompanionRelaySocket` the test scripts by hand: `pushInbound`
/// queues frames for the transport to `receive`, `nextSent` awaits frames the
/// transport sends.
private final class ScriptedRelaySocket: CompanionRelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var inboundWaiters: [CheckedContinuation<String?, Never>] = []
    private var isClosed = false

    private var sent: [String] = []
    private var sentWaiters: [CheckedContinuation<String, Never>] = []

    func send(_ text: String) async throws {
        takeSentWaiter(appending: text)?.resume(returning: text)
    }

    private func takeSentWaiter(appending text: String) -> CheckedContinuation<String, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if !sentWaiters.isEmpty { return sentWaiters.removeFirst() }
        sent.append(text)
        return nil
    }

    func receive() async throws -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            lock.lock()
            if !inbound.isEmpty {
                let text = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                inboundWaiters.append(continuation)
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
        let waiters = inboundWaiters
        inboundWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: nil) }
    }

    func pushInbound(_ text: String) {
        lock.lock()
        if let waiter = inboundWaiters.first {
            inboundWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            inbound.append(text)
            lock.unlock()
        }
    }

    func nextSent() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            lock.lock()
            if !sent.isEmpty {
                let text = sent.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else {
                sentWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// MARK: - Sleep recorder (virtual clock)

/// Records the backoff delays the transport asks to sleep, then breaks the loop
/// by throwing once `stopAfter` delays are collected.
private final class SleepRecorder: @unchecked Sendable {
    private struct Stop: Error {}

    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private let stopAfter: Int
    private var fullWaiters: [CheckedContinuation<Void, Never>] = []

    init(stopAfter: Int) {
        self.stopAfter = stopAfter
    }

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ seconds: TimeInterval) throws {
        lock.lock()
        recorded.append(seconds)
        let reachedCap = recorded.count >= stopAfter
        let waiters = reachedCap ? fullWaiters : []
        if reachedCap { fullWaiters.removeAll() }
        lock.unlock()
        waiters.forEach { $0.resume() }
        if reachedCap { throw Stop() }
    }

    func waitUntilFull() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if recorded.count >= stopAfter {
                lock.unlock()
                continuation.resume()
            } else {
                fullWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// MARK: - Phone peer

/// A phone-side identity used only to address `from`/`to` in relay frames.
private struct PhoneRelayPeer {
    let signingKey = Curve25519.Signing.PrivateKey()
    var deviceId: String { CompanionBase64URL.encode(signingKey.publicKey.rawRepresentation) }
}

// MARK: - Fake services

/// Minimal `CompanionSessionServicing` for relay tests: accepts every pairing
/// proof and records the device ids the demultiplexed sessions pair.
@MainActor
private final class FakeRelayServices: CompanionSessionServicing {
    /// Empty dashboard source; the relay demux tests exercise pairing, not state.
    private final class EmptyDashboardProvider: CompanionDashboardStateProviding {
        func companionDashboardWorklanes() -> [CompanionDashboardWorklane] { [] }
    }

    let identity: CompanionDeviceIdentity
    var recordedPairings: [String] = []
    private let provider = EmptyDashboardProvider()
    private let feed: CompanionDashboardFeed

    init(identity: CompanionDeviceIdentity) {
        self.identity = identity
        self.feed = CompanionDashboardFeed(provider: provider)
    }

    var localDeviceName: String { "TestMac" }
    var appVersion: String { "1.0" }

    func pairedDevice(withId deviceId: String) -> CompanionPairedDevice? { nil }
    func verifyPairingProof(phonePublicKey: String, proof: String) -> Bool { true }
    func recordPairing(_ device: CompanionPairedDevice) { recordedPairings.append(device.deviceId) }
    func markDeviceSeen(deviceId: String) {}

    func dashboardSnapshot() -> CompanionDashboardSnapshot { feed.makeSnapshot() }

    func addDashboardSubscriber(
        _ handler: @escaping (CompanionDashboardDelta) -> Void
    ) -> CompanionDashboardSubscriptionToken {
        feed.addSubscriber(handler)
    }

    func removeDashboardSubscriber(_ token: CompanionDashboardSubscriptionToken) {
        feed.removeSubscriber(token)
    }

    func routeInput(_ message: CompanionMessage) -> CompanionInputAck {
        CompanionInputAck(ok: false, error: "unsupported")
    }
}
