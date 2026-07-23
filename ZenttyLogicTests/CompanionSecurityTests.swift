import CryptoKit
import XCTest

@testable import Zentty

final class CompanionSecurityTests: XCTestCase {
    // MARK: - Test doubles

    private final class InMemoryKeychain: CompanionKeychainStoring {
        private var storage: [String: Data] = [:]
        func read(account: String) throws -> Data? { storage[account] }
        func store(_ data: Data, account: String) throws { storage[account] = data }
        func delete(account: String) throws { storage[account] = nil }
    }

    private struct FailingKeychain: CompanionKeychainStoring {
        struct Boom: Error {}
        func read(account: String) throws -> Data? { throw Boom() }
        func store(_ data: Data, account: String) throws { throw Boom() }
        func delete(account: String) throws { throw Boom() }
    }

    /// A pair of established sessions plus the identities behind them.
    private struct HandshakePair {
        let macIdentity: Curve25519.Signing.PrivateKey
        let phoneIdentity: Curve25519.Signing.PrivateKey
        let macSession: CompanionSessionCrypto
        let phoneSession: CompanionSessionCrypto
    }

    private func makeHandshake() throws -> HandshakePair {
        let macIdentity = Curve25519.Signing.PrivateKey()
        let phoneIdentity = Curve25519.Signing.PrivateKey()
        let macEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let macSignature = try CompanionHandshake.localSignature(
            role: .mac,
            localIdentity: macIdentity,
            localEphemeralPublicKey: macEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: phoneIdentity.publicKey.rawRepresentation,
            peerEphemeralPublicKey: phoneEphemeral.publicKey.rawRepresentation
        )
        let phoneSignature = try CompanionHandshake.localSignature(
            role: .phone,
            localIdentity: phoneIdentity,
            localEphemeralPublicKey: phoneEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: macIdentity.publicKey.rawRepresentation,
            peerEphemeralPublicKey: macEphemeral.publicKey.rawRepresentation
        )

        let macSession = try CompanionHandshake.establish(
            role: .mac,
            localIdentity: macIdentity,
            localEphemeral: macEphemeral,
            peerIdentityPublicKey: phoneIdentity.publicKey,
            peerEphemeralPublicKey: phoneEphemeral.publicKey,
            peerSignature: phoneSignature
        )
        let phoneSession = try CompanionHandshake.establish(
            role: .phone,
            localIdentity: phoneIdentity,
            localEphemeral: phoneEphemeral,
            peerIdentityPublicKey: macIdentity.publicKey,
            peerEphemeralPublicKey: macEphemeral.publicKey,
            peerSignature: macSignature
        )
        return HandshakePair(
            macIdentity: macIdentity,
            phoneIdentity: phoneIdentity,
            macSession: macSession,
            phoneSession: phoneSession
        )
    }

    // MARK: - Handshake + AEAD

    func testHandshakeSealOpenBothDirections() throws {
        let pair = try makeHandshake()

        let toPhone = Data("hello from mac".utf8)
        XCTAssertEqual(try pair.phoneSession.open(pair.macSession.seal(toPhone)), toPhone)

        let toMac = Data("hello from phone".utf8)
        XCTAssertEqual(try pair.macSession.open(pair.phoneSession.seal(toMac)), toMac)

        // Counters advance independently per direction.
        for i in 0..<5 {
            let payload = Data("mac message \(i)".utf8)
            XCTAssertEqual(try pair.phoneSession.open(pair.macSession.seal(payload)), payload)
        }
    }

