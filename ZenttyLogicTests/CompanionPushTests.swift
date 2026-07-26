import CryptoKit
import XCTest

@testable import Zentty

/// Mac-side push pipeline: the gateway signing contract (byte-for-byte with the
/// wire), the per-pairing seal (pinned to libsodium via PyNaCl vectors so the
/// mobile NSE can decrypt), the signed gateway client (offline transport seam),
/// and the attention fan-out gating.
@MainActor
final class CompanionPushTests: XCTestCase {
    // MARK: - Test doubles

    private final class InMemoryKeychain: CompanionKeychainStoring {
        private var storage: [String: Data] = [:]
        func read(account: String) throws -> Data? { storage[account] }
        func store(_ data: Data, account: String) throws { storage[account] = data }
        func delete(account: String) throws { storage[account] = nil }
    }

    /// Records every gateway POST and lets a test await the fire-and-forget wake.
    private final class RecordingTransport: CompanionPushHTTPTransport, @unchecked Sendable {
        struct Call { let url: URL; let body: Data }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var onPost: (@Sendable () -> Void)?
        var status = 202

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        /// Synchronous record step so `NSLock` is never touched from the async
        /// `post` context (locking is unavailable there under strict concurrency).
        private func record(_ call: Call) -> (@Sendable () -> Void)? {
            lock.lock(); defer { lock.unlock() }
            _calls.append(call)
            return onPost
        }

        func post(url: URL, body: Data) async throws -> Int {
            let callback = record(Call(url: url, body: body))
            callback?()
            return status
        }
    }

    // MARK: - Fixtures

    private static func hex(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private static func identity(seedHex: String) -> CompanionDeviceIdentity {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: hex(seedHex))
        return CompanionDeviceIdentity(signingPrivateKey: key, isPersistent: true)
    }

    // Ed25519 → Curve25519 conversion vectors from PyNaCl (libsodium):
    // crypto_sign_ed25519_pk_to_curve25519 / crypto_sign_ed25519_sk_to_curve25519.
    private struct ConversionVector {
        let seedHex: String
        let edPubHex: String
        let curvePubHex: String
        let curvePrivHex: String
    }

    private static let conversionVectors: [ConversionVector] = [
        ConversionVector(
            seedHex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            edPubHex: "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8",
            curvePubHex: "4701d08488451f545a409fb58ae3e58581ca40ac3f7f114698cd71deac73ca01",
            curvePrivHex: "3894eea49c580aef816935762be049559d6d1440dede12e6a125f1841fff8e6f"
        ),
        ConversionVector(
            seedHex: "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc",
            edPubHex: "755c4cb9256ca7cdc4acfdc6cfeeda849017e5b9f9514e99191bd67e0b0d4276",
            curvePubHex: "be2b8b75b369b8f459b8b153799bc5ab07a2f8feba04c11cc843d19fe55ae25c",
            curvePrivHex: "c0902ef600c188f0a9b0d32d5e78edf886d61887e698a81aab084c8f86dbfe6f"
        ),
        ConversionVector(
            seedHex: "056acf3499fe63c82d92f75cc1268bf055ba1f84e94eb3187de247ac1176db40",
            edPubHex: "13c1d03f8b954c931ff0f483522ed13c7cb8297fc8253ab986093e3c21831a5d",
            curvePubHex: "2d9f75bdf18f5ce48ade37de11a1d7705af1616b186f8ed50cf155fc78566212",
            curvePrivHex: "506a8ba1a795c74f89c6d7c0ddf9c435eb789c13a0b4b21e9ab2d60dd21a8a4e"
        ),
    ]

    // Full pairing seal vector (mac seals to phone), HKDF salt "zentty-push/v1",
    // info "zentty-push", from PyNaCl.
    private static let macSeedHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private static let phoneSeedHex = "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc"
    private static let sharedHex = "9693675991b52216d9ee815a1a4680764df25e5581c1190f2efaa94033ba3e67"
    private static let sealKeyHex = "5d4fd92294d48b7521ae8011a9ba7930ff587bc7d9ba7616a4b9435522bf762c"

    // MARK: - Ed25519 → Curve25519 conversion (libsodium parity)

