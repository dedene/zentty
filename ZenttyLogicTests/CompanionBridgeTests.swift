import CryptoKit
import XCTest

@testable import Zentty

/// End-to-end bridge tests over an in-memory transport (no sockets): a pairing
/// exchange, a full crypto handshake driven from the phone side, a dashboard
/// subscribe → snapshot → delta round trip, an input.text injection, and the
/// unknown-message → `session.error` path.
@MainActor
final class CompanionBridgeTests: XCTestCase {
    // MARK: - Test doubles

    private final class InMemoryKeychain: CompanionKeychainStoring {
        private var storage: [String: Data] = [:]
        func read(account: String) throws -> Data? { storage[account] }
        func store(_ data: Data, account: String) throws { storage[account] = data }
        func delete(account: String) throws { storage[account] = nil }
    }

    private final class FakeDashboardProvider: CompanionDashboardStateProviding {
        var worklanes: [CompanionDashboardWorklane] = []
        func companionDashboardWorklanes() -> [CompanionDashboardWorklane] { worklanes }
    }

    private final class FakeInputSink: CompanionInputSink {
        var sends: [(text: String, paneId: String)] = []
        func companionSendText(_ text: String, toPaneId paneId: String) -> Bool {
            sends.append((text, paneId))
            return true
        }
    }

    private final class FakePaneTextProvider: CompanionPaneTextProviding {
        var readouts: [String: CompanionPaneTextReadout] = [:]
        func companionReadPaneText(paneId: String, includeScrollback: Bool, lineLimit: Int?) -> CompanionPaneTextReadout? {
            readouts[paneId]
        }
    }

    private final class FakeTranscriptSource: CompanionTranscriptSourceProviding {
        var targets: [String: CompanionTranscriptTarget] = [:]
        func companionTranscriptTarget(forPaneId paneId: String) -> CompanionTranscriptTarget? {
            targets[paneId]
        }
    }

    /// A manually-fired transcript file watch: the feed's production watcher uses
    /// `DispatchSource`; here the test triggers `.changed` / `.vanished` directly.
    private final class ManualTranscriptWatch: CompanionTranscriptFileWatch {
        var onEvent: (@MainActor (CompanionTranscriptFileEvent) -> Void)?
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    private final class FakeLeaseApplier: CompanionLeaseTakeoverApplying {
        private(set) var applied: [(paneId: String, cols: Int, rows: Int, deviceName: String)] = []
        private(set) var restored: [String] = []
        var onTakeBackByPane: [String: () -> Void] = [:]
        @discardableResult
        func companionApplyLeaseTakeover(paneId: String, cols: Int, rows: Int, deviceName: String, onTakeBack: @escaping () -> Void) -> Bool {
            applied.append((paneId, cols, rows, deviceName))
            onTakeBackByPane[paneId] = onTakeBack
            return true
        }
        func companionRestoreLeasedPane(paneId: String) { restored.append(paneId) }
    }

    // MARK: - Fixture

