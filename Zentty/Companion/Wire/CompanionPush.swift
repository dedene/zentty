import Foundation

// MARK: - push.*

/// The push platform a device registers for.
enum CompanionPushPlatform: String, Codable, Equatable, Sendable {
    case apns
    case fcm
}

/// `push.register` (phone → mac; mac forwards signed to the gateway).
struct CompanionPushRegister: CompanionMessagePayload {
    static let messageType = "push.register"

    var platform: CompanionPushPlatform
    var token: String
    var deviceId: String
}

/// `push.test` (phone → mac) — request a test notification. Empty payload;
/// unknown fields tolerated.
struct CompanionPushTest: CompanionMessagePayload {
    static let messageType = "push.test"
}
