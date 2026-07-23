import Foundation

// MARK: - Protocol version

enum CompanionProtocol {
    /// The protocol version this build speaks.
    static let version = 1
    /// The oldest protocol version this build can still talk.
    static let minSupported = 1
}

// MARK: - Envelope

/// The universal frame wrapping every companion message:
/// `{ v, id, type, replyTo?, payload }`.
///
/// Decoding dispatches on `type` to a concrete payload. Unknown `type` strings
/// decode to `.unsupported` (carrying the raw payload) rather than throwing, so
/// a newer peer's messages survive a decode/re-encode round trip. Unknown JSON
/// fields are ignored by Swift's keyed decoding (forward compatibility).
struct CompanionEnvelope: Codable, Equatable, Sendable {
    var v: Int
    var id: String
    var replyTo: String?
    var message: CompanionMessage

    var type: String { message.type }

    enum CodingKeys: String, CodingKey {
        case v
        case id
        case replyTo
        case type
        case payload
    }

    init(v: Int = CompanionProtocol.version, id: String, replyTo: String? = nil, message: CompanionMessage) {
        self.v = v
        self.id = id
        self.replyTo = replyTo
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decode(String.self, forKey: .id)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        let type = try container.decode(String.self, forKey: .type)
        message = try CompanionMessage(type: type, container: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encode(message.type, forKey: .type)
        try message.encodePayload(into: &container)
    }
}

// MARK: - Message

/// A typed companion message: the `type` string paired with its decoded payload.
enum CompanionMessage: Equatable, Sendable {
    // pairing.*
    case pairingOffer(CompanionPairingOffer)
    case pairingRequest(CompanionPairingRequest)
    case pairingConfirm(CompanionPairingConfirm)
    case pairingReject(CompanionPairingReject)
    // session.*
    case sessionHello(CompanionSessionHello)
    case sessionReady(CompanionSessionReady)
    case sessionPing(CompanionSessionPing)
    case sessionPong(CompanionSessionPong)
    case sessionError(CompanionSessionError)
    // dashboard.*
    case dashboardSubscribe(CompanionDashboardSubscribe)
    case dashboardSnapshot(CompanionDashboardSnapshot)
    case dashboardDelta(CompanionDashboardDelta)
    // pane.*
    case paneWatch(CompanionPaneWatch)
    case paneUnwatch(CompanionPaneUnwatch)
    case paneText(CompanionPaneText)
    case paneScrollback(CompanionPaneScrollback)
    // input.*
    case inputText(CompanionInputText)
    case inputKey(CompanionInputKeyMessage)
    case inputQuickAction(CompanionInputQuickAction)
    case inputAck(CompanionInputAck)
    // transcript.*
    case transcriptSubscribe(CompanionTranscriptSubscribe)
    case transcriptSnapshot(CompanionTranscriptSnapshot)
    case transcriptDelta(CompanionTranscriptDelta)
    case transcriptUnavailable(CompanionTranscriptUnavailable)
    // lease.*
    case leaseRequest(CompanionLeaseRequest)
    case leaseGrant(CompanionLeaseGrant)
    case leaseHeartbeat(CompanionLeaseHeartbeat)
    case leaseResize(CompanionLeaseResize)
    case leaseRelease(CompanionLeaseRelease)
    case leaseRevoked(CompanionLeaseRevoked)
    // push.*
    case pushRegister(CompanionPushRegister)
    case pushTest(CompanionPushTest)
    /// A message whose `type` this build does not recognize.
    case unsupported(type: String, payload: CompanionJSONValue)

