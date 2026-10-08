import Foundation

/// Visual status of an agent pane as shown in the menu-bar dropdown.
///
/// Derived from a pane's ``MenuBarFleetState`` plus its
/// ``WorklaneAttentionState``. The only state the fleet state cannot express on
/// its own is "ready" — an idle pane that has just finished and is awaiting the
/// user's next move — which we surface distinctly (a blue pill) rather than
/// letting it read as plain idle.
enum MenuBarStatusKind: String, CaseIterable, Equatable, Sendable {
    case running
    case compacting
    case needsInput
    case stoppedEarly
    case ready
    case checkBack
    case idle

    /// Resolve the status kind from the two fields the snapshot already carries.
    ///
    /// `fleetState` is authoritative for everything except distinguishing
    /// "ready" and "check back" from "idle": all are `.idle`, separated only by
    /// the pane's `attentionState`.
    static func resolve(
        fleetState: MenuBarFleetState,
        attentionState: WorklaneAttentionState?
    ) -> MenuBarStatusKind {
        switch fleetState {
        case .active:
            return .running
        case .compacting:
            return .compacting
        case .waiting:
            return .needsInput
        case .stopped:
            return .stoppedEarly
        case .idle:
            switch attentionState {
            case .ready:
                return .ready
            case .checkBack:
                return .checkBack
            default:
                return .idle
            }
        }
    }

    init(snapshot: MenuBarPaneSnapshot) {
        self = MenuBarStatusKind.resolve(
            fleetState: snapshot.fleetState,
            attentionState: snapshot.attentionState
        )
    }
}