    private var pairingStore: CompanionPairingStore!
    private var provider: FakeDashboardProvider!
    private var sink: FakeInputSink!
    private var feed: CompanionDashboardFeed!
    private var paneTextProvider: FakePaneTextProvider!
    private var paneTextFeed: CompanionPaneTextFeed!
    private var transcriptSource: FakeTranscriptSource!
    private var transcriptFeed: CompanionTranscriptFeed!
    private var transcriptWatch: ManualTranscriptWatch!
    private var leaseApplier: FakeLeaseApplier!
    private var leaseManager: CompanionLeaseManager!
    private var server: CompanionBridgeServer!
    private var macIdentity: CompanionDeviceIdentity!
    private var tempDir: URL!

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        macIdentity = CompanionDeviceIdentity.loadOrCreate(keychain: InMemoryKeychain())
        pairingStore = CompanionPairingStore(configDirectoryURL: tempDir)
        provider = FakeDashboardProvider()
        sink = FakeInputSink()
        feed = CompanionDashboardFeed(provider: provider, debounceInterval: 0.01)
        paneTextProvider = FakePaneTextProvider()
        paneTextFeed = CompanionPaneTextFeed(provider: paneTextProvider, debounceInterval: 0.01)
        transcriptSource = FakeTranscriptSource()
        let watch = ManualTranscriptWatch()
        transcriptWatch = watch
        transcriptFeed = CompanionTranscriptFeed(
            source: transcriptSource,
            watcherFactory: { _, onEvent in
                watch.onEvent = onEvent
                return watch
            }
        )
        leaseApplier = FakeLeaseApplier()
        leaseManager = CompanionLeaseManager(applier: leaseApplier)
        server = CompanionBridgeServer(
            identity: macIdentity,
            pairingStore: pairingStore,
            dashboardFeed: feed,
            paneTextFeed: paneTextFeed,
            transcriptFeed: transcriptFeed,
            inputRouter: CompanionInputRouter(sink: sink),
            leaseManager: leaseManager,
            isFeatureEnabled: { true }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Pairing

    func testPairingPersistsDevice() async throws {
        let phone = PhoneIdentity()
        let offer = pairingStore.mintOffer()

        let (phoneConn, serverConn) = CompanionInMemoryConnection.makePair()
        let session = CompanionSession(connection: serverConn, services: server)
        let runTask = Task { await session.run() }

        let request = CompanionPairingRequest(
            phoneDeviceId: phone.deviceId,
            phonePubKey: phone.deviceId,
            phoneName: "Test iPhone",
            proof: phone.pairingProof(secret: offer.secret)
        )
        try await send(.pairingRequest(request), over: phoneConn)

        let confirm = try await receiveEnvelope(over: phoneConn)
        guard case .pairingConfirm(let payload) = confirm.message else {
            return XCTFail("Expected pairing.confirm, got \(confirm.type)")
        }
        XCTAssertTrue(payload.paired)

        await runTask.value
        XCTAssertTrue(pairingStore.contains(deviceId: phone.deviceId))
    }

    func testPairingRejectsBadProof() async throws {
        let phone = PhoneIdentity()
        _ = pairingStore.mintOffer()

        let (phoneConn, serverConn) = CompanionInMemoryConnection.makePair()
        let session = CompanionSession(connection: serverConn, services: server)
        let runTask = Task { await session.run() }

        let request = CompanionPairingRequest(
            phoneDeviceId: phone.deviceId,
            phonePubKey: phone.deviceId,
            phoneName: "Test iPhone",
            proof: CompanionBase64URL.encode(Data(repeating: 0, count: 32))
        )
        try await send(.pairingRequest(request), over: phoneConn)

        let reply = try await receiveEnvelope(over: phoneConn)
        guard case .pairingReject = reply.message else {
            return XCTFail("Expected pairing.reject, got \(reply.type)")
        }
        await runTask.value
        XCTAssertFalse(pairingStore.contains(deviceId: phone.deviceId))
    }

    // MARK: - Encrypted session

    func testHandshakeSnapshotDeltaAndInput() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Test iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )
        provider.worklanes = [Self.worklane(paneId: "pane-1", state: .running, attention: false)]

        let driver = try await openEncryptedSession(phone: phone)

