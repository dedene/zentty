import CryptoKit
import Foundation
import OSLog

private let companionSessionLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionSession")

/// One connection's lifecycle: decode a frame, route it, encode the reply.
///
/// A fresh connection is either a one-time pairing (plaintext `pairing.*`) or an
/// encrypted session for an already-paired device. The first frame decides:
/// a `pairing.request` envelope takes the pairing path; a crypto handshake frame
/// takes the session path (ECDH → sealed `session.hello` → `session.ready` →
/// routed traffic).
///
/// `@MainActor`-isolated (one instance per connection, each driven by its own
/// `run()` task). Main-actor isolation keeps the crypto counters, service calls,
/// and outbound sends serialized without moving non-`Sendable` CryptoKit keys
/// across actors; only the transport `send`/`receive` suspend.
@MainActor
final class CompanionSession {
    private let connection: CompanionTransportConnection
    private weak var services: (any CompanionSessionServicing)?

    private var crypto: CompanionSessionCrypto?
    private var didCompleteHello = false
    private var dashboardToken: CompanionDashboardSubscriptionToken?
    private var paneTextToken: CompanionPaneWatchToken?

    /// The paired device this connection authenticated as, once the crypto
    /// handshake resolves it. Lets the bridge drop a live session when its device
    /// is revoked in Settings.
    private(set) var pairedDeviceId: String?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(connection: CompanionTransportConnection, services: any CompanionSessionServicing) {
        self.connection = connection
        self.services = services
    }

    // MARK: - Run loop

    func run() async {
        do {
            let continued = try await handleOpeningFrame()
            if continued {
                try await runEncryptedLoop()
            }
        } catch CompanionTransportError.closed {
            // Peer hung up; normal.
        } catch {
            companionSessionLogger.error(
                "Companion session ended with error: \(String(describing: error), privacy: .public)"
            )
        }
        teardown()
    }

    private func teardown() {
        if let dashboardToken {
            services?.removeDashboardSubscriber(dashboardToken)
            self.dashboardToken = nil
        }
        if let paneTextToken {
            services?.removePaneTextWatcher(paneTextToken)
            self.paneTextToken = nil
        }
        connection.close()
    }

    // MARK: - Opening frame

    /// Reads the first frame and dispatches to pairing or the crypto handshake.
    /// Returns `true` when an encrypted session was established and the caller
    /// should proceed to the routed loop; `false` when the connection is done
    /// (pairing completed, or the handshake was rejected).
    private func handleOpeningFrame() async throws -> Bool {
        guard let frame = try await connection.receive() else { return false }

        if let envelope = try? decoder.decode(CompanionEnvelope.self, from: frame),
           case .pairingRequest(let request) = envelope.message {
            try await handlePairing(request)
            return false
        }

        guard let handshake = try? decoder.decode(CompanionCryptoHandshakeFrame.self, from: frame) else {
            try await sendPlaintext(
                .sessionError(CompanionSessionError(code: "malformed_open", message: "Unrecognized opening frame", fatal: true))
            )
            return false
        }

        return try await establishCrypto(clientHello: handshake)
    }

    // MARK: - Pairing (plaintext)

    private func handlePairing(_ request: CompanionPairingRequest) async throws {
        guard let services else { return }
        let isValid = services.verifyPairingProof(
            phonePublicKey: request.phonePubKey,
            proof: request.proof
        )
        guard isValid else {
            try await sendPlaintext(.pairingReject(CompanionPairingReject(reason: "invalid_proof")))
            return
        }

        let now = Date()
        let device = CompanionPairedDevice(
            deviceId: request.phoneDeviceId,
            publicKey: request.phonePubKey,
            name: request.phoneName,
            pairedAt: now,
            lastSeenAt: now
        )
        services.recordPairing(device)
        try await sendPlaintext(.pairingConfirm(CompanionPairingConfirm(macName: services.localDeviceName)))
    }

    // MARK: - Crypto handshake (mac / server role)

