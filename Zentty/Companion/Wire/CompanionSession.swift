import Foundation

// MARK: - session.*

/// `session.hello` (both ways, first encrypted frame).
struct CompanionSessionHello: CompanionMessagePayload {
    static let messageType = "session.hello"

    var supported: CompanionVersionRange
    var deviceName: String
    var appVersion: String
}

/// `session.ready` — echoes the effective negotiated version.
struct CompanionSessionReady: CompanionMessagePayload {
    static let messageType = "session.ready"

    var v: Int
}

/// `session.ping`.
struct CompanionSessionPing: CompanionMessagePayload {
    static let messageType = "session.ping"

    var ts: Int
}

/// `session.pong`.
struct CompanionSessionPong: CompanionMessagePayload {
    static let messageType = "session.pong"

    var ts: Int
}

/// `session.error`.
struct CompanionSessionError: CompanionMessagePayload {
    static let messageType = "session.error"

    var code: String
    var message: String
    var fatal: Bool
}
