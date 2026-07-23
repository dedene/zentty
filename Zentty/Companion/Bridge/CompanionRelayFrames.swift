import Foundation

// MARK: - Relay transport framing
//
// These are the *plaintext* frames exchanged between a device and the relay —
// NOT the end-to-end `CompanionEnvelope` family. The relay never sees an
// envelope: session frames ride opaque inside `relay.frame.sealed` (base64url).
//
// Wire shape (mirrored by `@zentty/wire` `src/relay.ts`): a flat JSON object with
// a `type` discriminator and the frame's fields at the top level, e.g.
// `{ "type": "relay.challenge", "nonce": "…", "ts": 1720000000000 }`. This is the
// natural `z.discriminatedUnion("type", …)` shape on the TS side; there is no
// nested `payload` object (that is the E2E envelope's shape, not the relay's).
//
// All keys/strings are UTF-8; every public key, signature, nonce, and sealed
// blob is base64url unpadded (`CompanionBase64URL`). Timestamps are ms epoch.

/// The message a device signs to answer the relay auth challenge: the UTF-8
/// bytes of `"zentty-relay-auth:" + nonce`, where `nonce` is the base64url
/// string exactly as transmitted in `relay.challenge` (NOT decoded — the relay
/// verifies over the transmitted spelling).
enum CompanionRelayAuthProof {
    static let label = "zentty-relay-auth:"

    static func message(nonce: String) -> Data {
        Data((label + nonce).utf8)
    }
}

// MARK: - Frame payloads

/// `relay.challenge` (relay → device, on connect).
struct CompanionRelayChallenge: Codable, Equatable, Sendable {
    /// base64url of the random per-connection nonce the device must sign.
    var nonce: String
    /// Server timestamp (ms epoch) the challenge was minted.
    var ts: Int
}

/// `relay.auth` (device → relay).
struct CompanionRelayAuth: Codable, Equatable, Sendable {
    /// The device's `deviceId` = base64url of its raw 32-byte Ed25519 public key.
    var deviceId: String
    /// base64url of the raw 32-byte Ed25519 public key (equals `deviceId`).
    var pubKey: String
    /// base64url Ed25519 signature over `CompanionRelayAuthProof.message(nonce:)`.
    var sig: String
}

/// `relay.ready` (relay → device) — authentication accepted.
struct CompanionRelayReady: Codable, Equatable, Sendable {
    var deviceId: String
}

/// `relay.denied` (relay → device) — authentication rejected; connection closes.
struct CompanionRelayDenied: Codable, Equatable, Sendable {
    var reason: String
}

/// `relay.frame` (both ways). `sealed` carries either a plaintext pairing
/// envelope (`pairing.*` only) or an encrypted session frame — the relay never
/// inspects it and stamps `from` with the authenticated sender.
struct CompanionRelaySealedFrame: Codable, Equatable, Sendable {
    var to: String
    var from: String
    /// base64url of the whole opaque frame (JSON handshake bytes or sealed AEAD).
    var sealed: String
}

/// `relay.peerStatus` (relay → device) — a watched peer's presence changed.
struct CompanionRelayPeerStatus: Codable, Equatable, Sendable {
    var deviceId: String
    var online: Bool
}

/// `relay.watch` (device → relay) — explicit subscribe to a peer's presence.
struct CompanionRelayWatch: Codable, Equatable, Sendable {
    var deviceId: String
}

/// `relay.error` (relay → device).
struct CompanionRelayError: Codable, Equatable, Sendable {
    /// One of `rate_limited | peer_unknown | frame_too_large | not_authed`.
    var code: String
    var message: String
}

// MARK: - Discriminated union

/// A single relay frame: the `type` string paired with its decoded fields.
/// Encodes/decodes flat — the fields sit alongside `type` at the top level.
enum CompanionRelayFrame: Equatable, Sendable {
    case challenge(CompanionRelayChallenge)
    case auth(CompanionRelayAuth)
    case ready(CompanionRelayReady)
    case denied(CompanionRelayDenied)
    case frame(CompanionRelaySealedFrame)
    case peerStatus(CompanionRelayPeerStatus)
    case watch(CompanionRelayWatch)
    case error(CompanionRelayError)

    static let challengeType = "relay.challenge"
    static let authType = "relay.auth"
    static let readyType = "relay.ready"
    static let deniedType = "relay.denied"
    static let frameType = "relay.frame"
    static let peerStatusType = "relay.peerStatus"
    static let watchType = "relay.watch"
    static let errorType = "relay.error"

    var type: String {
        switch self {
        case .challenge: return Self.challengeType
        case .auth: return Self.authType
        case .ready: return Self.readyType
        case .denied: return Self.deniedType
        case .frame: return Self.frameType
        case .peerStatus: return Self.peerStatusType
        case .watch: return Self.watchType
        case .error: return Self.errorType
        }
    }
}

