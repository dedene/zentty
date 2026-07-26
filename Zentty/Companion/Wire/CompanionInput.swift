import Foundation

// MARK: - input.*

/// The named keys `input.key` may carry.
enum CompanionInputKey: String, Codable, Equatable, Sendable {
    case enter
    case escape
    case tab
    case up
    case down
    case left
    case right
    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case ctrlZ = "ctrl_z"
    case ctrlR = "ctrl_r"
}

/// `input.text` (phone → mac) — UTF-8 passthrough.
struct CompanionInputText: CompanionMessagePayload {
    static let messageType = "input.text"

    var paneId: String
    var text: String
}

/// `input.key` (phone → mac).
struct CompanionInputKeyMessage: CompanionMessagePayload {
    static let messageType = "input.key"

    var paneId: String
    var key: CompanionInputKey
}

/// `input.quickAction` (phone → mac).
struct CompanionInputQuickAction: CompanionMessagePayload {
    static let messageType = "input.quickAction"

    var paneId: String
    var actionId: String
}

/// `input.ack` (mac → phone), correlated via the envelope `replyTo`.
struct CompanionInputAck: CompanionMessagePayload {
    static let messageType = "input.ack"

    var ok: Bool
    var error: String?
}