    /// The envelope `type` string for this message.
    var type: String {
        switch self {
        case .pairingOffer: return CompanionPairingOffer.messageType
        case .pairingRequest: return CompanionPairingRequest.messageType
        case .pairingConfirm: return CompanionPairingConfirm.messageType
        case .pairingReject: return CompanionPairingReject.messageType
        case .sessionHello: return CompanionSessionHello.messageType
        case .sessionReady: return CompanionSessionReady.messageType
        case .sessionPing: return CompanionSessionPing.messageType
        case .sessionPong: return CompanionSessionPong.messageType
        case .sessionError: return CompanionSessionError.messageType
        case .dashboardSubscribe: return CompanionDashboardSubscribe.messageType
        case .dashboardSnapshot: return CompanionDashboardSnapshot.messageType
        case .dashboardDelta: return CompanionDashboardDelta.messageType
        case .paneWatch: return CompanionPaneWatch.messageType
        case .paneUnwatch: return CompanionPaneUnwatch.messageType
        case .paneText: return CompanionPaneText.messageType
        case .paneScrollback: return CompanionPaneScrollback.messageType
        case .inputText: return CompanionInputText.messageType
        case .inputKey: return CompanionInputKeyMessage.messageType
        case .inputQuickAction: return CompanionInputQuickAction.messageType
        case .inputAck: return CompanionInputAck.messageType
        case .transcriptSubscribe: return CompanionTranscriptSubscribe.messageType
        case .transcriptSnapshot: return CompanionTranscriptSnapshot.messageType
        case .transcriptDelta: return CompanionTranscriptDelta.messageType
        case .transcriptUnavailable: return CompanionTranscriptUnavailable.messageType
        case .leaseRequest: return CompanionLeaseRequest.messageType
        case .leaseGrant: return CompanionLeaseGrant.messageType
        case .leaseHeartbeat: return CompanionLeaseHeartbeat.messageType
        case .leaseResize: return CompanionLeaseResize.messageType
        case .leaseRelease: return CompanionLeaseRelease.messageType
        case .leaseRevoked: return CompanionLeaseRevoked.messageType
        case .pushRegister: return CompanionPushRegister.messageType
        case .pushTest: return CompanionPushTest.messageType
        case .unsupported(let type, _): return type
        }
    }