// MARK: - Field validation
//
// Synthesized `Codable` only checks JSON *shape* (presence/type), not the
// tighter wire contract `companion/wire/src/relay.ts` enforces with zod
// (`Base64Url` = non-empty unpadded base64url; `code` = a closed enum). Every
// base64url-spelled field and the error-code enum gets the matching check here
// so a malformed frame fails to decode on both sides of the wire, not just TS.

/// A relay frame decoded with the right shape but a field that fails the
/// wire's stricter format contract (bad base64url spelling, unknown enum case).
struct CompanionRelayFieldError: Error, Equatable {
    let field: String
}

extension CompanionRelayChallenge {
    fileprivate func validate() throws {
        guard CompanionBase64URL.isValidUnpadded(nonce) else {
            throw CompanionRelayFieldError(field: "nonce")
        }
    }
}

extension CompanionRelayAuth {
    fileprivate func validate() throws {
        for (field, value) in [("deviceId", deviceId), ("pubKey", pubKey), ("sig", sig)] {
            guard CompanionBase64URL.isValidUnpadded(value) else {
                throw CompanionRelayFieldError(field: field)
            }
        }
    }
}

extension CompanionRelayReady {
    fileprivate func validate() throws {
        guard CompanionBase64URL.isValidUnpadded(deviceId) else {
            throw CompanionRelayFieldError(field: "deviceId")
        }
    }
}

extension CompanionRelaySealedFrame {
    fileprivate func validate() throws {
        for (field, value) in [("to", to), ("from", from), ("sealed", sealed)] {
            guard CompanionBase64URL.isValidUnpadded(value) else {
                throw CompanionRelayFieldError(field: field)
            }
        }
    }
}

extension CompanionRelayPeerStatus {
    fileprivate func validate() throws {
        guard CompanionBase64URL.isValidUnpadded(deviceId) else {
            throw CompanionRelayFieldError(field: "deviceId")
        }
    }
}

extension CompanionRelayWatch {
    fileprivate func validate() throws {
        guard CompanionBase64URL.isValidUnpadded(deviceId) else {
            throw CompanionRelayFieldError(field: "deviceId")
        }
    }
}

extension CompanionRelayError {
    /// Mirrors `RELAY_ERROR_CODES` in `companion/wire/src/relay.ts`.
    static let knownCodes: Set<String> = ["rate_limited", "peer_unknown", "frame_too_large", "not_authed"]

    fileprivate func validate() throws {
        guard Self.knownCodes.contains(code) else {
            throw CompanionRelayFieldError(field: "code")
        }
    }
}

// MARK: - Codable (flat, type-tagged)

extension CompanionRelayFrame: Codable {
    private enum TypeKey: String, CodingKey { case type }

    /// A relay frame carried a `type` this build does not understand.
    struct UnknownFrameTypeError: Error, Equatable {
        let type: String
    }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(String.self, forKey: .type)
        switch type {
        case Self.challengeType:
            let payload = try CompanionRelayChallenge(from: decoder)
            try payload.validate()
            self = .challenge(payload)
        case Self.authType:
            let payload = try CompanionRelayAuth(from: decoder)
            try payload.validate()
            self = .auth(payload)
        case Self.readyType:
            let payload = try CompanionRelayReady(from: decoder)
            try payload.validate()
            self = .ready(payload)
        case Self.deniedType:
            self = .denied(try CompanionRelayDenied(from: decoder))
        case Self.frameType:
            let payload = try CompanionRelaySealedFrame(from: decoder)
            try payload.validate()
            self = .frame(payload)
        case Self.peerStatusType:
            let payload = try CompanionRelayPeerStatus(from: decoder)
            try payload.validate()
            self = .peerStatus(payload)
        case Self.watchType:
            let payload = try CompanionRelayWatch(from: decoder)
            try payload.validate()
            self = .watch(payload)
        case Self.errorType:
            let payload = try CompanionRelayError(from: decoder)
            try payload.validate()
            self = .error(payload)
        default: throw UnknownFrameTypeError(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .challenge(let p): try p.encode(to: encoder)
        case .auth(let p): try p.encode(to: encoder)
        case .ready(let p): try p.encode(to: encoder)
        case .denied(let p): try p.encode(to: encoder)
        case .frame(let p): try p.encode(to: encoder)
        case .peerStatus(let p): try p.encode(to: encoder)
        case .watch(let p): try p.encode(to: encoder)
        case .error(let p): try p.encode(to: encoder)
        }
        var typeContainer = encoder.container(keyedBy: TypeKey.self)
        try typeContainer.encode(type, forKey: .type)
    }
}
