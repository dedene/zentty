import CryptoKit
import Foundation
import OSLog

private let companionPairingLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionPairing")

// MARK: - Records

/// A device this Mac has paired with. Persisted as JSON; `publicKey` and
/// `deviceId` are base64url of the peer's Ed25519 identity key.
struct CompanionPairedDevice: Codable, Equatable, Sendable {
    var deviceId: String
    var publicKey: String
    var name: String
    var pairedAt: Date
    var lastSeenAt: Date

    init(deviceId: String, publicKey: String, name: String, pairedAt: Date, lastSeenAt: Date) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// A freshly minted one-time pairing secret. The transport wraps this into the
/// QR-carried `pairing.offer` (adding relay URL, LAN hint, Mac identity). The
/// secret itself never persists — it lives only until it is used or expires.
struct CompanionMintedOffer: Equatable, Sendable {
    let secret: Data
    let expiresAt: Date

    /// base64url of the raw secret, as it travels in the QR payload.
    var secretBase64URL: String { CompanionBase64URL.encode(secret) }

    func isExpired(now: Date) -> Bool { now >= expiresAt }
}

// MARK: - Store

/// Persists the set of paired devices (JSON in the app config dir, mirroring
/// `SessionRestoreStore`) and brokers one-time pairing offers plus proof
/// verification.
///
/// Not internally synchronized — callers serialize access (main actor / the
/// bridge's connection queue), same contract as `SessionRestoreStore`.
final class CompanionPairingStore {
    /// Default lifetime of a pairing offer (~2 min, per the security model).
    static let defaultOfferTTL: TimeInterval = 120
    /// Secret size in bytes.
    static let secretByteCount = 32

    private let fileURL: URL
    private let fileManager: FileManager
    private var cachedDevices: [CompanionPairedDevice]
    private var activeOffers: [CompanionMintedOffer] = []

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.cachedDevices = Self.loadDevices(from: fileURL, fileManager: fileManager)
    }

    convenience init(configDirectoryURL: URL, fileManager: FileManager = .default) {
        self.init(
            fileURL: configDirectoryURL.appendingPathComponent("companion-paired-devices.json"),
            fileManager: fileManager
        )
    }

    // MARK: Devices

    func devices() -> [CompanionPairedDevice] { cachedDevices }

    func device(withId deviceId: String) -> CompanionPairedDevice? {
        cachedDevices.first { $0.deviceId == deviceId }
    }

    func contains(deviceId: String) -> Bool {
        cachedDevices.contains { $0.deviceId == deviceId }
    }

    /// Adds or replaces (by `deviceId`) a paired device, then persists.
    func add(_ device: CompanionPairedDevice) throws {
        if let index = cachedDevices.firstIndex(where: { $0.deviceId == device.deviceId }) {
            cachedDevices[index] = device
        } else {
            cachedDevices.append(device)
        }
        try persist()
    }

    /// Removes a paired device (revocation). No-op if unknown.
    func remove(deviceId: String) throws {
        let before = cachedDevices.count
        cachedDevices.removeAll { $0.deviceId == deviceId }
        guard cachedDevices.count != before else { return }
        try persist()
    }

    /// Updates a device's `lastSeenAt` and persists. No-op if unknown.
    func updateLastSeen(deviceId: String, at date: Date) throws {
        guard let index = cachedDevices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        cachedDevices[index].lastSeenAt = date
        try persist()
    }

    // MARK: Pairing offers

    /// Mints a one-time secret + expiry and tracks it as active. Expired offers
    /// are purged as a side effect.
    @discardableResult
    func mintOffer(now: Date = Date(), ttl: TimeInterval = CompanionPairingStore.defaultOfferTTL) -> CompanionMintedOffer {
        purgeExpiredOffers(now: now)
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let offer = CompanionMintedOffer(secret: secret, expiresAt: now.addingTimeInterval(ttl))
        activeOffers.append(offer)
        return offer
    }

    /// Cancels every outstanding offer (e.g. the pairing sheet was dismissed).
    func clearOffers() {
        activeOffers.removeAll()
    }

    var hasActiveOffer: Bool { !activeOffers.isEmpty }

    /// Verifies a `pairing.request` proof against the active offers. The proof is
    /// `HMAC-SHA256(secret, rawPhonePublicKey)`. Inputs are the base64url wire
    /// strings exactly as received. A match consumes the offer (one-time) and
    /// returns `true`; expired offers are purged and never match.
    func verifyPairingProof(
        phonePublicKey encodedPublicKey: String,
        proof encodedProof: String,
        now: Date = Date()
    ) -> Bool {
        purgeExpiredOffers(now: now)
        guard
            let publicKey = CompanionBase64URL.decode(encodedPublicKey),
            let proof = CompanionBase64URL.decode(encodedProof)
        else {
            return false
        }

        for index in activeOffers.indices {
            let key = SymmetricKey(data: activeOffers[index].secret)
            if HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: publicKey, using: key) {
                activeOffers.remove(at: index)
                return true
            }
        }
        return false
    }

    private func purgeExpiredOffers(now: Date) {
        activeOffers.removeAll { $0.isExpired(now: now) }
    }

    // MARK: Persistence

    private func persist() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cachedDevices)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadDevices(from url: URL, fileManager: FileManager) -> [CompanionPairedDevice] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([CompanionPairedDevice].self, from: data)
        } catch {
            companionPairingLogger.error(
                "Failed to load paired devices (\(String(describing: error), privacy: .public)); starting empty"
            )
            return []
        }
    }
}