    /// Decode the payload for `type` from the envelope container.
    fileprivate init(type: String, container: KeyedDecodingContainer<CompanionEnvelope.CodingKeys>) throws {
        func decode<T: CompanionMessagePayload>(_: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch type {
        case CompanionPairingOffer.messageType: self = .pairingOffer(try decode(CompanionPairingOffer.self))
        case CompanionPairingRequest.messageType: self = .pairingRequest(try decode(CompanionPairingRequest.self))
        case CompanionPairingConfirm.messageType: self = .pairingConfirm(try decode(CompanionPairingConfirm.self))
        case CompanionPairingReject.messageType: self = .pairingReject(try decode(CompanionPairingReject.self))
        case CompanionSessionHello.messageType: self = .sessionHello(try decode(CompanionSessionHello.self))
        case CompanionSessionReady.messageType: self = .sessionReady(try decode(CompanionSessionReady.self))
        case CompanionSessionPing.messageType: self = .sessionPing(try decode(CompanionSessionPing.self))
        case CompanionSessionPong.messageType: self = .sessionPong(try decode(CompanionSessionPong.self))
        case CompanionSessionError.messageType: self = .sessionError(try decode(CompanionSessionError.self))
        case CompanionDashboardSubscribe.messageType: self = .dashboardSubscribe(try decode(CompanionDashboardSubscribe.self))
        case CompanionDashboardSnapshot.messageType: self = .dashboardSnapshot(try decode(CompanionDashboardSnapshot.self))
        case CompanionDashboardDelta.messageType: self = .dashboardDelta(try decode(CompanionDashboardDelta.self))
        case CompanionPaneWatch.messageType: self = .paneWatch(try decode(CompanionPaneWatch.self))
        case CompanionPaneUnwatch.messageType: self = .paneUnwatch(try decode(CompanionPaneUnwatch.self))
        case CompanionPaneText.messageType: self = .paneText(try decode(CompanionPaneText.self))
        case CompanionPaneScrollback.messageType: self = .paneScrollback(try decode(CompanionPaneScrollback.self))
        case CompanionInputText.messageType: self = .inputText(try decode(CompanionInputText.self))
        case CompanionInputKeyMessage.messageType: self = .inputKey(try decode(CompanionInputKeyMessage.self))
        case CompanionInputQuickAction.messageType: self = .inputQuickAction(try decode(CompanionInputQuickAction.self))
        case CompanionInputAck.messageType: self = .inputAck(try decode(CompanionInputAck.self))
        case CompanionTranscriptSubscribe.messageType: self = .transcriptSubscribe(try decode(CompanionTranscriptSubscribe.self))
        case CompanionTranscriptSnapshot.messageType: self = .transcriptSnapshot(try decode(CompanionTranscriptSnapshot.self))
        case CompanionTranscriptDelta.messageType: self = .transcriptDelta(try decode(CompanionTranscriptDelta.self))
        case CompanionTranscriptUnavailable.messageType: self = .transcriptUnavailable(try decode(CompanionTranscriptUnavailable.self))
        case CompanionLeaseRequest.messageType: self = .leaseRequest(try decode(CompanionLeaseRequest.self))
        case CompanionLeaseGrant.messageType: self = .leaseGrant(try decode(CompanionLeaseGrant.self))
        case CompanionLeaseHeartbeat.messageType: self = .leaseHeartbeat(try decode(CompanionLeaseHeartbeat.self))
        case CompanionLeaseResize.messageType: self = .leaseResize(try decode(CompanionLeaseResize.self))
        case CompanionLeaseRelease.messageType: self = .leaseRelease(try decode(CompanionLeaseRelease.self))
        case CompanionLeaseRevoked.messageType: self = .leaseRevoked(try decode(CompanionLeaseRevoked.self))
        case CompanionPushRegister.messageType: self = .pushRegister(try decode(CompanionPushRegister.self))
        case CompanionPushTest.messageType: self = .pushTest(try decode(CompanionPushTest.self))
        default:
            let payload = try container.decodeIfPresent(CompanionJSONValue.self, forKey: .payload) ?? .object([:])
            self = .unsupported(type: type, payload: payload)
        }
    }

    /// Encode this message's payload under the `payload` key.
    fileprivate func encodePayload(into container: inout KeyedEncodingContainer<CompanionEnvelope.CodingKeys>) throws {
        switch self {
        case .pairingOffer(let p): try container.encode(p, forKey: .payload)
        case .pairingRequest(let p): try container.encode(p, forKey: .payload)
        case .pairingConfirm(let p): try container.encode(p, forKey: .payload)
        case .pairingReject(let p): try container.encode(p, forKey: .payload)
        case .sessionHello(let p): try container.encode(p, forKey: .payload)
        case .sessionReady(let p): try container.encode(p, forKey: .payload)
        case .sessionPing(let p): try container.encode(p, forKey: .payload)
        case .sessionPong(let p): try container.encode(p, forKey: .payload)
        case .sessionError(let p): try container.encode(p, forKey: .payload)
        case .dashboardSubscribe(let p): try container.encode(p, forKey: .payload)
        case .dashboardSnapshot(let p): try container.encode(p, forKey: .payload)
        case .dashboardDelta(let p): try container.encode(p, forKey: .payload)
        case .paneWatch(let p): try container.encode(p, forKey: .payload)
        case .paneUnwatch(let p): try container.encode(p, forKey: .payload)
        case .paneText(let p): try container.encode(p, forKey: .payload)
        case .paneScrollback(let p): try container.encode(p, forKey: .payload)
        case .inputText(let p): try container.encode(p, forKey: .payload)
        case .inputKey(let p): try container.encode(p, forKey: .payload)
        case .inputQuickAction(let p): try container.encode(p, forKey: .payload)
        case .inputAck(let p): try container.encode(p, forKey: .payload)
        case .transcriptSubscribe(let p): try container.encode(p, forKey: .payload)
        case .transcriptSnapshot(let p): try container.encode(p, forKey: .payload)
        case .transcriptDelta(let p): try container.encode(p, forKey: .payload)
        case .transcriptUnavailable(let p): try container.encode(p, forKey: .payload)
        case .leaseRequest(let p): try container.encode(p, forKey: .payload)
        case .leaseGrant(let p): try container.encode(p, forKey: .payload)
        case .leaseHeartbeat(let p): try container.encode(p, forKey: .payload)
        case .leaseResize(let p): try container.encode(p, forKey: .payload)
        case .leaseRelease(let p): try container.encode(p, forKey: .payload)
        case .leaseRevoked(let p): try container.encode(p, forKey: .payload)
        case .pushRegister(let p): try container.encode(p, forKey: .payload)
        case .pushTest(let p): try container.encode(p, forKey: .payload)
        case .unsupported(_, let payload): try container.encode(payload, forKey: .payload)
        }
    }
}
