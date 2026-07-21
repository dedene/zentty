import CryptoKit
import Foundation

// MARK: - Push payload sealing
//
// A push wake carries an E2E-encrypted `sealedPayload` the gateway (and APNs/FCM)
// forward opaquely; only the paired phone's Notification Service Extension can open
// it, using key material it already holds from pairing — no live session required.
//
// Scheme ("zentty-push/v1"), mirrored by the mobile NSE with react-native-libsodium:
//
//   1. Static-static X25519 shared secret between the two device *identities*:
//        macCurveSK   = crypto_sign_ed25519_sk_to_curve25519(macEd25519Priv)
//        phoneCurvePK = crypto_sign_ed25519_pk_to_curve25519(phoneEd25519Pub)
//        shared       = X25519(macCurveSK, phoneCurvePK)
//      The phone derives the identical secret from its own converted private key
//      and the Mac's converted public key (ECDH is symmetric). Both identities are
//      the long-term Ed25519 keys pinned at pairing, so the NSE needs no session.
//
//   2. Seal key = HKDF-SHA256(ikm: shared, salt: "zentty-push/v1", info: "zentty-push", L: 32).
//
//   3. Seal = ChaCha20-Poly1305-IETF(seal key, random 12-byte nonce, plaintext),
//      serialized as nonce(12) || ciphertext || tag(16), then Base64 (standard).
//      This is CryptoKit's `ChaChaPoly.SealedBox.combined`; the NSE splits the
//      first 12 bytes as the nonce and feeds `ciphertext || tag` to libsodium's
//      `crypto_aead_chacha20poly1305_ietf_decrypt`.
//
// The plaintext is the JSON `{title, body, paneId, worklaneId}` (sorted keys).
enum CompanionPushSeal {
    /// HKDF salt/info — fixed, non-empty, and versioned so the mobile side has no
    /// empty-salt ambiguity to resolve.
    static let hkdfSalt = Data("zentty-push/v1".utf8)
    static let hkdfInfo = Data("zentty-push".utf8)

    enum SealError: Error, Equatable {
        /// The peer's stored Ed25519 public key could not be converted to X25519.
        case invalidPeerKey
    }

    // MARK: - Key derivation

    /// The X25519 agreement private key for an Ed25519 signing identity, matching
    /// libsodium's `crypto_sign_ed25519_sk_to_curve25519`: SHA-512 of the 32-byte
    /// Ed25519 seed, first 32 bytes, clamped to a valid Curve25519 scalar.
    static func curveAgreementPrivateKey(
        fromEd25519 identity: Curve25519.Signing.PrivateKey
    ) -> Curve25519.KeyAgreement.PrivateKey {
        var scalar = [UInt8](SHA512.hash(data: identity.rawRepresentation).prefix(32))
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        // A clamped scalar is always a valid X25519 raw key; force-try is safe.
        // swiftlint:disable:next force_try
        return try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(scalar))
    }

    /// The seal key for a pairing, derived from this Mac's identity private key and
    /// the paired phone's Ed25519 identity public key.
    static func sealKey(
        macIdentity: Curve25519.Signing.PrivateKey,
        phoneIdentityPublicKey: Data
    ) throws -> SymmetricKey {
        guard
            let phoneCurvePub = Curve25519MontgomeryMap
                .montgomeryPublicKey(fromEd25519PublicKey: phoneIdentityPublicKey),
            let peerAgreementKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phoneCurvePub)
        else {
            throw SealError.invalidPeerKey
        }
        let macCurvePriv = curveAgreementPrivateKey(fromEd25519: macIdentity)
        let shared = try macCurvePriv.sharedSecretFromKeyAgreement(with: peerAgreementKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }

    // MARK: - Seal / open

    /// Seals `plaintext` under `key`, returning `nonce(12) || ciphertext || tag(16)`.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return box.combined
    }

    /// Opens a `nonce || ciphertext || tag` blob produced by `seal`. Modeled in
    /// tests to prove the mobile NSE can decrypt with the same derived key.
    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        return try ChaChaPoly.open(box, using: key)
    }

    // MARK: - Notification content

    /// The decrypted push content the phone renders (and re-seals from on the Mac).
    struct Content: Codable, Equatable, Sendable {
        var title: String
        var body: String
        var paneId: String
        var worklaneId: String
    }

    /// Seals a notification `content` to a paired phone, returning the Base64
    /// `sealedPayload` for the `/wake` request body.
    static func sealedPayload(
        content: Content,
        macIdentity: Curve25519.Signing.PrivateKey,
        phoneIdentityPublicKey: Data
    ) throws -> String {
        let key = try sealKey(macIdentity: macIdentity, phoneIdentityPublicKey: phoneIdentityPublicKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try seal(try encoder.encode(content), key: key)
        return sealed.base64EncodedString()
    }
}
