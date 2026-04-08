import AppKit
import Foundation
import UserNotifications

@MainActor
protocol WorklaneAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(
        identifier: String,
        title: String,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String
    )
}

@MainActor
final class WorklaneAttentionNotificationCoordinator {
    private struct PaneKey: Hashable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private let center: any WorklaneAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private let configStore: AppConfigStore?
    private var lastSeenStates: [PaneKey: WorklaneAttentionState] = [:]
    private var lastSeenActiveViews: [PaneKey: Bool] = [:]

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
        windowID: WindowID,
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [PaneKey: WorklaneAttentionState] = [:]
        var nextSeenActiveViews: [PaneKey: Bool] = [:]
        var visitedPaneKeys = Set<PaneKey>()

        for worklane in worklanes {
            for attention in WorklaneAttentionSummaryBuilder.summaries(for: worklane) {
                let key = PaneKey(worklaneID: worklane.id, paneID: attention.paneID)
                visitedPaneKeys.insert(key)
                nextSeenStates[key] = attention.state
                let isActivelyViewed = isPaneActivelyViewed(
                    paneID: attention.paneID,
                    in: worklane,
                    activeWorklaneID: activeWorklaneID,
                    windowIsKey: windowIsKey
                )
                nextSeenActiveViews[key] = isActivelyViewed

                if isActivelyViewed,
                   lastSeenStates[key] == attention.state,
                   lastSeenActiveViews[key] == false {
                    notificationStore.resolve(
                        windowID: windowID,
                        worklaneID: worklane.id,
                        paneID: attention.paneID
                    )
                }

                let stateChanged = lastSeenStates[key] != attention.state
                guard stateChanged else {
                    continue
                }

                if isNotificationWorthy(attention.state) {
                    notificationStore.add(
                        windowID: windowID,
                        worklaneID: worklane.id,
                        paneID: attention.paneID,
                        state: attention.state,
                        tool: attention.tool,
                        interactionKind: attention.interactionKind,
                        interactionSymbolName: attention.interactionSymbolName,
                        statusText: systemNotificationTitle(for: attention),
                        primaryText: systemNotificationBody(for: attention, in: worklane),
                        isDebounced: attention.state == .needsInput
                    )
                } else {
                    notificationStore.resolve(
                        windowID: windowID,
                        worklaneID: worklane.id,
                        paneID: attention.paneID
                    )
                }

                guard shouldNotifySystemNotification(
                    for: attention,
                    in: worklane,
                    activeWorklaneID: activeWorklaneID,
                    windowIsKey: windowIsKey
                ) else {
                    continue
                }

                center.add(
                    identifier: "\(windowID.rawValue)-\(worklane.id.rawValue)-\(attention.paneID.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                    title: systemNotificationTitle(for: attention),
                    body: systemNotificationBody(for: attention, in: worklane),
                    windowID: windowID.rawValue,
                    worklaneID: worklane.id.rawValue,
                    paneID: attention.paneID.rawValue,
                    soundName: systemNotificationSoundName(for: attention.state)
                )
                if attention.state == .needsInput, !windowIsKey {
                    NSApplication.shared.requestUserAttention(.informationalRequest)
                }
            }
        }

        for (key, previousState) in lastSeenStates {
            guard isNotificationWorthy(previousState), !visitedPaneKeys.contains(key) else {
                continue
            }
            notificationStore.resolve(windowID: windowID, worklaneID: key.worklaneID, paneID: key.paneID)
        }

        lastSeenStates = nextSeenStates
        lastSeenActiveViews = nextSeenActiveViews
    }

    private func shouldNotifySystemNotification(
        for attention: WorklaneAttentionSummary,
        in worklane: WorklaneState,
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) -> Bool {
        isNotificationWorthy(attention.state)
            && !isPaneActivelyViewed(
                paneID: attention.paneID,
                in: worklane,
                activeWorklaneID: activeWorklaneID,
                windowIsKey: windowIsKey
            )
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
        switch attention.state {
        case .needsInput:
            return attention.primaryText
        case .unresolvedStop:
            if let presentation = worklane.paneContext(for: attention.paneID)?.presentation {
                let meaningfulTitle = WorklaneContextFormatter.trimmed(presentation.rememberedTitle)
                    ?? WorklaneContextFormatter.trimmed(presentation.identityText)
                if let meaningfulTitle,
                   meaningfulTitle.caseInsensitiveCompare("shell") != .orderedSame {
                    return meaningfulTitle
                }

                if let cwd = presentation.cwd,
                   let compactPath = WorklaneContextFormatter.compactRepositorySidebarPath(cwd)
                    ?? WorklaneContextFormatter.formattedWorkingDirectory(cwd, branch: nil) {
                    return "Agent in \(compactPath) stopped early."
                }
            }

            return "Agent stopped early."
        case .ready:
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
        case .running:
            return attention.primaryText
        }
    }

    private func isNotificationWorthy(_ state: WorklaneAttentionState) -> Bool {
        switch state {
        case .needsInput, .ready, .unresolvedStop:
            return true
        case .running:
            return false
        }
    }

    private func systemNotificationTitle(for attention: WorklaneAttentionSummary) -> String {
        let title = WorklaneContextFormatter.trimmed(attention.statusText)
        if let title, !title.isEmpty {
            return title
        }

        switch attention.state {
        case .needsInput:
            return attention.interactionLabel ?? "Needs input"
        case .ready:
            return "Agent ready"
        case .unresolvedStop:
            return "Stopped early"
        case .running:
            return "Running"
        }
    }

    private func systemNotificationSoundName(for state: WorklaneAttentionState) -> String {
        switch state {
        case .needsInput:
            return configStore?.current.notifications.soundName ?? ""
        case .ready, .unresolvedStop, .running:
            return ""
        }
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

    func add(
        identifier: String,
        title: String,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "agent-attention"
        content.threadIdentifier = worklaneID
        content.userInfo = ["windowID": windowID, "worklaneID": worklaneID, "paneID": paneID]
        content.sound = resolvedNotificationSound(for: soundName)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
