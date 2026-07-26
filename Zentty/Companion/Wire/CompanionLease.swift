import Foundation

// MARK: - lease.* (takeover)

/// Why a lease was revoked.
enum CompanionLeaseRevokedReason: String, Codable, Equatable, Sendable {
    case takeback
    case expired
    case paneClosed = "pane_closed"
    case superseded
}

/// `lease.request` (phone → mac) — phone-measured natural grid.
struct CompanionLeaseRequest: CompanionMessagePayload {
    static let messageType = "lease.request"

    var paneId: String
    var cols: Int
    var rows: Int
}

/// `lease.grant` (mac → phone).
struct CompanionLeaseGrant: CompanionMessagePayload {
    static let messageType = "lease.grant"

    var paneId: String
    var leaseId: String
    var effective: CompanionGrid
    var client: CompanionGrid
    var isCurrentClientLimiting: Bool
    var heartbeatIntervalMs: Int
    var expiryMs: Int
}

/// `lease.heartbeat` (phone → mac).
struct CompanionLeaseHeartbeat: CompanionMessagePayload {
    static let messageType = "lease.heartbeat"

    var leaseId: String
}

/// `lease.resize` (phone → mac) — rotation/font change.
struct CompanionLeaseResize: CompanionMessagePayload {
    static let messageType = "lease.resize"

    var leaseId: String
    var cols: Int
    var rows: Int
}

/// `lease.release` (phone → mac).
struct CompanionLeaseRelease: CompanionMessagePayload {
    static let messageType = "lease.release"

    var leaseId: String
}

/// `lease.revoked` (mac → phone).
struct CompanionLeaseRevoked: CompanionMessagePayload {
    static let messageType = "lease.revoked"

    var leaseId: String
    var reason: CompanionLeaseRevokedReason
}
