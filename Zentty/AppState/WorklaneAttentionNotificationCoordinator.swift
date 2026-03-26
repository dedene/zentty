import AppKit
import Foundation
import UserNotifications

@MainActor
protocol WorklaneAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(identifier: String, title: String, body: String, worklaneID: String, paneID: String)
}

@MainActor
final class WorklaneAttentionNotificationCoordinator {
    private let center: any WorklaneAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private var lastSeenStates: [WorklaneID: WorklaneAttentionState] = [:]
    private var lastSeenPaneIDs: [WorklaneID: PaneID] = [:]

    init(
        center: any WorklaneAttentionUserNotificationCenter = WorklaneAttentionUNCenter(),
        notificationStore: NotificationStore
    ) {
        self.center = center
        self.notificationStore = notificationStore
        center.requestAuthorizationIfNeeded()
    }

    func update(
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [WorklaneID: WorklaneAttentionState] = [:]
        var nextSeenPaneIDs: [WorklaneID: PaneID] = [:]
        var visitedWorklaneIDs = Set<WorklaneID>()

        for worklane in worklanes {
            visitedWorklaneIDs.insert(worklane.id)

            guard let attention = WorklaneAttentionSummaryBuilder.summary(for: worklane) else {
                // Worklane no longer has attention — resolve if it was previously needsInput.
                if lastSeenStates[worklane.id] == .needsInput,
                   let previousPaneID = lastSeenPaneIDs[worklane.id] {
                    notificationStore.resolve(worklaneID: worklane.id, paneID: previousPaneID)
                }
                continue
            }

            nextSeenStates[worklane.id] = attention.state
            nextSeenPaneIDs[worklane.id] = attention.paneID

            let stateChanged = lastSeenStates[worklane.id] != attention.state
            let paneChanged = lastSeenPaneIDs[worklane.id] != attention.paneID
            let didChange = stateChanged || paneChanged

            // Resolve in-app notification when leaving needsInput or when the attention pane changed.
            if didChange,
               lastSeenStates[worklane.id] == .needsInput,
               let previousPaneID = lastSeenPaneIDs[worklane.id] {
                notificationStore.resolve(worklaneID: worklane.id, paneID: previousPaneID)
            }

            // Add in-app notification when entering needsInput or when the attention pane changed.
            if didChange, attention.state == .needsInput {
                notificationStore.add(
                    worklaneID: worklane.id,
                    paneID: attention.paneID,
                    tool: attention.tool,
                    interactionKind: attention.interactionKind,
                    interactionSymbolName: attention.interactionSymbolName,
                    statusText: attention.statusText,
                    primaryText: attention.primaryText
                )
            }

            // System notification — only for background / non-active worklanes.
            let shouldNotify = (worklane.id != activeWorklaneID) || !windowIsKey
            guard didChange, shouldNotify, attention.state == .needsInput else {
                continue
            }

            center.add(
                identifier: "\(worklane.id.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                title: attention.statusText,
                body: attention.primaryText,
                worklaneID: worklane.id.rawValue,
                paneID: attention.paneID.rawValue
            )
            if !windowIsKey {
                NSApplication.shared.requestUserAttention(.informationalRequest)
            }
        }

        // Resolve any worklanes that were removed entirely (not in the worklanes array).
        for (worklaneID, previousState) in lastSeenStates {
            guard previousState == .needsInput,
                  !visitedWorklaneIDs.contains(worklaneID),
                  let previousPaneID = lastSeenPaneIDs[worklaneID] else { continue }
            notificationStore.resolve(worklaneID: worklaneID, paneID: previousPaneID)
        }

        lastSeenStates = nextSeenStates
        lastSeenPaneIDs = nextSeenPaneIDs
    }
}

@MainActor
final class WorklaneAttentionUNCenter: NSObject, WorklaneAttentionUserNotificationCenter {
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
            title: "Jump to Worklane",
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

    func add(identifier: String, title: String, body: String, worklaneID: String, paneID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "agent-attention"
        content.threadIdentifier = worklaneID
        content.userInfo = ["worklaneID": worklaneID, "paneID": paneID]
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
