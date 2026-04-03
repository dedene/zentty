import AppKit
import Foundation
import UserNotifications

@MainActor
protocol WorklaneAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(identifier: String, title: String, body: String, worklaneID: String, paneID: String, soundName: String)
}

@MainActor
final class WorklaneAttentionNotificationCoordinator {
    private let center: any WorklaneAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private let configStore: AppConfigStore?
    private var lastSeenStates: [WorklaneID: WorklaneAttentionState] = [:]
    private var lastSeenPaneIDs: [WorklaneID: PaneID] = [:]

    init(
        center: any WorklaneAttentionUserNotificationCenter = WorklaneAttentionUNCenter(),
        notificationStore: NotificationStore,
        configStore: AppConfigStore? = nil
    ) {
        self.center = center
        self.notificationStore = notificationStore
        self.configStore = configStore
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

            guard didChange,
                  shouldNotifySystemNotification(
                    for: attention,
                    in: worklane,
                    activeWorklaneID: activeWorklaneID,
                    windowIsKey: windowIsKey
                  ) else {
                continue
            }

            center.add(
                identifier: "\(worklane.id.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                title: attention.statusText,
                body: systemNotificationBody(for: attention, in: worklane),
                worklaneID: worklane.id.rawValue,
                paneID: attention.paneID.rawValue,
                soundName: configStore?.current.notifications.soundName ?? ""
            )
            if attention.state == .needsInput, !windowIsKey {
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

    private func shouldNotifySystemNotification(
        for attention: WorklaneAttentionSummary,
        in worklane: WorklaneState,
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) -> Bool {
        switch attention.state {
        case .needsInput:
            return (worklane.id != activeWorklaneID) || !windowIsKey
        case .ready:
            return !isPaneActivelyViewed(
                paneID: attention.paneID,
                in: worklane,
                activeWorklaneID: activeWorklaneID,
                windowIsKey: windowIsKey
            )
        case .unresolvedStop, .running:
            return false
        }
    }

    private func isPaneActivelyViewed(
        paneID: PaneID,
        in worklane: WorklaneState,
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) -> Bool {
        windowIsKey
            && worklane.id == activeWorklaneID
            && worklane.paneStripState.focusedPaneID == paneID
    }

    private func systemNotificationBody(
        for attention: WorklaneAttentionSummary,
        in worklane: WorklaneState
    ) -> String {
        guard attention.state == .ready else {
            return attention.primaryText
        }

        if let presentation = worklane.paneContext(for: attention.paneID)?.presentation {
            let meaningfulTitle = WorklaneContextFormatter.trimmed(presentation.rememberedTitle)
                ?? WorklaneContextFormatter.trimmed(presentation.identityText)
            if let meaningfulTitle,
               meaningfulTitle != presentation.contextText,
               meaningfulTitle.caseInsensitiveCompare("shell") != .orderedSame {
                return meaningfulTitle
            }

            if let cwd = presentation.cwd,
               let compactPath = WorklaneContextFormatter.compactRepositorySidebarPath(cwd)
                ?? WorklaneContextFormatter.formattedWorkingDirectory(cwd, branch: nil) {
                return "Agent in \(compactPath) is ready."
            }
        }

        return "Agent is ready."
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

    func add(identifier: String, title: String, body: String, worklaneID: String, paneID: String, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "agent-attention"
        content.threadIdentifier = worklaneID
        content.userInfo = ["worklaneID": worklaneID, "paneID": paneID]
        content.sound = resolvedNotificationSound(for: soundName)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
