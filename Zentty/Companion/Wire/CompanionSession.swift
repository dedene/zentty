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
    /// This Mac's current direct-LAN endpoint, restated on every handshake so the
    /// phone's cached hint self-heals after a rename or a port change. `nil` when
    /// there is no live listener — which means "no update", not "forget it".
    var lanHint: CompanionLanHint?

    init(v: Int, lanHint: CompanionLanHint? = nil) {
        self.v = v
        self.lanHint = lanHint
    }
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
