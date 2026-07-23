import CryptoKit
import Foundation

// MARK: - Errors

enum CompanionCryptoError: Error, Equatable {
    /// The peer's handshake signature did not verify against its pinned identity.
    case invalidHandshakeSignature
    /// A received frame's counter was not strictly greater than the last accepted
    /// one (replay or reorder).
    case replayDetected
    /// A sealed frame was too short to contain a counter and an authentication tag.
    case malformedSealedFrame
    /// The 2^64 send-counter space is exhausted; the session must be re-keyed.
    case sendCounterExhausted
}

// MARK: - Role

/// Which end of the session this endpoint is. Determines which directional key it
/// seals with and which it opens with.
enum CompanionEndpointRole: Sendable {
    case mac
    case phone
}

// MARK: - Handshake

/// Establishes a `CompanionSessionCrypto` from an X25519 ECDH exchange, binding
/// the derived keys to the full handshake transcript and to both sides' Ed25519
/// identities.
///
/// Wire contract (must match the phone side, react-native-libsodium):
/// - Shared secret: X25519 ECDH over the per-session ephemeral keys.
/// - Directional keys: `HKDF-SHA256(ikm: sharedSecret, salt: transcript, info: <dir>)`,
///   32 bytes each, where `<dir>` is `macToPhoneInfo` / `phoneToMacInfo`.
/// - Transcript (also the HKDF salt): `handshakeLabel` UTF-8 bytes followed by the
///   raw 32-byte public keys in fixed order — mac identity, phone identity, mac
///   ephemeral, phone ephemeral.
/// - Each side signs the transcript with its Ed25519 identity key; the peer
///   verifies with the identity it pinned at pairing.
enum CompanionHandshake {
    static let handshakeLabel = "zentty-companion/v1/handshake"
    static let macToPhoneInfo = "zentty-companion/v1/mac->phone"
    static let phoneToMacInfo = "zentty-companion/v1/phone->mac"

    /// 4-byte nonce domain separators (`"m>p\0"` / `"p>m\0"`).
    static let macToPhoneSalt = Data([0x6D, 0x3E, 0x70, 0x00])
    static let phoneToMacSalt = Data([0x70, 0x3E, 0x6D, 0x00])

    /// Signature this endpoint contributes to the handshake. The peer feeds the
    /// result to `establish(peerSignature:)`.
    static func localSignature(
        role: CompanionEndpointRole,
        localIdentity: Curve25519.Signing.PrivateKey,
        localEphemeralPublicKey: Data,
        peerIdentityPublicKey: Data,
        peerEphemeralPublicKey: Data
    ) throws -> Data {
        let transcript = transcript(
            role: role,
            localIdentityPublicKey: localIdentity.publicKey.rawRepresentation,
            localEphemeralPublicKey: localEphemeralPublicKey,
            peerIdentityPublicKey: peerIdentityPublicKey,
            peerEphemeralPublicKey: peerEphemeralPublicKey
        )
        return try localIdentity.signature(for: transcript)
    }

