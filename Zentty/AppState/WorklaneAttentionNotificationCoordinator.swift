import AppKit
import Foundation
import UserNotifications
import os

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
    private enum Runtime {
        static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private struct NeedsInputNotificationContent {
        let systemTitle: String
        let panelStatusText: String
        let askPreview: String
        let locationText: String?

        var systemBody: String {
            switch (locationText, WorklaneContextFormatter.trimmed(askPreview)) {
            case let (location?, ask?):
                return "\(location) — \(ask)"
            case let (location?, nil):
                return location
            case let (nil, ask?):
                return ask
            case (nil, nil):
                return ""
            }
        }
    }

    private struct PaneKey: Hashable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private let center: any WorklaneAttentionUserNotificationCenter
    private let notificationStore: NotificationStore
    private let configStore: AppConfigStore?
    private let logger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneAttentionNotifications")
    private var lastSeenStates: [PaneKey: WorklaneAttentionState] = [:]
    private var lastSeenActiveViews: [PaneKey: Bool] = [:]
    private var lastSeenNotificationSignatures: [PaneKey: String] = [:]
    private var loggedGenericNeedsInputMessages = Set<String>()

    init(
        center: (any WorklaneAttentionUserNotificationCenter)? = nil,
        notificationStore: NotificationStore,
        configStore: AppConfigStore? = nil
    ) {
        self.center = center ?? Self.makeDefaultNotificationCenter()
        self.notificationStore = notificationStore
        self.configStore = configStore
        self.center.requestAuthorizationIfNeeded()
    }

    private static func makeDefaultNotificationCenter() -> any WorklaneAttentionUserNotificationCenter {
        if Runtime.isRunningTests {
            return NoOpWorklaneAttentionUserNotificationCenter()
        }
        return WorklaneAttentionUNCenter()
    }

    func update(
        windowID: WindowID,
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [PaneKey: WorklaneAttentionState] = [:]
        var nextSeenActiveViews: [PaneKey: Bool] = [:]
        var nextSeenNotificationSignatures: [PaneKey: String] = [:]
        var visitedPaneKeys = Set<PaneKey>()

        for worklane in worklanes {
            for attention in WorklaneAttentionSummaryBuilder.summaries(for: worklane) {
                let key = PaneKey(worklaneID: worklane.id, paneID: attention.paneID)
                let paneContext = worklane.paneContext(for: attention.paneID)
                let needsInputContent = attention.state == .needsInput
                    ? needsInputContent(for: attention, paneContext: paneContext)
                    : nil
                let notificationSignature = notificationSignature(
                    for: attention,
                    needsInputContent: needsInputContent
                )
                visitedPaneKeys.insert(key)
                nextSeenStates[key] = attention.state
                nextSeenNotificationSignatures[key] = notificationSignature
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
                let contentChanged = attention.state == .needsInput
                    && lastSeenNotificationSignatures[key] != notificationSignature
                guard stateChanged || contentChanged else {
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
                        statusText: needsInputContent?.panelStatusText ?? systemNotificationTitle(for: attention),
                        primaryText: needsInputContent?.askPreview ?? systemNotificationBody(for: attention, in: worklane),
                        locationText: needsInputContent?.locationText,
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
                    identifier: "\(windowID.rawValue)-\(worklane.id.rawValue)-\(attention.paneID.rawValue)-\(attention.state.rawValue)-\(notificationSignature.hashValue)",
                    title: needsInputContent?.systemTitle ?? systemNotificationTitle(for: attention),
                    body: needsInputContent?.systemBody ?? systemNotificationBody(for: attention, in: worklane),
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
        lastSeenNotificationSignatures = nextSeenNotificationSignatures
    }

    private func needsInputContent(
        for attention: WorklaneAttentionSummary,
        paneContext: WorklanePaneContext?
    ) -> NeedsInputNotificationContent {
        let interactionKind = attention.interactionKind ?? .genericInput
        logUnclassifiedNeedsInputIfNeeded(
            interactionKind: interactionKind,
            paneContext: paneContext
        )
        let actionText = needsInputActionText(for: interactionKind)
        let askPreview = meaningfulAskPreview(
            for: attention,
            interactionKind: interactionKind,
            paneContext: paneContext
        ) ?? fallbackAskPreview(for: interactionKind)

        return NeedsInputNotificationContent(
            systemTitle: "\(attention.tool.displayName) \(actionText)",
            panelStatusText: actionText,
            askPreview: askPreview,
            locationText: paneContext.flatMap { compactLocationText(for: $0.presentation) }
        )
    }

    private func meaningfulAskPreview(
        for attention: WorklaneAttentionSummary,
        interactionKind: PaneInteractionKind,
        paneContext: WorklanePaneContext?
    ) -> String? {
        guard let paneContext else {
            return nil
        }

        let raw = paneContext.auxiliaryState?.raw
        let presentation = paneContext.presentation
        let candidates = [
            WorklaneContextFormatter.trimmed(raw?.agentStatus?.text),
            WorklaneContextFormatter.trimmed(raw?.lastDesktopNotificationText),
            fallbackIdentityText(for: presentation, tool: attention.tool),
        ]

        return candidates.compactMap { $0 }.first {
            isMeaningfulAskText(
                $0,
                tool: attention.tool,
                interactionKind: interactionKind
            )
        }
    }

    private func isMeaningfulAskText(
        _ text: String,
        tool: AgentTool,
        interactionKind: PaneInteractionKind
    ) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        if AgentInteractionClassifier.isGenericNeedsInputContent(normalized) {
            return false
        }

        if interactionKind == .approval,
           AgentInteractionClassifier.isGenericApprovalMessage(normalized) {
            return false
        }

        let lowered = normalized.lowercased()
        let genericPhrases = Set([
            interactionKind.defaultLabel.lowercased(),
            needsInputActionText(for: interactionKind),
            "\(tool.displayName.lowercased()) \(needsInputActionText(for: interactionKind))",
            "\(tool.displayName.lowercased()) needs input",
            "\(tool.displayName.lowercased()) needs your input",
            "\(tool.displayName.lowercased()) needs your attention",
        ])

        return !genericPhrases.contains(lowered)
    }

    private func fallbackIdentityText(
        for presentation: PanePresentationState,
        tool: AgentTool
    ) -> String? {
        let candidates = [
            WorklaneContextFormatter.trimmed(presentation.rememberedTitle),
            WorklaneContextFormatter.trimmed(presentation.identityText),
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }

            let lowered = candidate.lowercased()
            if lowered == "shell" || lowered == tool.displayName.lowercased() {
                continue
            }

            if candidate.contains("/") || candidate.hasPrefix("~") {
                continue
            }

            return candidate
        }

        return nil
    }

    private func compactLocationText(for presentation: PanePresentationState) -> String? {
        if presentation.isRemoteShell {
            return WorklaneContextFormatter.trimmed(presentation.remotePathLabel)
                ?? WorklaneContextFormatter.trimmed(presentation.remoteLocationLabel)
        }

        guard let cwd = standardizedPath(presentation.cwd) else {
            return nil
        }

        if let repoRoot = standardizedPath(presentation.repoRoot) {
            let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
            if cwd == repoRoot {
                return repoName
            }

            let prefix = repoRoot.hasSuffix("/") ? repoRoot : repoRoot + "/"
            if cwd.hasPrefix(prefix) {
                let relativePath = String(cwd.dropFirst(prefix.count))
                return relativePath.isEmpty ? repoName : "\(repoName) • \(relativePath)"
            }
        }

        if let homeRelative = compactHomeRelativePath(cwd) {
            return homeRelative
        }

        return WorklaneContextFormatter.compactSidebarPath(cwd, minimumSegments: 2)
            ?? URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func standardizedPath(_ path: String?) -> String? {
        guard let trimmedPath = WorklaneContextFormatter.trimmed(path) else {
            return nil
        }

        return URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
    }

    private func compactHomeRelativePath(_ path: String) -> String? {
        guard let homeRelative = WorklaneContextFormatter.homeRelativePath(path) else {
            return nil
        }

        guard homeRelative != "~", homeRelative.hasPrefix("~/") else {
            return homeRelative
        }

        let components = homeRelative.dropFirst(2).split(separator: "/").map(String.init)
        guard components.count > 2 else {
            return homeRelative
        }

        return "~/…/" + components.suffix(2).joined(separator: "/")
    }

    private func needsInputActionText(for interactionKind: PaneInteractionKind) -> String {
        switch interactionKind {
        case .decision:
            return "requires a decision"
        case .approval:
            return "needs approval"
        case .question:
            return "has a question"
        case .auth:
            return "needs sign-in"
        case .genericInput:
            return "needs input"
        }
    }

    private func fallbackAskPreview(for interactionKind: PaneInteractionKind) -> String {
        switch interactionKind {
        case .decision:
            return "Decision required."
        case .approval:
            return "Approval required."
        case .question:
            return "Question pending."
        case .auth:
            return "Sign-in required."
        case .genericInput:
            return "Input required."
        }
    }

    private func logUnclassifiedNeedsInputIfNeeded(
        interactionKind: PaneInteractionKind,
        paneContext: WorklanePaneContext?
    ) {
        guard interactionKind == .genericInput else {
            return
        }

        let raw = paneContext?.auxiliaryState?.raw
        let candidates = [
            WorklaneContextFormatter.trimmed(raw?.agentStatus?.text),
            WorklaneContextFormatter.trimmed(raw?.lastDesktopNotificationText),
        ]

        guard let message = candidates.compactMap({ $0 }).first else {
            return
        }

        guard loggedGenericNeedsInputMessages.insert(message).inserted else {
            return
        }

        logger.info("Generic needs-input notification text: \(message, privacy: .public)")
    }

    private func notificationSignature(
        for attention: WorklaneAttentionSummary,
        needsInputContent: NeedsInputNotificationContent?
    ) -> String {
        if let needsInputContent {
            return [
                attention.state.rawValue,
                needsInputContent.systemTitle,
                needsInputContent.askPreview,
                needsInputContent.locationText ?? "",
            ].joined(separator: "\u{1F}")
        }

        return [
            attention.state.rawValue,
            attention.statusText,
            attention.primaryText,
            attention.contextText,
        ].joined(separator: "\u{1F}")
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
        let remotePrimaryText = worklane.paneContext(for: attention.paneID)
            .flatMap { paneContext -> String? in
                guard paneContext.presentation.isRemoteShell else {
                    return nil
                }
                return WorklaneContextFormatter.trimmed(attention.primaryText)
            }

        switch attention.state {
        case .needsInput:
            return attention.primaryText
        case .unresolvedStop:
            if let remotePrimaryText {
                return remotePrimaryText
            }
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
            if let remotePrimaryText {
                return remotePrimaryText
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
private final class NoOpWorklaneAttentionUserNotificationCenter: WorklaneAttentionUserNotificationCenter {
    func requestAuthorizationIfNeeded() {}

    func add(
        identifier: String,
        title: String,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String
    ) {}
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
