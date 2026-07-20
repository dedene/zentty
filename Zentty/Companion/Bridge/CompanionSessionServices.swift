import CryptoKit
import Foundation

// MARK: - Crypto handshake frame

/// The plaintext frames that establish the encrypted channel for an
/// already-paired device, exchanged before the first sealed `session.hello`.
///
/// The wire draft's crypto section specifies the X25519/Ed25519 material but
/// does not name the on-wire exchange frames; the bridge defines them here and
/// the phone (react-native-libsodium) mirrors them. Order:
/// 1. phone → mac: `{deviceId, ephemeralPublicKey}` (no signature yet)
/// 2. mac → phone: `{deviceId, ephemeralPublicKey, signature}`
/// 3. phone → mac: `{signature}`
///
/// Each signature is over the canonical `CompanionHandshake` transcript, which
/// includes both ephemerals — so a side can only sign once it has seen the
/// peer's ephemeral key.
struct CompanionCryptoHandshakeFrame: Codable, Equatable, Sendable {
    /// base64url of the sender's Ed25519 identity public key (its `deviceId`).
    var deviceId: String?
    /// base64url of the sender's per-session X25519 ephemeral public key.
    var ephemeralPublicKey: String?
    /// base64url of the Ed25519 signature over the handshake transcript.
    var signature: String?

    init(deviceId: String? = nil, ephemeralPublicKey: String? = nil, signature: String? = nil) {
        self.deviceId = deviceId
        self.ephemeralPublicKey = ephemeralPublicKey
        self.signature = signature
    }
}

// MARK: - Version negotiation

enum CompanionVersionNegotiation {
    /// Effective protocol version for two `{min, max}` ranges, or `nil` when the
    /// ranges do not overlap (incompatible peers).
    static func effectiveVersion(local: CompanionVersionRange, remote: CompanionVersionRange) -> Int? {
        let low = Swift.max(local.min, remote.min)
        let high = Swift.min(local.max, remote.max)
        guard low <= high else { return nil }
        return high
    }

    /// This build's advertised support range.
    static var localRange: CompanionVersionRange {
        CompanionVersionRange(min: CompanionProtocol.minSupported, max: CompanionProtocol.version)
    }
}

// MARK: - Session services seam

/// Everything one `CompanionSession` needs from the rest of the app, behind a
/// protocol so `ZenttyLogicTests` can supply a fake and drive a session over an
/// in-memory pipe. The bridge server provides the production implementation,
/// wiring the pairing store, dashboard feed, and input router.
@MainActor
protocol CompanionSessionServicing: AnyObject {
    /// This Mac's stable identity (Ed25519), pinned by peers at pairing time.
    var identity: CompanionDeviceIdentity { get }

    /// Human-readable Mac name announced in `session.hello` / `pairing.confirm`.
    var localDeviceName: String { get }

    /// This build's app version string (for `session.hello`).
    var appVersion: String { get }

    // Pairing
    func pairedDevice(withId deviceId: String) -> CompanionPairedDevice?
    /// Verifies a `pairing.request` proof against outstanding one-time offers.
    func verifyPairingProof(phonePublicKey: String, proof: String) -> Bool
    /// Persists a newly paired device (also refreshes advertising state).
    func recordPairing(_ device: CompanionPairedDevice)
    /// Bumps a paired device's `lastSeenAt` on a successful session handshake.
    func markDeviceSeen(deviceId: String)

    // Dashboard
    func dashboardSnapshot() -> CompanionDashboardSnapshot
    /// Registers a delta handler; returns a token to unregister on disconnect.
    func addDashboardSubscriber(_ handler: @escaping (CompanionDashboardDelta) -> Void) -> CompanionDashboardSubscriptionToken
    func removeDashboardSubscriber(_ token: CompanionDashboardSubscriptionToken)

    // Input
    func routeInput(_ message: CompanionMessage) -> CompanionInputAck
}
