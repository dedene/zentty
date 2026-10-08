import Foundation

/// A manual "Check back" mark on an idle agent pane (Mark as Unread).
///
/// The mark is consumed by a later visit, never by the visit that created it:
/// marking the focused pane only clears after focus has left it and returned.
struct PaneCheckBackReminder: Equatable, Sendable {
    static let statusText = "Check back"
    static let statusSymbolName = "checkmark.circle.fill"

    var hasLeftPane: Bool
}

/// What the Mark as Unread command does for a pane right now.
enum PaneUnreadToggle: Equatable, Sendable {
    /// Idle agent pane without a visible ready/check-back status.
    case markUnread
    /// Pane showing "Agent ready" or "Check back".
    case markRead

    var title: String {
        switch self {
        case .markUnread:
            "Mark as Unread"
        case .markRead:
            "Mark as Read"
        }
    }

    var symbolName: String {
        switch self {
        case .markUnread:
            "envelope.badge"
        case .markRead:
            "envelope.open"
        }
    }

    static func resolve(for presentation: PanePresentationState) -> PaneUnreadToggle? {
        if presentation.isReady || presentation.isCheckBack {
            return .markRead
        }
        guard presentation.recognizedTool != nil, presentation.runtimePhase == .idle else {
            return nil
        }
        return .markUnread
    }
}