    private func establishCrypto(clientHello: CompanionCryptoHandshakeFrame) async throws -> Bool {
        guard let services else { return false }

        guard
            let phoneDeviceId = clientHello.deviceId,
            let phoneEphemeralB64 = clientHello.ephemeralPublicKey,
            let phoneEphemeralData = CompanionBase64URL.decode(phoneEphemeralB64),
            let phoneEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneEphemeralData)
        else {
            try await sendPlaintext(
                .sessionError(CompanionSessionError(code: "malformed_handshake", message: "Missing ephemeral key", fatal: true))
            )
            return false
        }

        guard
            let paired = services.pairedDevice(withId: phoneDeviceId),
            let phoneIdentityData = CompanionBase64URL.decode(paired.publicKey),
            let phoneIdentity = try? Curve25519.Signing.PublicKey(rawRepresentation: phoneIdentityData)
        else {
            try await sendPlaintext(
                .sessionError(CompanionSessionError(code: "not_paired", message: "Device is not paired", fatal: true))
            )
            return false
        }

        let identity = services.identity
        let macEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let macSignature = try CompanionHandshake.localSignature(
            role: .mac,
            localIdentity: identity.signingPrivateKey,
            localEphemeralPublicKey: macEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: phoneIdentity.rawRepresentation,
            peerEphemeralPublicKey: phoneEphemeral.rawRepresentation
        )

        let serverHello = CompanionCryptoHandshakeFrame(
            deviceId: identity.deviceId,
            ephemeralPublicKey: CompanionBase64URL.encode(macEphemeral.publicKey.rawRepresentation),
            signature: CompanionBase64URL.encode(macSignature)
        )
        try await sendPlaintext(frame: serverHello)

        guard let authFrameData = try await connection.receive() else { return false }
        guard
            let authFrame = try? decoder.decode(CompanionCryptoHandshakeFrame.self, from: authFrameData),
            let phoneSignatureB64 = authFrame.signature,
            let phoneSignature = CompanionBase64URL.decode(phoneSignatureB64)
        else {
            try await sendPlaintext(
                .sessionError(CompanionSessionError(code: "malformed_handshake", message: "Missing signature", fatal: true))
            )
            return false
        }

        do {
            crypto = try CompanionHandshake.establish(
                role: .mac,
                localIdentity: identity.signingPrivateKey,
                localEphemeral: macEphemeral,
                peerIdentityPublicKey: phoneIdentity,
                peerEphemeralPublicKey: phoneEphemeral,
                peerSignature: phoneSignature
            )
        } catch {
            try await sendPlaintext(
                .sessionError(CompanionSessionError(code: "bad_signature", message: "Handshake signature invalid", fatal: true))
            )
            return false
        }

