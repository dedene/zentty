import Foundation

// MARK: - pairing.*

/// `pairing.offer` — carried in the QR code, not sent on the wire, but modeled
/// for completeness and conformance testing.
struct CompanionPairingOffer: CompanionMessagePayload {
    static let messageType = "pairing.offer"

    var relayUrl: String
    var lanHint: CompanionLanHint?
    var macDeviceId: String
    var macPubKey: String
    var secret: String
    var expiresAt: Int
}

/// `pairing.request` (phone → mac).
struct CompanionPairingRequest: CompanionMessagePayload {
    static let messageType = "pairing.request"

    var phoneDeviceId: String
    var phonePubKey: String
    var phoneName: String
    var proof: String
}

/// `pairing.confirm` (mac → phone). `paired` is a literal `true` marker.
struct CompanionPairingConfirm: CompanionMessagePayload {
    static let messageType = "pairing.confirm"

    var macName: String
    var paired: Bool

    private enum CodingKeys: String, CodingKey {
        case macName
        case paired
    }

    init(macName: String, paired: Bool = true) {
        self.macName = macName
        self.paired = paired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macName = try container.decode(String.self, forKey: .macName)
        paired = try container.decode(Bool.self, forKey: .paired)
        guard paired else {
            throw DecodingError.dataCorruptedError(
                forKey: .paired,
                in: container,
                debugDescription: "pairing.confirm requires paired == true"
            )
        }
    }
}

/// `pairing.reject` (mac → phone).
struct CompanionPairingReject: CompanionMessagePayload {
    static let messageType = "pairing.reject"

    var reason: String
}