        // session.hello → session.ready
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Test iPhone",
            appVersion: "1.0"
        )))
        let ready = try await driver.receive()
        guard case .sessionReady(let readyPayload) = ready.message else {
            return XCTFail("Expected session.ready, got \(ready.type)")
        }
        XCTAssertEqual(readyPayload.v, 1)

        // dashboard.subscribe → dashboard.snapshot
        try await driver.send(.dashboardSubscribe(CompanionDashboardSubscribe()))
        let snapshot = try await driver.receive()
        guard case .dashboardSnapshot(let snapshotPayload) = snapshot.message else {
            return XCTFail("Expected dashboard.snapshot, got \(snapshot.type)")
        }
        XCTAssertEqual(snapshotPayload.worklanes.first?.panes.first?.paneId, "pane-1")
        XCTAssertEqual(snapshotPayload.worklanes.first?.panes.first?.state, .running)

        // Wait until the session has registered as a subscriber before mutating.
        while !feed.hasSubscribers { await Task.yield() }

        // A synthetic status change yields a delta.
        provider.worklanes = [Self.worklane(paneId: "pane-1", state: .needsInput, attention: true)]
        feed.flushNow()
        let delta = try await driver.receive()
        guard case .dashboardDelta(let deltaPayload) = delta.message else {
            return XCTFail("Expected dashboard.delta, got \(delta.type)")
        }
        XCTAssertEqual(deltaPayload.updated.first?.paneId, "pane-1")
        XCTAssertEqual(deltaPayload.updated.first?.state, .needsInput)
        XCTAssertTrue(deltaPayload.updated.first?.requiresHumanAttention ?? false)

        // input.text routes to the sink and is acked.
        try await driver.send(.inputText(CompanionInputText(paneId: "pane-1", text: "ship it\r")))
        let ack = try await driver.receive()
        guard case .inputAck(let ackPayload) = ack.message else {
            return XCTFail("Expected input.ack, got \(ack.type)")
        }
        XCTAssertTrue(ackPayload.ok)
        XCTAssertEqual(sink.sends.count, 1)
        XCTAssertEqual(sink.sends.first?.text, "ship it\r")
        XCTAssertEqual(sink.sends.first?.paneId, "pane-1")

        driver.close()
        await driver.runTask.value
    }

    func testPaneWatchStreamsTextAndScrollbackReplies() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Test iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )
        paneTextProvider.readouts["pane-1"] = CompanionPaneTextReadout(
            text: "build succeeded",
            gridCols: 100,
            gridRows: 30,
            cursorRow: nil
        )

        let driver = try await openEncryptedSession(phone: phone)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Test iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready

        // pane.watch, then a ping/pong to fence: the session processes frames in
        // order, so a pong proves the watch is registered before we pulse content.
        try await driver.send(.paneWatch(CompanionPaneWatch(paneId: "pane-1")))
        try await driver.send(.sessionPing(CompanionSessionPing(ts: 1)))
        let pong = try await driver.receive()
        guard case .sessionPong = pong.message else {
            return XCTFail("Expected session.pong, got \(pong.type)")
        }

        // A render pulse yields exactly one debounced pane.text.
        server.ingestPaneContentChange(paneID: "pane-1")
        let text = try await driver.receive()
        guard case .paneText(let textPayload) = text.message else {
            return XCTFail("Expected pane.text, got \(text.type)")
        }
        XCTAssertEqual(textPayload.paneId, "pane-1")
        XCTAssertEqual(textPayload.seq, 1)
        XCTAssertEqual(textPayload.viewport, "build succeeded")
        XCTAssertEqual(textPayload.gridCols, 100)
        XCTAssertEqual(textPayload.gridRows, 30)

        // pane.scrollback request → correlated reply carrying text.
        try await driver.send(.paneScrollback(CompanionPaneScrollback(paneId: "pane-1", lineLimit: 200)))
        let scrollback = try await driver.receive()
        guard case .paneScrollback(let scrollbackPayload) = scrollback.message else {
            return XCTFail("Expected pane.scrollback, got \(scrollback.type)")
        }
        XCTAssertEqual(scrollbackPayload.paneId, "pane-1")
        XCTAssertEqual(scrollbackPayload.text, "build succeeded")
        XCTAssertNotNil(scrollback.replyTo) // reply is correlated to the request

        driver.close()
        await driver.runTask.value
    }

    func testTranscriptSubscribeSnapshotThenDelta() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Test iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )

        // A real transcript file on disk, resolved via the live-path shortcut.
        let transcriptURL = tempDir.appendingPathComponent("session.jsonl")
        let userLine = #"{"type":"user","uuid":"u1","timestamp":"2026-07-20T17:50:44.000Z","message":{"role":"user","content":"hello"}}"#
        try (userLine + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        transcriptSource.targets["pane-1"] = CompanionTranscriptTarget(
            tool: .claudeCode,
            sessionID: "sess-1",
            workingDirectory: "/tmp/project",
            liveTranscriptPath: transcriptURL.path
        )

        let driver = try await openEncryptedSession(phone: phone)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Test iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready

        // transcript.subscribe → transcript.snapshot (correlated).
        try await driver.send(.transcriptSubscribe(CompanionTranscriptSubscribe(paneId: "pane-1")))
        let snapshot = try await driver.receive()
        guard case .transcriptSnapshot(let snapshotPayload) = snapshot.message else {
            return XCTFail("Expected transcript.snapshot, got \(snapshot.type)")
        }
        XCTAssertEqual(snapshotPayload.paneId, "pane-1")
        XCTAssertEqual(snapshotPayload.sessionId, "sess-1")
        XCTAssertFalse(snapshotPayload.truncated)
        XCTAssertEqual(snapshotPayload.entries.count, 1)
        XCTAssertEqual(snapshotPayload.entries.first?.role, .user)
        XCTAssertEqual(snapshotPayload.entries.first?.text, "hello")
        XCTAssertNotNil(snapshot.replyTo)

        // Append an assistant line, fire the (manual) file watch → transcript.delta.
        let assistantLine = #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-20T17:51:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}"#
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistantLine + "\n").utf8))
        try handle.close()
        transcriptWatch.onEvent?(.changed)

        let delta = try await driver.receive()
        guard case .transcriptDelta(let deltaPayload) = delta.message else {
            return XCTFail("Expected transcript.delta, got \(delta.type)")
        }
        XCTAssertEqual(deltaPayload.paneId, "pane-1")
        XCTAssertEqual(deltaPayload.entries.count, 1)
        XCTAssertEqual(deltaPayload.entries.first?.role, .assistant)
        XCTAssertEqual(deltaPayload.entries.first?.text, "hi there")

        driver.close()
        await driver.runTask.value
    }

    func testLeaseRequestGrantsAppliesTakeoverAndTakebackRevokes() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Peter's iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )

        let driver = try await openEncryptedSession(phone: phone)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Peter's iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready

        // lease.request → lease.grant (correlated), takeover applied to the pane.
        try await driver.send(.leaseRequest(CompanionLeaseRequest(paneId: "pane-1", cols: 45, rows: 30)))
        let granted = try await driver.receive()
        guard case .leaseGrant(let grant) = granted.message else {
            return XCTFail("Expected lease.grant, got \(granted.type)")
        }
        XCTAssertEqual(grant.paneId, "pane-1")
        XCTAssertEqual(grant.effective, CompanionGrid(cols: 45, rows: 30))
        XCTAssertTrue(grant.isCurrentClientLimiting) // in-range: clamp changed nothing
        XCTAssertNotNil(granted.replyTo)
        XCTAssertEqual(leaseApplier.applied.count, 1)
        XCTAssertEqual(leaseApplier.applied.first?.deviceName, "Peter's iPhone")

        // Desktop take-back revokes the lease over the wire and restores the pane.
        leaseApplier.onTakeBackByPane["pane-1"]?()
        let revoked = try await driver.receive()
        guard case .leaseRevoked(let payload) = revoked.message else {
            return XCTFail("Expected lease.revoked, got \(revoked.type)")
        }
        XCTAssertEqual(payload.leaseId, grant.leaseId)
        XCTAssertEqual(payload.reason, .takeback)
        XCTAssertEqual(leaseApplier.restored, ["pane-1"])

        driver.close()
        await driver.runTask.value
    }

    /// Disabling the feature (or unpairing the last device) must not only stop the
    /// listener but also force-close every live LAN session and revoke all control
    /// leases, so a connected phone can't stay live with a takeover placeholder
    /// pinned on the desktop. The teardown is edge-triggered on the running →
    /// disabled flip.
    func testDisablingFeatureClosesLiveSessionsAndRevokesLeases() async throws {
        // A server whose feature toggle we flip at runtime; the LAN listener is
        // gated off so the run-state transition needs no real socket.
        var featureEnabled = true
        let gatedServer = CompanionBridgeServer(
            identity: macIdentity,
            pairingStore: pairingStore,
            dashboardFeed: feed,
            paneTextFeed: paneTextFeed,
            transcriptFeed: transcriptFeed,
            inputRouter: CompanionInputRouter(sink: sink),
            leaseManager: leaseManager,
            isFeatureEnabled: { featureEnabled },
            lanListenerEnabled: { false }
        )

        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Peter's iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )

        // Feature on + a paired device → running (isRunning becomes true).
        gatedServer.refreshAdvertisingState()

        // A live LAN session takes a lease, pinning a takeover placeholder.
        let driver = try await openEncryptedSession(phone: phone, server: gatedServer)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Peter's iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready
        try await driver.send(.leaseRequest(CompanionLeaseRequest(paneId: "pane-1", cols: 80, rows: 24)))
        let granted = try await driver.receive()
        guard case .leaseGrant = granted.message else {
            return XCTFail("Expected lease.grant, got \(granted.type)")
        }
        XCTAssertEqual(leaseApplier.applied.count, 1)
        XCTAssertTrue(leaseApplier.restored.isEmpty)

        // Disable the feature and refresh: the live session is force-closed and the
        // lease revoked, restoring the pane on the desktop.
        featureEnabled = false
        gatedServer.refreshAdvertisingState()

        XCTAssertEqual(leaseApplier.restored, ["pane-1"])
        // The server closed the connection out from under the phone; its run loop
        // ends, proving the session was force-closed (not left dangling).
        await driver.runTask.value

        // Edge-triggered: a lease created while already disabled must NOT be swept
        // by a further disabled refresh (no running → disabled transition).
        let lingeringToken = leaseManager.addClient { _ in }
        _ = leaseManager.request(token: lingeringToken, paneId: "pane-2", cols: 80, rows: 24, deviceName: "x")
        XCTAssertEqual(leaseApplier.applied.count, 2)
        gatedServer.refreshAdvertisingState()
        XCTAssertFalse(leaseApplier.restored.contains("pane-2"))
    }

    func testUnknownMessageYieldsUnsupportedError() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Test iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )

        let driver = try await openEncryptedSession(phone: phone)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Test iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready

        try await driver.send(.unsupported(type: "widget.frobnicate", payload: .object([:])))
        let error = try await driver.receive()
        guard case .sessionError(let payload) = error.message else {
            return XCTFail("Expected session.error, got \(error.type)")
        }
        XCTAssertEqual(payload.code, "unsupported_type")
        XCTAssertFalse(payload.fatal)

        driver.close()
        await driver.runTask.value
    }

    // MARK: - Push

    func testPushRegisterPersistsTokenOnPairing() async throws {
        let phone = PhoneIdentity()
        try pairingStore.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "Test iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )

        let driver = try await openEncryptedSession(phone: phone)
        try await driver.send(.sessionHello(CompanionSessionHello(
            supported: CompanionVersionRange(min: 1, max: 1),
            deviceName: "Test iPhone",
            appVersion: "1.0"
        )))
        _ = try await driver.receive() // session.ready

        // push.register stores the token on the pairing. No gateway URL is
        // configured here, so nothing leaves the process.
        try await driver.send(.pushRegister(CompanionPushRegister(
            platform: .apns,
            token: "apns-token-abc",
            deviceId: phone.deviceId
        )))
        // Fence with ping/pong: in-order processing means the token is persisted
        // by the time the pong arrives.
        try await driver.send(.sessionPing(CompanionSessionPing(ts: 1)))
        let pong = try await driver.receive()
        guard case .sessionPong = pong.message else {
            return XCTFail("Expected session.pong, got \(pong.type)")
        }

        XCTAssertEqual(pairingStore.device(withId: phone.deviceId)?.pushToken, "apns-token-abc")
        XCTAssertEqual(pairingStore.device(withId: phone.deviceId)?.pushPlatform, .apns)

        driver.close()
        await driver.runTask.value
    }

    // MARK: - Helpers

    private static func worklane(paneId: String, state: PaneAgentState, attention: Bool) -> CompanionDashboardWorklane {
        let summary = CompanionPaneSummary(
            paneId: paneId,
            worklaneId: "wl-1",
            title: "Pane",
            tool: "Claude Code",
            state: CompanionDashboardMapping.paneState(from: state),
            interactionKind: state == .needsInput ? .genericInput : .none,
            requiresHumanAttention: attention,
            workingDirectory: "/tmp",
            sessionId: "s-1",
            hasTranscript: true,
            taskProgress: nil
        )
        return CompanionDashboardWorklane(
            id: "wl-1",
            title: "Worklane",
            windowId: 1,
            attention: attention,
            panes: [summary]
        )
    }

    private func send(_ message: CompanionMessage, over connection: CompanionInMemoryConnection) async throws {
        let envelope = CompanionEnvelope(id: UUID().uuidString, message: message)
        try await connection.send(try encoder.encode(envelope))
    }

    private func receiveEnvelope(over connection: CompanionInMemoryConnection) async throws -> CompanionEnvelope {
        guard let data = try await connection.receive() else {
            throw CompanionTransportError.closed
        }
        return try decoder.decode(CompanionEnvelope.self, from: data)
    }

    /// Runs the mac side of the crypto handshake against a fresh session and
    /// returns a phone-side driver holding the established session crypto. The
    /// session is registered with the server (so it lands in `activeSessions`),
    /// mirroring the production accept path.
    private func openEncryptedSession(
        phone: PhoneIdentity,
        server: CompanionBridgeServer? = nil
    ) async throws -> PhoneSessionDriver {
        let usedServer = server ?? self.server!
        let (phoneConn, serverConn) = CompanionInMemoryConnection.makePair()
        let session = CompanionSession(connection: serverConn, services: usedServer)
        let runTask = usedServer.trackSession(session)

        let phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()

        // frame 1: phone hello (device id + ephemeral)
        let hello = CompanionCryptoHandshakeFrame(
            deviceId: phone.deviceId,
            ephemeralPublicKey: CompanionBase64URL.encode(phoneEphemeral.publicKey.rawRepresentation)
        )
        try await phoneConn.send(try encoder.encode(hello))

        // frame 2: mac hello (device id + ephemeral + signature)
        guard let macHelloData = try await phoneConn.receive() else {
            throw CompanionTransportError.closed
        }
        let macHello = try decoder.decode(CompanionCryptoHandshakeFrame.self, from: macHelloData)
        let macEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(CompanionBase64URL.decode(try XCTUnwrap(macHello.ephemeralPublicKey)))
        )
        let macIdentityKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try XCTUnwrap(CompanionBase64URL.decode(try XCTUnwrap(macHello.deviceId)))
        )
        let macSignature = try XCTUnwrap(CompanionBase64URL.decode(try XCTUnwrap(macHello.signature)))

        // frame 3: phone signature
        let phoneSignature = try CompanionHandshake.localSignature(
            role: .phone,
            localIdentity: phone.signingKey,
            localEphemeralPublicKey: phoneEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: macIdentityKey.rawRepresentation,
            peerEphemeralPublicKey: macEphemeral.rawRepresentation
        )
        try await phoneConn.send(try encoder.encode(
            CompanionCryptoHandshakeFrame(signature: CompanionBase64URL.encode(phoneSignature))
        ))

        let crypto = try CompanionHandshake.establish(
            role: .phone,
            localIdentity: phone.signingKey,
            localEphemeral: phoneEphemeral,
            peerIdentityPublicKey: macIdentityKey,
            peerEphemeralPublicKey: macEphemeral,
            peerSignature: macSignature
        )

        return PhoneSessionDriver(
            connection: phoneConn,
            crypto: crypto,
            encoder: encoder,
            decoder: decoder,
            runTask: runTask
        )
    }
}

