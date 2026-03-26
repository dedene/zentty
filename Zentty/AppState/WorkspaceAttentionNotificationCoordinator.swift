import AppKit
import Foundation
import UserNotifications

@MainActor
protocol WorkspaceAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(identifier: String, title: String, body: String, workspaceID: String, paneID: String)
}

@MainActor
final class WorkspaceAttentionNotificationCoordinator {
    private let center: any WorkspaceAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private var lastSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]
    private var lastSeenPaneIDs: [WorkspaceID: PaneID] = [:]

    init(
        center: any WorkspaceAttentionUserNotificationCenter = WorkspaceAttentionUNCenter(),
        notificationStore: NotificationStore
    ) {
        self.center = center
        self.notificationStore = notificationStore
        center.requestAuthorizationIfNeeded()
    }

    func update(
        workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]
        var nextSeenPaneIDs: [WorkspaceID: PaneID] = [:]
        var visitedWorkspaceIDs = Set<WorkspaceID>()

        for workspace in workspaces {
            visitedWorkspaceIDs.insert(workspace.id)

            guard let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace) else {
                // Workspace no longer has attention — resolve if it was previously needsInput.
                if lastSeenStates[workspace.id] == .needsInput,
                   let previousPaneID = lastSeenPaneIDs[workspace.id] {
                    notificationStore.resolve(workspaceID: workspace.id, paneID: previousPaneID)
                }
                continue
            }

            nextSeenStates[workspace.id] = attention.state
            nextSeenPaneIDs[workspace.id] = attention.paneID

            let stateChanged = lastSeenStates[workspace.id] != attention.state
            let paneChanged = lastSeenPaneIDs[workspace.id] != attention.paneID
            let didChange = stateChanged || paneChanged

            // Resolve in-app notification when leaving needsInput or when the attention pane changed.
            if didChange,
               lastSeenStates[workspace.id] == .needsInput,
               let previousPaneID = lastSeenPaneIDs[workspace.id] {
                notificationStore.resolve(workspaceID: workspace.id, paneID: previousPaneID)
            }

            // Add in-app notification when entering needsInput or when the attention pane changed.
            if didChange, attention.state == .needsInput {
                notificationStore.add(
                    workspaceID: workspace.id,
                    paneID: attention.paneID,
                    tool: attention.tool,
                    interactionKind: attention.interactionKind,
                    interactionSymbolName: attention.interactionSymbolName,
                    statusText: attention.statusText,
                    primaryText: attention.primaryText
                )
            }

            // System notification — only for background / non-active workspaces.
            let shouldNotify = (workspace.id != activeWorkspaceID) || !windowIsKey
            guard didChange, shouldNotify, attention.state == .needsInput else {
                continue
            }

            center.add(
                identifier: "\(workspace.id.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                title: attention.statusText,
                body: attention.primaryText,
                workspaceID: workspace.id.rawValue,
                paneID: attention.paneID.rawValue
            )
            if !windowIsKey {
                NSApplication.shared.requestUserAttention(.informationalRequest)
            }
        }

        // Resolve any workspaces that were removed entirely (not in the workspaces array).
        for (workspaceID, previousState) in lastSeenStates {
            guard previousState == .needsInput,
                  !visitedWorkspaceIDs.contains(workspaceID),
                  let previousPaneID = lastSeenPaneIDs[workspaceID] else { continue }
            notificationStore.resolve(workspaceID: workspaceID, paneID: previousPaneID)
        }

        lastSeenStates = nextSeenStates
        lastSeenPaneIDs = nextSeenPaneIDs
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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Notifications] authorization error: \(error.localizedDescription)")
            } else {
                print("[Notifications] authorization granted: \(granted)")
            }
        }

        // Log current settings for diagnostics.
        center.getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "notDetermined"
            case .denied: status = "denied"
            case .authorized: status = "authorized"
            case .provisional: status = "provisional"
            case .ephemeral: status = "ephemeral"
            @unknown default: status = "unknown(\(settings.authorizationStatus.rawValue))"
            }
            let style: String
            switch settings.alertStyle {
            case .none: style = "none"
            case .banner: style = "banner"
            case .alert: style = "alert"
            @unknown default: style = "unknown"
            }
            print("[Notifications] status=\(status) alertStyle=\(style) "
                + "alert=\(settings.alertSetting.rawValue) "
                + "sound=\(settings.soundSetting.rawValue) "
                + "badge=\(settings.badgeSetting.rawValue)")
        }

        let jumpAction = UNNotificationAction(
            identifier: "JUMP",
            title: "Jump to Workspace",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "agent-attention",
            actions: [jumpAction, dismissAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func add(identifier: String, title: String, body: String, workspaceID: String, paneID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "agent-attention"
        content.threadIdentifier = workspaceID
        content.userInfo = ["workspaceID": workspaceID, "paneID": paneID]
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