    /// Verifies the peer's transcript signature, runs ECDH, derives the two
    /// directional keys, and returns a ready session bound to this `role`.
    static func establish(
        role: CompanionEndpointRole,
        localIdentity: Curve25519.Signing.PrivateKey,
        localEphemeral: Curve25519.KeyAgreement.PrivateKey,
        peerIdentityPublicKey: Curve25519.Signing.PublicKey,
        peerEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey,
        peerSignature: Data
    ) throws -> CompanionSessionCrypto {
        let transcript = transcript(
            role: role,
            localIdentityPublicKey: localIdentity.publicKey.rawRepresentation,
            localEphemeralPublicKey: localEphemeral.publicKey.rawRepresentation,
            peerIdentityPublicKey: peerIdentityPublicKey.rawRepresentation,
            peerEphemeralPublicKey: peerEphemeralPublicKey.rawRepresentation
        )

        guard peerIdentityPublicKey.isValidSignature(peerSignature, for: transcript) else {
            throw CompanionCryptoError.invalidHandshakeSignature
        }

        let sharedSecret = try localEphemeral.sharedSecretFromKeyAgreement(with: peerEphemeralPublicKey)
        let macToPhoneKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(macToPhoneInfo.utf8),
            outputByteCount: 32
        )
        let phoneToMacKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(phoneToMacInfo.utf8),
            outputByteCount: 32
        )

        switch role {
        case .mac:
            return CompanionSessionCrypto(
                sendKey: macToPhoneKey, sendSalt: macToPhoneSalt,
                receiveKey: phoneToMacKey, receiveSalt: phoneToMacSalt
            )
        case .phone:
            return CompanionSessionCrypto(
                sendKey: phoneToMacKey, sendSalt: phoneToMacSalt,
                receiveKey: macToPhoneKey, receiveSalt: macToPhoneSalt
            )
        }
    }

    /// Builds the canonical, role-independent transcript. Both endpoints produce
    /// identical bytes: the label followed by mac identity, phone identity, mac
    /// ephemeral, phone ephemeral (each a raw 32-byte key).
    private static func transcript(
        role: CompanionEndpointRole,
        localIdentityPublicKey: Data,
        localEphemeralPublicKey: Data,
        peerIdentityPublicKey: Data,
        peerEphemeralPublicKey: Data
    ) -> Data {
        let macIdentity: Data
        let phoneIdentity: Data
        let macEphemeral: Data
        let phoneEphemeral: Data
        switch role {
        case .mac:
            macIdentity = localIdentityPublicKey
            macEphemeral = localEphemeralPublicKey
            phoneIdentity = peerIdentityPublicKey
            phoneEphemeral = peerEphemeralPublicKey
        case .phone:
            phoneIdentity = localIdentityPublicKey
            phoneEphemeral = localEphemeralPublicKey
            macIdentity = peerIdentityPublicKey
            macEphemeral = peerEphemeralPublicKey
        }

        var data = Data(handshakeLabel.utf8)
        data.append(macIdentity)
        data.append(phoneIdentity)
        data.append(macEphemeral)
        data.append(phoneEphemeral)
        return data
    }
}

// MARK: - Session crypto

/// A directional AEAD channel established by `CompanionHandshake`. Seals outbound
/// frames with a monotonic send counter and opens inbound frames, rejecting any
/// whose counter does not advance (replay / reorder).
///
/// Sealed frame layout: `counter (8 bytes, big-endian) || ciphertext || tag (16)`.
/// The 12-byte ChaCha20-Poly1305-IETF nonce is the 4-byte directional salt
/// followed by the same big-endian counter — never transmitted whole.
final class CompanionSessionCrypto {
    private let sendKey: SymmetricKey
    private let sendSalt: Data
    private let receiveKey: SymmetricKey
    private let receiveSalt: Data

    private var sendCounter: UInt64 = 0
    private var lastReceivedCounter: UInt64?

    init(sendKey: SymmetricKey, sendSalt: Data, receiveKey: SymmetricKey, receiveSalt: Data) {
        self.sendKey = sendKey
        self.sendSalt = sendSalt
        self.receiveKey = receiveKey
        self.receiveSalt = receiveSalt
    }

    /// Seals `plaintext` and advances the send counter.
    func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter != UInt64.max else {
            throw CompanionCryptoError.sendCounterExhausted
        }
        let counter = sendCounter
        let nonce = try Self.nonce(salt: sendSalt, counter: counter)
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        sendCounter += 1

        var out = Data(capacity: 8 + box.ciphertext.count + box.tag.count)
        out.append(Self.bigEndianBytes(counter))
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Opens a sealed frame. Throws `replayDetected` if the frame's counter does
    /// not strictly exceed the last successfully opened one; the high-water mark
    /// advances only on successful authentication.
    func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 8 + 16 else {
            throw CompanionCryptoError.malformedSealedFrame
        }
        let counter = Self.readBigEndian(sealed.prefix(8))
        if let last = lastReceivedCounter, counter <= last {
            throw CompanionCryptoError.replayDetected
        }

        let body = sealed.dropFirst(8)
        let tag = body.suffix(16)
        let ciphertext = body.dropLast(16)
        let nonce = try Self.nonce(salt: receiveSalt, counter: counter)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try ChaChaPoly.open(box, using: receiveKey)

        lastReceivedCounter = counter
        return plaintext
    }

    private static func nonce(salt: Data, counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = salt
        bytes.append(bigEndianBytes(counter))
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private static func bigEndianBytes(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func readBigEndian(_ data: some Sequence<UInt8>) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