// MARK: - Phone-side helpers

/// A phone device identity for driving the mac bridge in tests. `deviceId` is
/// base64url of the Ed25519 public key, matching the wire spelling used for both
/// `deviceId` and `publicKey`.
private struct PhoneIdentity {
    let signingKey = Curve25519.Signing.PrivateKey()

    var deviceId: String {
        CompanionBase64URL.encode(signingKey.publicKey.rawRepresentation)
    }

    /// `HMAC-SHA256(secret, rawPublicKey)` in base64url, as the mac verifies.
    func pairingProof(secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: signingKey.publicKey.rawRepresentation,
            using: SymmetricKey(data: secret)
        )
        return CompanionBase64URL.encode(Data(mac))
    }
}

/// Wraps a phone-side established session so tests can send/receive sealed
/// envelopes as if they were the mobile app. `@MainActor` so its non-`Sendable`
/// session crypto stays on one actor alongside the bridge under test.
@MainActor
private struct PhoneSessionDriver {
    let connection: CompanionInMemoryConnection
    let crypto: CompanionSessionCrypto
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let runTask: Task<Void, Never>

    func send(_ message: CompanionMessage) async throws {
        let envelope = CompanionEnvelope(id: UUID().uuidString, message: message)
        let sealed = try crypto.seal(try encoder.encode(envelope))
        try await connection.send(sealed)
    }

    func receive() async throws -> CompanionEnvelope {
        guard let data = try await connection.receive() else {
            throw CompanionTransportError.closed
        }
        let plaintext = try crypto.open(data)
        return try decoder.decode(CompanionEnvelope.self, from: plaintext)
    }

    func close() {
        connection.close()
    }
}
