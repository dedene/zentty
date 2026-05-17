import Foundation

struct PaneNotificationRequest: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let body: String?
    let includeInbox: Bool
    let isSilent: Bool
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID

    init(
        title: String,
        subtitle: String?,
        body: String? = nil,
        includeInbox: Bool,
        isSilent: Bool,
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.includeInbox = includeInbox
        self.isSilent = isSilent
        self.windowID = windowID
        self.worklaneID = worklaneID
        self.paneID = paneID
    }
}

@MainActor
final class PaneNotificationCoordinator {
    private let center: any WorklaneAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private let configStore: AppConfigStore?

    init(
        center: (any WorklaneAttentionUserNotificationCenter)? = nil,
        notificationStore: NotificationStore,
        configStore: AppConfigStore?
    ) {
        self.center = center ?? WorklaneAttentionUNCenter()
        self.notificationStore = notificationStore
        self.configStore = configStore
        self.center.requestAuthorizationIfNeeded()
    }

    func deliver(_ request: PaneNotificationRequest) {
        let body = request.body?.nonBlank ?? ""
        center.add(
            identifier: "pane-notification-\(UUID().uuidString)",
            title: request.title,
            subtitle: request.subtitle,
            body: body,
            windowID: request.windowID.rawValue,
            worklaneID: request.worklaneID.rawValue,
            paneID: request.paneID.rawValue,
            soundName: request.isSilent ? nil : (configStore?.current.notifications.soundName ?? "")
        )

        guard request.includeInbox else {
            return
        }

        notificationStore.add(
            windowID: request.windowID,
            worklaneID: request.worklaneID,
            paneID: request.paneID,
            state: .ready,
            tool: .zentty,
            interactionKind: nil,
            interactionSymbolName: "bell.fill",
            statusText: request.title,
            primaryText: request.body?.nonBlank ?? request.subtitle ?? "Notification from pane.",
            locationText: nil,
            isDebounced: false,
            coalescesByPane: false
        )
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
