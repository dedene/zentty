import CryptoKit
import Foundation
import OSLog
import Security

private let companionSecurityLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionSecurity")

// MARK: - base64url

/// URL-safe, unpadded Base64 (RFC 4648 §5). The wire spells every public key and
/// device id this way, so keep encode/decode here as the single definition the
/// rest of the companion module reuses.
enum CompanionBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }

    /// Non-empty and spelled with only unpadded base64url characters
    /// (`[A-Za-z0-9_-]`). Mirrors the `Base64Url` zod schema in
    /// `companion/wire/src/relay.ts` — the relay transport rejects a padded or
    /// empty string outright rather than accepting-then-normalizing it.
    private static let unpaddedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    static func isValidUnpadded(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { unpaddedCharacters.contains($0) }
    }
}

// MARK: - Keychain seam

/// Storage seam for small secrets. The real implementation talks to the macOS
/// Keychain; tests inject an in-memory double so `ZenttyLogicTests` (which has no
/// keychain entitlement) can exercise the identity logic without touching it.
protocol CompanionKeychainStoring {
    /// Returns the stored bytes for `account`, or `nil` if nothing is stored.
    func read(account: String) throws -> Data?
    /// Stores `data` for `account`, replacing any existing value.
    func store(_ data: Data, account: String) throws
    /// Removes any value stored for `account`. Missing is not an error.
    func delete(account: String) throws
}

enum CompanionKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain store scoped to the companion service. First
/// `SecItem*` usage in the codebase; kept deliberately small.
struct CompanionKeychainStore: CompanionKeychainStoring {
    /// Shared service string for every companion keychain item.
    static let service = "com.zenjoy.zentty.companion"

    private let service: String

    init(service: String = CompanionKeychainStore.service) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw CompanionKeychainError.unexpectedStatus(status)
        }
    }

    func store(_ data: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw CompanionKeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw CompanionKeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionKeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Device identity

/// This Mac's stable companion identity: an Ed25519 signing keypair. The private
/// key lives in the Keychain; `deviceId` is the base64url of the public key and
/// is what peers pin at pairing time.
struct CompanionDeviceIdentity {
    /// Keychain account under which the raw Ed25519 private key is stored.
    static let keychainAccount = "companion.device-identity.ed25519"

    let signingPrivateKey: Curve25519.Signing.PrivateKey
    /// `true` when the key is backed by the Keychain; `false` when the Keychain
    /// was unavailable and this is an in-memory fallback that will not survive
    /// relaunch.
    let isPersistent: Bool

    var signingPublicKey: Curve25519.Signing.PublicKey { signingPrivateKey.publicKey }

    /// base64url of the raw Ed25519 public key.
    var deviceId: String { Self.deviceId(for: signingPublicKey) }

    static func deviceId(for publicKey: Curve25519.Signing.PublicKey) -> String {
        CompanionBase64URL.encode(publicKey.rawRepresentation)
    }

    /// Loads the persisted identity or mints a new one. Never throws: a Keychain
    /// failure is logged and degrades to a working, non-persistent identity so the
    /// rest of the app keeps functioning (log-and-continue tier).
    static func loadOrCreate(keychain: CompanionKeychainStoring) -> CompanionDeviceIdentity {
        do {
            if let data = try keychain.read(account: keychainAccount) {
                if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
                    return CompanionDeviceIdentity(signingPrivateKey: key, isPersistent: true)
                }
                companionSecurityLogger.error("Stored companion identity is malformed; regenerating")
            }
        } catch {
            companionSecurityLogger.error(
                "Keychain read failed (\(String(describing: error), privacy: .public)); using ephemeral identity"
            )
        }

        let key = Curve25519.Signing.PrivateKey()
        do {
            try keychain.store(key.rawRepresentation, account: keychainAccount)
            return CompanionDeviceIdentity(signingPrivateKey: key, isPersistent: true)
        } catch {
            companionSecurityLogger.error(
                "Keychain store failed (\(String(describing: error), privacy: .public)); identity will not persist"
            )
            return CompanionDeviceIdentity(signingPrivateKey: key, isPersistent: false)
        }
    }
}
