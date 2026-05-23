import Foundation

/// Aggregate menu bar status across all agent panes (claude-status style).
enum MenuBarFleetState: Equatable, Sendable {
    case waiting
    case stopped
    case compacting
    case active
    case idle

    /// Lower value = higher urgency for fleet icon and menu sort order.
    var priority: Int {
        switch self {
        case .waiting:
            return 1
        case .stopped:
            return 2
        case .compacting:
            return 3
        case .active:
            return 4
        case .idle:
            return 5
        }
    }

    var menuAttentionState: WorklaneAttentionState? {
        switch self {
        case .waiting:
            return .needsInput
        case .stopped:
            return .unresolvedStop
        case .compacting, .active:
            return .running
        case .idle:
            return nil
        }
    }

    static func aggregate(_ states: [MenuBarFleetState]) -> MenuBarFleetState {
        states.min { $0.priority < $1.priority } ?? .idle
    }

    static func resolve(
        agentStatus: PaneAgentStatus,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> MenuBarFleetState {
        switch agentStatus.state {
        case .needsInput:
            return .waiting
        case .unresolvedStop:
            return .stopped
        case .starting, .running:
            if isCompacting(agentStatus: agentStatus, metadata: metadata, paneTitle: paneTitle) {
                return .compacting
            }
            return .active
        case .idle:
            return .idle
        }
    }

    static func resolve(
        presentation: PanePresentationState,
        agentStatus: PaneAgentStatus?,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> MenuBarFleetState {
        switch presentation.runtimePhase {
        case .needsInput:
            return .waiting
        case .unresolvedStop:
            return .stopped
        case .starting, .running:
            if isCompacting(
                presentation: presentation,
                agentStatus: agentStatus,
                metadata: metadata,
                paneTitle: paneTitle
            ) {
                return .compacting
            }
            return .active
        case .idle:
            return .idle
        }
    }

    static func resolve(
        paneRow: WorklaneSidebarPaneRow?,
        presentation: PanePresentationState,
        agentStatus: PaneAgentStatus?,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> MenuBarFleetState {
        guard let paneRow else {
            return resolve(
                presentation: presentation,
                agentStatus: agentStatus,
                metadata: metadata,
                paneTitle: paneTitle
            )
        }

        switch paneRow.attentionState {
        case .needsInput:
            return .waiting
        case .unresolvedStop:
            return .stopped
        case .running:
            if agentStatus == nil, presentation.runtimePhase == .running {
                return .idle
            }
            return isCompacting(
                paneRow: paneRow,
                presentation: presentation,
                agentStatus: agentStatus,
                metadata: metadata,
                paneTitle: paneTitle
            ) ? .compacting : .active
        case .ready:
            return .idle
        case nil:
            guard paneRow.isWorking else {
                return .idle
            }
            return isCompacting(
                paneRow: paneRow,
                presentation: presentation,
                agentStatus: agentStatus,
                metadata: metadata,
                paneTitle: paneTitle
            ) ? .compacting : .active
        }
    }

    /// Best-effort until hooks expose an explicit compacting lifecycle event.
    private static func isCompacting(
        agentStatus: PaneAgentStatus,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> Bool {
        let haystacks = [
            agentStatus.text,
            metadata?.title,
            paneTitle,
        ]
        for haystack in haystacks {
            guard let lowered = haystack?.lowercased() else { continue }
            if lowered.contains("compact") || lowered.contains("summariz") {
                return true
            }
        }
        return false
    }

    private static func isCompacting(
        presentation: PanePresentationState,
        agentStatus: PaneAgentStatus?,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> Bool {
        let haystacks = [
            presentation.statusText,
            agentStatus?.text,
            metadata?.title,
            paneTitle,
        ]
        for haystack in haystacks {
            guard let lowered = haystack?.lowercased() else { continue }
            if lowered.contains("compact") || lowered.contains("summariz") {
                return true
            }
        }
        return false
    }

    private static func isCompacting(
        paneRow: WorklaneSidebarPaneRow,
        presentation: PanePresentationState,
        agentStatus: PaneAgentStatus?,
        metadata: TerminalMetadata?,
        paneTitle: String?
    ) -> Bool {
        let haystacks = [
            paneRow.statusText,
            presentation.statusText,
            agentStatus?.text,
            metadata?.title,
            paneTitle,
        ]
        for haystack in haystacks {
            guard let lowered = haystack?.lowercased() else { continue }
            if lowered.contains("compact") || lowered.contains("summariz") {
                return true
            }
        }
        return false
    }

    func accessibilityLabel(hasAgentPanes: Bool) -> String {
        switch self {
        case .waiting:
            return "Agent status: waiting for input"
        case .stopped:
            return "Agent status: stopped early"
        case .compacting:
            return "Agent status: compacting context"
        case .active:
            return "Agent status: active"
        case .idle:
            return hasAgentPanes ? "Agent status: idle" : "No agent panes"
        }
    }

    func menuStatusLabel(interactionKind: PaneAgentInteractionKind = .none) -> String {
        switch self {
        case .waiting:
            if interactionKind.requiresHumanAttention {
                return interactionKind.statusLabel
            }
            return "Waiting"
        case .stopped:
            return "Stopped early"
        case .compacting:
            return "Compacting"
        case .active:
            return "Running"
        case .idle:
            return "Idle"
        }
    }
}