    func testTamperedSignatureRejected() throws {
        let macIdentity = Curve25519.Signing.PrivateKey()
        let phoneIdentity = Curve25519.Signing.PrivateKey()
        let attackerIdentity = Curve25519.Signing.PrivateKey()
        let macEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()

        // Phone signs with the wrong (attacker) identity key.
        let forgedSignature = try CompanionHandshake.localSignature(
            role: .phone,
            localIdentity: attackerIdentity,
            localEphemeralPublicKey: phoneEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: macIdentity.publicKey.rawRepresentation,
            peerEphemeralPublicKey: macEphemeral.publicKey.rawRepresentation
        )

        XCTAssertThrowsError(
            try CompanionHandshake.establish(
                role: .mac,
                localIdentity: macIdentity,
                localEphemeral: macEphemeral,
                peerIdentityPublicKey: phoneIdentity.publicKey,
                peerEphemeralPublicKey: phoneEphemeral.publicKey,
                peerSignature: forgedSignature
            )
        ) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .invalidHandshakeSignature)
        }
    }

    // MARK: - Replay

    func testReplayRejected() throws {
        let pair = try makeHandshake()
        let sealed = try pair.macSession.seal(Data("once".utf8))

        XCTAssertEqual(try pair.phoneSession.open(sealed), Data("once".utf8))
        XCTAssertThrowsError(try pair.phoneSession.open(sealed)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .replayDetected)
        }
    }

    func testOutOfOrderCounterRejected() throws {
        let pair = try makeHandshake()
        let first = try pair.macSession.seal(Data("first".utf8))
        let second = try pair.macSession.seal(Data("second".utf8))

        XCTAssertEqual(try pair.phoneSession.open(second), Data("second".utf8))
        // The earlier counter is now stale.
        XCTAssertThrowsError(try pair.phoneSession.open(first)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .replayDetected)
        }
    }

    // MARK: - Tamper

    func testTamperedCiphertextRejected() throws {
        let pair = try makeHandshake()
        var sealed = try pair.macSession.seal(Data("secret payload".utf8))

        // Flip a byte inside the ciphertext region (after the 8-byte counter).
        let flipIndex = 8 + ((sealed.count - 8) / 2)
        sealed[flipIndex] ^= 0xFF

        XCTAssertThrowsError(try pair.phoneSession.open(sealed))
    }

    func testMalformedFrameRejected() throws {
        let pair = try makeHandshake()
        XCTAssertThrowsError(try pair.phoneSession.open(Data([0x00, 0x01]))) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .malformedSealedFrame)
        }
    }

    // MARK: - Pairing proofs

    private func proof(secret: Data, phonePublicKey: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: phonePublicKey, using: SymmetricKey(data: secret))
        return CompanionBase64URL.encode(Data(mac))
    }

    func testValidPairingProofAcceptedOnce() throws {
        let store = makePairingStore()
        let offer = store.mintOffer()
        let phonePublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let encodedPub = CompanionBase64URL.encode(phonePublicKey)
        let goodProof = proof(secret: offer.secret, phonePublicKey: phonePublicKey)

        XCTAssertTrue(store.verifyPairingProof(phonePublicKey: encodedPub, proof: goodProof))
        // One-time: the same proof no longer matches after consumption.
        XCTAssertFalse(store.verifyPairingProof(phonePublicKey: encodedPub, proof: goodProof))
    }

    func testWrongProofRejected() throws {
        let store = makePairingStore()
        let offer = store.mintOffer()
        let phonePublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let encodedPub = CompanionBase64URL.encode(phonePublicKey)

        // Proof computed with a different secret.
        let wrongSecret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let badProof = proof(secret: wrongSecret, phonePublicKey: phonePublicKey)

        XCTAssertFalse(store.verifyPairingProof(phonePublicKey: encodedPub, proof: badProof))
        // The offer was not consumed by a bad proof; a good one still works.
        let goodProof = proof(secret: offer.secret, phonePublicKey: phonePublicKey)
        XCTAssertTrue(store.verifyPairingProof(phonePublicKey: encodedPub, proof: goodProof))
    }

    func testExpiredOfferRejected() throws {
        let store = makePairingStore()
        let now = Date()
        let offer = store.mintOffer(now: now, ttl: 120)
        let phonePublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let encodedPub = CompanionBase64URL.encode(phonePublicKey)
        let goodProof = proof(secret: offer.secret, phonePublicKey: phonePublicKey)

        let later = now.addingTimeInterval(200)
        XCTAssertFalse(store.verifyPairingProof(phonePublicKey: encodedPub, proof: goodProof, now: later))
    }

    // MARK: - Pairing store persistence

    func testPairingStoreRoundTrip() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("companion-paired-devices.json")

        let device = CompanionPairedDevice(
            deviceId: "dev-1",
            publicKey: "pub-1",
            name: "Peter's iPhone",
            pairedAt: Date(timeIntervalSince1970: 1_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_000_050)
        )

        let store = CompanionPairingStore(fileURL: fileURL)
        try store.add(device)
        XCTAssertTrue(store.contains(deviceId: "dev-1"))

        // Reload from disk into a fresh instance.
        let reloaded = CompanionPairingStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.devices().count, 1)
        XCTAssertEqual(reloaded.device(withId: "dev-1"), device)

        try reloaded.updateLastSeen(deviceId: "dev-1", at: Date(timeIntervalSince1970: 2_000_000))
        let afterSeen = CompanionPairingStore(fileURL: fileURL)
        XCTAssertEqual(
            afterSeen.device(withId: "dev-1")?.lastSeenAt,
            Date(timeIntervalSince1970: 2_000_000)
        )

        try afterSeen.remove(deviceId: "dev-1")
        let afterRemove = CompanionPairingStore(fileURL: fileURL)
        XCTAssertTrue(afterRemove.devices().isEmpty)
    }

    // MARK: - Device identity

    func testDeviceIdentityPersistsAcrossLoads() throws {
        let keychain = InMemoryKeychain()
        let first = CompanionDeviceIdentity.loadOrCreate(keychain: keychain)
        XCTAssertTrue(first.isPersistent)

        let second = CompanionDeviceIdentity.loadOrCreate(keychain: keychain)
        XCTAssertTrue(second.isPersistent)
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(
            first.signingPrivateKey.rawRepresentation,
            second.signingPrivateKey.rawRepresentation
        )
    }

    func testDeviceIdentityDegradesWhenKeychainFails() throws {
        let identity = CompanionDeviceIdentity.loadOrCreate(keychain: FailingKeychain())
        XCTAssertFalse(identity.isPersistent)
        // Still fully usable: it can sign, and deviceId is valid base64url.
        let message = Data("proof of life".utf8)
        let signature = try identity.signingPrivateKey.signature(for: message)
        XCTAssertTrue(identity.signingPublicKey.isValidSignature(signature, for: message))
        XCTAssertNotNil(CompanionBase64URL.decode(identity.deviceId))
    }

    func testBase64URLRoundTrip() {
        let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let encoded = CompanionBase64URL.encode(raw)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(CompanionBase64URL.decode(encoded), raw)
    }

    // MARK: - Helpers

    private func makePairingStore() -> CompanionPairingStore {
        // A path under a unique temp dir; no writes occur until a device is added.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-security-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return CompanionPairingStore(fileURL: dir.appendingPathComponent("devices.json"))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-security-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }
}
