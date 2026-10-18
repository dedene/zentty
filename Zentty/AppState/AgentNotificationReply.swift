import Foundation
import UserNotifications

/// Identifiers shared by agent attention notifications and the delegate that
/// answers them.
enum AgentNotificationIdentifiers {
    enum Category {
        static let attention = "agent-attention"
        static let attentionWithReply = "agent-attention-reply"
    }

    enum Action {
        static let jump = "JUMP"
        static let dismiss = "DISMISS"
        static let reply = "REPLY"
    }

    enum UserInfoKey {
        static let windowID = "windowID"
        static let worklaneID = "worklaneID"
        static let paneID = "paneID"
        static let replyToken = "replyToken"
    }
}

/// Decides which agent notifications can be answered with typed text.
///
/// Only a finished turn qualifies: the agent sits at its own input prompt and
/// takes free text. Every needs-input prompt keeps "Jump to Pane": approvals,
/// decisions and sign-in expect keystrokes in the agent's interface, and an
/// open question can't be told apart from a picker reliably (several agents
/// report pickers and approval menus as questions), so a typed reply plus
/// Return could pick an option the user never chose.
///
/// The pane's shell must not be back at its prompt either. A finished turn can
/// outlive the agent process (an agent promoted to ready when its command
/// exits, or one the user quit), and a reply typed there would run as a shell
/// command.
enum AgentNotificationReplyPolicy {
    static func acceptsTypedReply(
        state: WorklaneAttentionState,
        shellActivityState: PaneShellActivityState?
    ) -> Bool {
        state == .ready && !isShellAtPrompt(shellActivityState)
    }

    static func offersReply(
        state: WorklaneAttentionState,
        shellActivityState: PaneShellActivityState?,
        isInlineReplyEnabled: Bool
    ) -> Bool {
        isInlineReplyEnabled && acceptsTypedReply(state: state, shellActivityState: shellActivityState)
    }

    /// `.unknown` means no shell integration report, e.g. a pane whose root
    /// process is the agent itself; only a reported prompt counts.
    static func isShellAtPrompt(_ shellActivityState: PaneShellActivityState?) -> Bool {
        shellActivityState == .promptIdle
    }

    static func categoryIdentifier(offersReply: Bool) -> String {
        offersReply
            ? AgentNotificationIdentifiers.Category.attentionWithReply
            : AgentNotificationIdentifiers.Category.attention
    }

    static func makeCategories() -> Set<UNNotificationCategory> {
        let jumpAction = UNNotificationAction(
            identifier: AgentNotificationIdentifiers.Action.jump,
            title: "Jump to Pane",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: AgentNotificationIdentifiers.Action.dismiss,
            title: "Dismiss",
            options: []
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: AgentNotificationIdentifiers.Action.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to agent"
        )
        return [
            UNNotificationCategory(
                identifier: AgentNotificationIdentifiers.Category.attention,
                actions: [jumpAction, dismissAction],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: AgentNotificationIdentifiers.Category.attentionWithReply,
                actions: [replyAction, jumpAction, dismissAction],
                intentIdentifiers: []
            ),
        ]
    }
}

/// Whether a reply typed into a notification may still be typed into its pane.
enum AgentNotificationReplyGuard {
    enum StaleReason: String, Equatable, Sendable {
        case paneGone = "pane-gone"
        case replyDisabled = "reply-disabled"
        case missingToken = "missing-token"
        case agentGone = "agent-gone"
        case agentRunning = "agent-running"
        case agentExited = "agent-exited"
        case notReplyable = "not-replyable"
        case attentionChanged = "attention-changed"
    }

    enum Decision: Equatable, Sendable {
        case deliver
        case stale(StaleReason)
    }

    /// - Parameters:
    ///   - isInlineReplyEnabled: the setting right now. Banners raised before
    ///     it was turned off still carry a Reply field, so it is checked again.
    ///   - notificationToken: the token the notification was raised with.
    ///   - currentToken: the pane's token right now; it rotates on every
    ///     attention change, so a new turn or prompt invalidates old banners.
    ///   - currentState: the pane's live attention state, nil when no agent
    ///     is recognized in the pane anymore.
    ///   - shellActivityState: the pane's shell, `.promptIdle` once the agent
    ///     command has exited.
    static func decide(
        paneExists: Bool,
        isInlineReplyEnabled: Bool,
        notificationToken: String?,
        currentToken: String?,
        currentState: WorklaneAttentionState?,
        shellActivityState: PaneShellActivityState?
    ) -> Decision {
        guard paneExists else {
            return .stale(.paneGone)
        }
        guard isInlineReplyEnabled else {
            return .stale(.replyDisabled)
        }
        guard let notificationToken, !notificationToken.isEmpty else {
            return .stale(.missingToken)
        }
        guard let currentState else {
            return .stale(.agentGone)
        }
        guard currentState != .running else {
            return .stale(.agentRunning)
        }
        guard !AgentNotificationReplyPolicy.isShellAtPrompt(shellActivityState) else {
            return .stale(.agentExited)
        }
        guard AgentNotificationReplyPolicy.acceptsTypedReply(
            state: currentState,
            shellActivityState: shellActivityState
        ) else {
            return .stale(.notReplyable)
        }
        guard currentToken == notificationToken else {
            return .stale(.attentionChanged)
        }
        return .deliver
    }

    /// Reads the pane's live attention and shell state from `worklane`.
    static func decide(
        worklane: WorklaneState?,
        paneID: PaneID,
        paneExists: Bool,
        isInlineReplyEnabled: Bool,
        notificationToken: String?,
        currentToken: String?
    ) -> Decision {
        let attention = worklane.flatMap { worklane in
            WorklaneAttentionSummaryBuilder.summaries(for: worklane).first { $0.paneID == paneID }
        }
        return decide(
            paneExists: paneExists && worklane != nil,
            isInlineReplyEnabled: isInlineReplyEnabled,
            notificationToken: notificationToken,
            currentToken: currentToken,
            currentState: attention?.state,
            shellActivityState: worklane?.auxiliaryStateByPaneID[paneID]?.shellActivityState
        )
    }
}

/// Turns notification reply text into what is pasted into the pane.
///
/// The result is one line, pasted once and followed by a single Return key.
/// Line breaks become spaces: libghostty can't report whether the agent turned
/// on bracketed paste, and without it the terminal turns every pasted newline
/// into Enter, which would submit a multi-line reply line by line.
enum AgentNotificationReplyText {
    static func terminalPaste(for reply: String) -> String? {
        let normalizedNewlines = reply
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        let scalars = normalizedNewlines.unicodeScalars.filter { scalar in
            scalar == "\n" || !isControl(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// C0 controls, DEL and C1 controls: none belong in a typed reply. ESC in
    /// particular could end a bracketed paste early, and a tab could trigger
    /// completion in a prompt that reads keys.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        default:
            return false
        }
    }
}

enum AgentNotificationReplyOutcome: Equatable, Sendable {
    case delivered(worklaneID: WorklaneID)
    case emptyReply
    case stale(AgentNotificationReplyGuard.StaleReason)
}