        services.markDeviceSeen(deviceId: phoneDeviceId)
        pairedDeviceId = phoneDeviceId
        return true
    }

    /// Tears down the connection out-of-band (e.g. its device was revoked in
    /// Settings). The `run()` loop's pending `receive()` unblocks and completes
    /// the normal teardown path.
    func requestClose() {
        connection.close()
    }

    // MARK: - Encrypted routed loop

    private func runEncryptedLoop() async throws {
        while let frame = try await connection.receive() {
            guard let crypto else { break }
            let plaintext: Data
            do {
                plaintext = try crypto.open(frame)
            } catch {
                companionSessionLogger.error(
                    "Dropping unopenable frame: \(String(describing: error), privacy: .public)"
                )
                continue
            }
            guard let envelope = try? decoder.decode(CompanionEnvelope.self, from: plaintext) else {
                try await sendSealed(
                    .sessionError(CompanionSessionError(code: "malformed_frame", message: "Undecodable envelope", fatal: false))
                )
                continue
            }
            try await route(envelope)
        }
    }

    private func route(_ envelope: CompanionEnvelope) async throws {
        guard let services else { return }

        switch envelope.message {
        case .sessionHello(let hello):
            let effective = CompanionVersionNegotiation.effectiveVersion(
                local: CompanionVersionNegotiation.localRange,
                remote: hello.supported
            )
            guard let effective else {
                try await sendSealed(
                    .sessionError(CompanionSessionError(code: "incompatible_version", message: "No shared protocol version", fatal: true)),
                    replyTo: envelope.id
                )
                return
            }
            didCompleteHello = true
            try await sendSealed(.sessionReady(CompanionSessionReady(v: effective)), replyTo: envelope.id)

        case .sessionPing(let ping):
            try await sendSealed(.sessionPong(CompanionSessionPong(ts: ping.ts)), replyTo: envelope.id)

        case .dashboardSubscribe:
            guard didCompleteHello else {
                try await sendExpectedHello(replyTo: envelope.id)
                return
            }
            let snapshot = services.dashboardSnapshot()
            try await sendSealed(.dashboardSnapshot(snapshot))
            subscribeToDashboard()

        case .inputText, .inputKey, .inputQuickAction:
            guard didCompleteHello else {
                try await sendExpectedHello(replyTo: envelope.id)
                return
            }
            let ack = services.routeInput(envelope.message)
            try await sendSealed(.inputAck(ack), replyTo: envelope.id)

        case .paneWatch(let payload):
            guard didCompleteHello else {
                try await sendExpectedHello(replyTo: envelope.id)
                return
            }
            let token = ensurePaneTextWatcher(services: services)
            services.watchPane(token: token, paneId: payload.paneId)

        case .paneUnwatch(let payload):
            guard didCompleteHello else {
                try await sendExpectedHello(replyTo: envelope.id)
                return
            }
            if let paneTextToken {
                services.unwatchPane(token: paneTextToken, paneId: payload.paneId)
            }

        case .paneScrollback(let payload):
            guard didCompleteHello else {
                try await sendExpectedHello(replyTo: envelope.id)
                return
            }
            // The request half carries `lineLimit`; a stray reply half (text only)
            // has nothing for the mac to do, so treat it as the request shape.
            let reply = services.paneScrollback(paneId: payload.paneId, lineLimit: payload.lineLimit)
            try await sendSealed(.paneScrollback(reply), replyTo: envelope.id)

        default:
            try await sendSealed(
                .sessionError(CompanionSessionError(code: "unsupported_type", message: "Unsupported message type: \(envelope.type)", fatal: false)),
                replyTo: envelope.id
            )
        }
    }

    private func sendExpectedHello(replyTo: String) async throws {
        try await sendSealed(
            .sessionError(CompanionSessionError(code: "expected_hello", message: "session.hello required first", fatal: true)),
            replyTo: replyTo
        )
    }

    // MARK: - Dashboard subscription

    private func subscribeToDashboard() {
        guard dashboardToken == nil, let services else { return }
        dashboardToken = services.addDashboardSubscriber { [weak self] delta in
            Task { [weak self] in await self?.deliverDelta(delta) }
        }
    }

    private func deliverDelta(_ delta: CompanionDashboardDelta) async {
        do {
            try await sendSealed(.dashboardDelta(delta))
        } catch {
            companionSessionLogger.error(
                "Failed to send dashboard delta: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Pane text watch

    /// Lazily registers this connection's `pane.text` sink, once, and returns its
    /// token. Subsequent `pane.watch` calls reuse it.
    private func ensurePaneTextWatcher(services: any CompanionSessionServicing) -> CompanionPaneWatchToken {
        if let paneTextToken { return paneTextToken }
        let token = services.addPaneTextWatcher { [weak self] text in
            Task { [weak self] in await self?.deliverPaneText(text) }
        }
        paneTextToken = token
        return token
    }

    private func deliverPaneText(_ text: CompanionPaneText) async {
        do {
            try await sendSealed(.paneText(text))
        } catch {
            companionSessionLogger.error(
                "Failed to send pane text: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Framing

    private func sendPlaintext(_ message: CompanionMessage) async throws {
        let envelope = CompanionEnvelope(id: UUID().uuidString, message: message)
        try await connection.send(try encoder.encode(envelope))
    }

    private func sendPlaintext(frame: CompanionCryptoHandshakeFrame) async throws {
        try await connection.send(try encoder.encode(frame))
    }

    private func sendSealed(_ message: CompanionMessage, replyTo: String? = nil) async throws {
        guard let crypto else { throw CompanionTransportError.closed }
        let envelope = CompanionEnvelope(id: UUID().uuidString, replyTo: replyTo, message: message)
        let sealed = try crypto.seal(try encoder.encode(envelope))
        try await connection.send(sealed)
    }
}