    func testMontgomeryPublicKeyMatchesLibsodiumVectors() {
        for vector in Self.conversionVectors {
            let edPub = Self.hex(vector.edPubHex)
            let curvePub = Curve25519MontgomeryMap.montgomeryPublicKey(fromEd25519PublicKey: edPub)
            XCTAssertEqual(
                curvePub?.map { String(format: "%02x", $0) }.joined(),
                vector.curvePubHex,
                "pk_to_curve25519 mismatch for \(vector.edPubHex)"
            )
        }
    }

    func testCurveAgreementPrivateKeyMatchesLibsodiumVectors() {
        for vector in Self.conversionVectors {
            let identity = try! Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(vector.seedHex))
            // Sanity: the seed maps to the expected Ed25519 public key.
            XCTAssertEqual(
                identity.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                vector.edPubHex
            )
            let curvePriv = CompanionPushSeal.curveAgreementPrivateKey(fromEd25519: identity)
            XCTAssertEqual(
                curvePriv.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                vector.curvePrivHex,
                "sk_to_curve25519 mismatch for \(vector.seedHex)"
            )
        }
    }

    // MARK: - Seal key + round trip

    func testSealKeyMatchesLibsodiumAndIsSymmetric() throws {
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let phone = Self.identity(seedHex: Self.phoneSeedHex)

        // Mac seals to phone: sealKey(macPriv, phonePub) == the PyNaCl vector.
        let macSideKey = try CompanionPushSeal.sealKey(
            macIdentity: mac.signingPrivateKey,
            phoneIdentityPublicKey: phone.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(
            macSideKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined(),
            Self.sealKeyHex
        )

        // Phone derives the identical key from its own private + the mac's public
        // (ECDH is symmetric) — this is what the NSE computes.
        let phoneSideKey = try CompanionPushSeal.sealKey(
            macIdentity: phone.signingPrivateKey,
            phoneIdentityPublicKey: mac.signingPublicKey.rawRepresentation
        )
        XCTAssertEqual(
            phoneSideKey.withUnsafeBytes { Data($0) },
            macSideKey.withUnsafeBytes { Data($0) }
        )
    }

    func testSealRoundTripsThroughDerivedKey() throws {
        // Model "mobile can open": seal on the Mac, open with the phone-derived key.
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let phone = Self.identity(seedHex: Self.phoneSeedHex)

        let content = CompanionPushSeal.Content(
            title: "Claude Code needs approval",
            body: "zentty • run tests?",
            paneId: "pane-1",
            worklaneId: "wl-1"
        )
        let sealedBase64 = try CompanionPushSeal.sealedPayload(
            content: content,
            macIdentity: mac.signingPrivateKey,
            phoneIdentityPublicKey: phone.signingPublicKey.rawRepresentation
        )

        let phoneKey = try CompanionPushSeal.sealKey(
            macIdentity: phone.signingPrivateKey,
            phoneIdentityPublicKey: mac.signingPublicKey.rawRepresentation
        )
        let opened = try CompanionPushSeal.open(Data(base64Encoded: sealedBase64)!, key: phoneKey)
        let decoded = try JSONDecoder().decode(CompanionPushSeal.Content.self, from: opened)
        XCTAssertEqual(decoded, content)
    }

    // MARK: - Signing string (byte-for-byte with the wire)

    func testWakeSigningStringMatchesWireContract() throws {
        let deviceId = "phone-device-id"
        let token = "apns-token-xyz"
        let sealed = "c2VhbGVkLXBheWxvYWQ="
        let expected = [
            "zentty-push-wake:v1",
            "deviceId=\(deviceId)",
            "platform=apns",
            "sealedPayload=\(sealed)",
            "token=\(token)",
        ].joined(separator: "\n")

        let built = CompanionPushSigning.wakeSigningString(
            deviceId: deviceId,
            platform: "apns",
            sealedPayload: sealed,
            token: token
        )
        XCTAssertEqual(built, expected)

        // The signature verifies with CryptoKit against the mac identity key.
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let signature = try mac.signingPrivateKey.signature(for: Data(built.utf8))
        XCTAssertTrue(mac.signingPublicKey.isValidSignature(signature, for: Data(built.utf8)))
    }

    func testRegisterSigningStringMatchesWireContract() {
        let expected = [
            "zentty-push-register:v1",
            "macDeviceId=mac-id",
            "phoneDeviceId=phone-id",
            "platform=fcm",
            "token=fcm-token",
        ].joined(separator: "\n")
        let built = CompanionPushSigning.registerSigningString(
            macDeviceId: "mac-id",
            phoneDeviceId: "phone-id",
            platform: "fcm",
            token: "fcm-token"
        )
        XCTAssertEqual(built, expected)
    }

    // MARK: - Gateway client request shape

    func testGatewayClientBuildsSignedWakeRequest() throws {
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let client = CompanionPushGatewayClient(
            baseURL: URL(string: "https://push.example.com")!,
            identity: mac,
            transport: RecordingTransport()
        )

        let request = try client.makeWakeRequest(
            phoneDeviceId: "phone-id",
            platform: .apns,
            token: "tok",
            sealedPayload: "c2VhbA=="
        )
        XCTAssertEqual(request.url, URL(string: "https://push.example.com/wake"))

        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(body["deviceId"], "phone-id")
        XCTAssertEqual(body["platform"], "apns")
        XCTAssertEqual(body["token"], "tok")
        XCTAssertEqual(body["sealedPayload"], "c2VhbA==")

        // The sig verifies over the canonical signing string with the mac key.
        let signingString = CompanionPushSigning.wakeSigningString(
            deviceId: "phone-id", platform: "apns", sealedPayload: "c2VhbA==", token: "tok"
        )
        let sig = try XCTUnwrap(CompanionBase64URL.decode(try XCTUnwrap(body["sig"])))
        XCTAssertTrue(mac.signingPublicKey.isValidSignature(sig, for: Data(signingString.utf8)))
    }

    // MARK: - Fan-out gating

    private func makePairingStore() throws -> (CompanionPairingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (CompanionPairingStore(configDirectoryURL: dir), dir)
    }

    private func addPhone(
        to store: CompanionPairingStore,
        phone: CompanionDeviceIdentity,
        withToken: Bool
    ) throws {
        try store.add(
            CompanionPairedDevice(
                deviceId: phone.deviceId,
                publicKey: phone.deviceId,
                name: "iPhone",
                pairedAt: Date(),
                lastSeenAt: Date()
            )
        )
        if withToken {
            try store.setPushRegistration(deviceId: phone.deviceId, platform: .apns, token: "apns-token")
        }
    }

    func testFanOutSendsOneWakePerRegisteredPairing() throws {
        let (store, dir) = try makePairingStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let phone = Self.identity(seedHex: Self.phoneSeedHex)
        try addPhone(to: store, phone: phone, withToken: true)

        let transport = RecordingTransport()
        let posted = expectation(description: "wake posted")
        transport.onPost = { posted.fulfill() }

        let coordinator = CompanionPushCoordinator(
            identity: mac,
            pairingStore: store,
            isFeatureEnabled: { true },
            gatewayURLProvider: { "https://push.example.com" },
            transport: transport
        )
        coordinator.fanOutAttention(
            CompanionAttentionPush(title: "t", body: "b", paneId: "pane-1", worklaneId: "wl-1")
        )

        wait(for: [posted], timeout: 2)
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls.first?.url, URL(string: "https://push.example.com/wake"))
    }

    func testFanOutIsNoOpWhenDisabledOrUnregisteredOrNoURL() throws {
        let (store, dir) = try makePairingStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let phone = Self.identity(seedHex: Self.phoneSeedHex)

        let attention = CompanionAttentionPush(title: "t", body: "b", paneId: "p", worklaneId: "w")

        // Disabled feature → no client, no post.
        let disabledTransport = RecordingTransport()
        try addPhone(to: store, phone: phone, withToken: true)
        CompanionPushCoordinator(
            identity: mac, pairingStore: store,
            isFeatureEnabled: { false },
            gatewayURLProvider: { "https://push.example.com" },
            transport: disabledTransport
        ).fanOutAttention(attention)

        // No gateway URL → no post.
        let noURLTransport = RecordingTransport()
        CompanionPushCoordinator(
            identity: mac, pairingStore: store,
            isFeatureEnabled: { true },
            gatewayURLProvider: { "" },
            transport: noURLTransport
        ).fanOutAttention(attention)

        // Enabled + URL but no registered token → no post.
        let (store2, dir2) = try makePairingStore()
        defer { try? FileManager.default.removeItem(at: dir2) }
        try addPhone(to: store2, phone: phone, withToken: false)
        let noTokenTransport = RecordingTransport()
        CompanionPushCoordinator(
            identity: mac, pairingStore: store2,
            isFeatureEnabled: { true },
            gatewayURLProvider: { "https://push.example.com" },
            transport: noTokenTransport
        ).fanOutAttention(attention)

        // Let any (erroneously) spawned task run before asserting emptiness.
        let settled = expectation(description: "settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(disabledTransport.calls.isEmpty)
        XCTAssertTrue(noURLTransport.calls.isEmpty)
        XCTAssertTrue(noTokenTransport.calls.isEmpty)
    }

    // MARK: - push.register routing

    func testRegisterPushPersistsTokenAndForwardsToGateway() throws {
        let (store, dir) = try makePairingStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = Self.identity(seedHex: Self.macSeedHex)
        let phone = Self.identity(seedHex: Self.phoneSeedHex)
        try addPhone(to: store, phone: phone, withToken: false)

        let transport = RecordingTransport()
        let posted = expectation(description: "register posted")
        transport.onPost = { posted.fulfill() }

        let coordinator = CompanionPushCoordinator(
            identity: mac,
            pairingStore: store,
            isFeatureEnabled: { true },
            gatewayURLProvider: { "https://push.example.com" },
            transport: transport
        )
        coordinator.registerPush(phoneDeviceId: phone.deviceId, platform: .apns, token: "apns-token")

        // Token persisted on the pairing immediately.
        XCTAssertEqual(store.device(withId: phone.deviceId)?.pushToken, "apns-token")
        XCTAssertEqual(store.device(withId: phone.deviceId)?.pushPlatform, .apns)

        wait(for: [posted], timeout: 2)
        XCTAssertEqual(transport.calls.first?.url, URL(string: "https://push.example.com/register"))
    }

    // MARK: - Attention coordinator fan-out (debounced, once per transition)

    func testAttentionCoordinatorFiresSinkOncePerTransition() {
        final class SpySink: @unchecked Sendable {
            var pushes: [CompanionAttentionPush] = []
        }
        let spy = SpySink()
        let notificationStore = NotificationStore()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: nil,
            notificationStore: notificationStore,
            configStore: nil,
            needsInputSystemNotificationDelay: 0,
            attentionPushSink: { push in spy.pushes.append(push) }
        )

        let windowID = WindowID("wd-1")
        let worklane = Self.needsInputWorklane()

        // First update crosses idle → needsInput: exactly one push.
        coordinator.update(windowID: windowID, worklanes: [worklane], activeWorklaneID: worklane.id, windowIsKey: false)
        XCTAssertEqual(spy.pushes.count, 1)
        XCTAssertEqual(spy.pushes.first?.paneId, "pane-1")
        XCTAssertEqual(spy.pushes.first?.worklaneId, worklane.id.rawValue)

        // Re-delivering the same state does not re-fire (coalesced identically to
        // the local notification path).
        coordinator.update(windowID: windowID, worklanes: [worklane], activeWorklaneID: worklane.id, windowIsKey: false)
        XCTAssertEqual(spy.pushes.count, 1)
    }

    private static func needsInputWorklane() -> WorklaneState {
        let paneID = PaneID("pane-1")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Claude Code",
            contextText: "main · /tmp/project",
            rememberedTitle: "Claude Code",
            recognizedTool: .claudeCode,
            runtimePhase: .needsInput,
            statusText: "Needs approval",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false,
            interactionKind: .approval,
            interactionLabel: "Needs approval",
            interactionSymbolName: "hand.raised"
        )
        return WorklaneState(
            id: WorklaneID("wl-1"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )
    }
}
