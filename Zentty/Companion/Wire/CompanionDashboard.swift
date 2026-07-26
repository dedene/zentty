import Foundation

// MARK: - dashboard.*

/// `dashboard.subscribe` (phone → mac). Empty payload; unknown fields tolerated.
struct CompanionDashboardSubscribe: CompanionMessagePayload {
    static let messageType = "dashboard.subscribe"
}

/// One worklane group inside a dashboard snapshot.
struct CompanionDashboardWorklane: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var windowId: Int
    var attention: Bool
    var panes: [CompanionPaneSummary]
}

/// `dashboard.snapshot` (mac → phone).
struct CompanionDashboardSnapshot: CompanionMessagePayload {
    static let messageType = "dashboard.snapshot"

    var worklanes: [CompanionDashboardWorklane]
}

/// `dashboard.delta` (mac → phone).
struct CompanionDashboardDelta: CompanionMessagePayload {
    static let messageType = "dashboard.delta"

    var updated: [CompanionPaneSummary]
    var removedPaneIds: [String]
}
