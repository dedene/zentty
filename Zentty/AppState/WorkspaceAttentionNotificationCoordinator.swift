import Foundation
import UserNotifications

@MainActor
protocol WorkspaceAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(identifier: String, title: String, body: String)
}

@MainActor
final class WorkspaceAttentionNotificationCoordinator {
    private let center: any WorkspaceAttentionUserNotificationCenter
    private var lastSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]

    init(center: any WorkspaceAttentionUserNotificationCenter = WorkspaceAttentionUNCenter()) {
        self.center = center
        center.requestAuthorizationIfNeeded()
    }

    func update(
        workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]

        for workspace in workspaces {
            guard let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace) else {
                continue
            }

            nextSeenStates[workspace.id] = attention.state
            let didChange = lastSeenStates[workspace.id] != attention.state
            let shouldNotify = (workspace.id != activeWorkspaceID) || !windowIsKey
            let isNotifyable = attention.state == .needsInput
            guard didChange, shouldNotify, isNotifyable else {
                continue
            }

            center.add(
                identifier: "\(workspace.id.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                title: attention.statusText,
                body: attention.primaryText
            )
        }

        lastSeenStates = nextSeenStates
    }
}

@MainActor
final class WorkspaceAttentionUNCenter: NSObject, WorkspaceAttentionUserNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else {
            return
        }

        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func add(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
