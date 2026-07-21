import CryptoKit
import UserNotifications

/// Notification Service Extension: decrypts a Zentty wake payload end-to-end and
/// rewrites the notification's title/body to the real content, on-device, before
/// it is shown. The gateway only ever sends the generic fallback ("An agent needs
/// your attention"); the specific content rides along sealed in `data.zentty` and
/// is opened here so the notification banner shows what actually needs attention.
///
/// Seal scheme (must match core/pushCrypto.ts and the Mac's push seal):
///   key    = HKDF-SHA256(ikm = X25519(phonePriv, macPub), salt = "",
///                        info = "zentty-push", length = 32)
///   sealed = nonce(12) || ChaCha20-Poly1305-IETF(ciphertext) || tag(16)
///
/// The X25519 key material is supplied by the app in the shared App Group so the
/// extension never has to touch Ed25519↔X25519 conversion: the app stores the
/// phone's X25519 private scalar and each paired Mac's X25519 public key, both
/// already converted. When the material is absent (app has not populated it yet)
/// the extension safely keeps the generic fallback — the notification still shows.
final class NotificationService: UNNotificationServiceExtension {
    /// Must match the App Group id injected by the config plugin.
    private static let appGroupId = "group.be.zenjoy.zentty.mobile"
    private static let hkdfInfo = Data("zentty-push".utf8)
    private static let fallbackTitle = "Zentty"
    private static let fallbackBody = "An agent needs your attention."
    private static let nonceLength = 12

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        bestAttempt = content

        if let decrypted = Self.decrypt(userInfo: request.content.userInfo) {
            content.title = decrypted.title.isEmpty ? Self.fallbackTitle : decrypted.title
            content.body = decrypted.body.isEmpty ? Self.fallbackBody : decrypted.body
            // Carry the routing target so a tap deep-links to the pane even without
            // re-decrypting in the app.
            var data = content.userInfo["zentty"] as? [String: Any] ?? [:]
            data["paneId"] = decrypted.paneId
            content.userInfo["zentty"] = data
        } else {
            // No key material / not a Zentty wake / undecryptable: keep it generic.
            if content.title.isEmpty { content.title = Self.fallbackTitle }
            if content.body.isEmpty { content.body = Self.fallbackBody }
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // System is about to kill us: deliver whatever we have.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    // MARK: - Decryption

    private struct WakeContent {
        let paneId: String
        let title: String
        let body: String
    }

    private static func decrypt(userInfo: [AnyHashable: Any]) -> WakeContent? {
        guard
            let envelope = userInfo["zentty"] as? [String: Any],
            let macDeviceId = envelope["macDeviceId"] as? String,
            let sealedB64 = envelope["sealed"] as? String,
            let sealed = Data(base64URLEncoded: sealedB64),
            sealed.count > nonceLength + 16
        else {
            return nil
        }

        guard
            let material = KeyMaterial.load(appGroupId: appGroupId),
            let macPublicKeyRaw = material.macPublicKeys[macDeviceId],
            let phonePrivate = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: material.phonePrivateKey
            ),
            let macPublic = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: macPublicKeyRaw
            ),
            let shared = try? phonePrivate.sharedSecretFromKeyAgreement(with: macPublic)
        else {
            return nil
        }

        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        // sealed = nonce(12) || ciphertext || tag(16). Reconstruct the box from
        // its parts (the wire format is not CryptoKit's `.combined`, which is
        // nonce||ciphertext||tag but only via the 12-byte-nonce convention we use
        // here — building it explicitly keeps the framing unambiguous).
        let nonceData = Data(sealed.prefix(nonceLength))
        let rest = Data(sealed.suffix(from: sealed.startIndex + nonceLength))
        let tag = rest.suffix(16)
        let ciphertext = rest.prefix(rest.count - 16)
        guard
            let nonce = try? ChaChaPoly.Nonce(data: nonceData),
            let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
            let plaintext = try? ChaChaPoly.open(box, using: key)
        else {
            return nil
        }
        return parse(plaintext)
    }

    private static func parse(_ plaintext: Data) -> WakeContent? {
        guard
            let json = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            let paneId = json["paneId"] as? String,
            !paneId.isEmpty
        else {
            return nil
        }
        return WakeContent(
            paneId: paneId,
            title: json["title"] as? String ?? "",
            body: json["body"] as? String ?? ""
        )
    }
}

// MARK: - Shared key material

/// The X25519 material the app mirrors into the shared App Group for offline
/// unseal. All keys are raw 32-byte Curve25519 values, base64url-encoded.
private struct KeyMaterial {
    let phonePrivateKey: Data
    let macPublicKeys: [String: Data]

    static let storageKey = "zentty.push.keyMaterial"

    static func load(appGroupId: String) -> KeyMaterial? {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: storageKey),
            let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let phoneB64 = json["phoneX25519Priv"] as? String,
            let phonePriv = Data(base64URLEncoded: phoneB64),
            let macs = json["macX25519Pub"] as? [String: String]
        else {
            return nil
        }
        var publics: [String: Data] = [:]
        for (deviceId, pubB64) in macs {
            if let pub = Data(base64URLEncoded: pubB64) {
                publics[deviceId] = pub
            }
        }
        return KeyMaterial(phonePrivateKey: phonePriv, macPublicKeys: publics)
    }
}

// MARK: - base64url

private extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: s) else {
            return nil
        }
        self = data
    }
}
