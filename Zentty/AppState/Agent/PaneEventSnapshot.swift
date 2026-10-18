import Foundation

/// The slice of workspace state the `zentty events` stream reports on,
/// captured across every window. Two snapshots diff into the events that
/// happened between them, which keeps event derivation pure and lets the
/// monitor coalesce bursts of store changes into one comparison.
struct PaneEventSnapshot: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        var windowID: String
        var worklaneID: String
        var agent: String?
        var phase: String?
        var interaction: String?
        var attention: String?
    }

    struct Worklane: Equatable, Sendable {
        var windowID: String
        var focusedPaneID: String?
        /// Whether this is the worklane its window is showing.
        var isActive = false
    }

    var worklaneOrder: [String] = []
    var worklanes: [String: Worklane] = [:]
    var paneOrder: [String] = []
    var panes: [String: Pane] = [:]

    static let empty = PaneEventSnapshot()

    mutating func insert(worklaneID: String, _ worklane: Worklane) {
        if worklanes.updateValue(worklane, forKey: worklaneID) == nil {
            worklaneOrder.append(worklaneID)
        }
    }

    mutating func insert(paneID: String, _ pane: Pane) {
        if panes.updateValue(pane, forKey: paneID) == nil {
            paneOrder.append(paneID)
        }
    }
}

extension PaneEventSnapshot {
    /// Builds a snapshot from each window's worklanes, in window order.
    static func make(
        windows: [(windowID: WindowID, activeWorklaneID: WorklaneID?, worklanes: [WorklaneState])]
    ) -> PaneEventSnapshot {
        var snapshot = PaneEventSnapshot()
        for window in windows {
            for worklane in window.worklanes {
                snapshot.insert(
                    worklaneID: worklane.id.rawValue,
                    Worklane(
                        windowID: window.windowID.rawValue,
                        focusedPaneID: worklane.paneStripState.focusedPaneID?.rawValue,
                        isActive: worklane.id == window.activeWorklaneID
                    )
                )
                for column in worklane.paneStripState.columns {
                    for pane in column.panes {
                        let presentation = worklane.auxiliaryStateByPaneID[pane.id]?.presentation
                        snapshot.insert(
                            paneID: pane.id.rawValue,
                            paneEntry(
                                windowID: window.windowID,
                                worklaneID: worklane.id,
                                presentation: presentation
                            )
                        )
                    }
                }
            }
        }
        return snapshot
    }

    static func paneEntry(
        windowID: WindowID,
        worklaneID: WorklaneID,
        presentation: PanePresentationState?
    ) -> Pane {
        guard let presentation, let tool = presentation.recognizedTool else {
            return Pane(windowID: windowID.rawValue, worklaneID: worklaneID.rawValue)
        }
        return Pane(
            windowID: windowID.rawValue,
            worklaneID: worklaneID.rawValue,
            agent: tool.displayName,
            phase: presentation.runtimePhase.eventName,
            interaction: presentation.runtimePhase == .needsInput ? presentation.interactionKind?.rawValue : nil,
            attention: attentionName(for: presentation)
        )
    }

    /// The reason a pane is asking to be looked at, if any. Mirrors the
    /// sidebar attention states, minus plain `running`.
    static func attentionName(for presentation: PanePresentationState) -> String? {
        if presentation.isReady {
            return "ready"
        }
        if presentation.isCheckBack {
            return "check-back"
        }
        switch presentation.runtimePhase {
        case .needsInput:
            return "needs-input"
        case .unresolvedStop:
            return "unresolved-stop"
        case .idle, .starting, .running:
            return nil
        }
    }

    /// Events that turn `old` into `new`, in a stable order: creations,
    /// then per-pane changes, then focus and worklane switches, then
    /// closures.
    ///
    /// `pane.focused` follows each worklane's own focused pane, background
    /// worklanes included. `worklane.activated` reports a window switching
    /// to another worklane; together they say which pane a window shows.
    static func diff(from old: PaneEventSnapshot, to new: PaneEventSnapshot) -> [PaneEvent] {
        var events: [PaneEvent] = []

        for worklaneID in new.worklaneOrder where old.worklanes[worklaneID] == nil {
            events.append(PaneEvent(
                type: .worklaneCreated,
                window: new.worklanes[worklaneID]?.windowID,
                worklane: worklaneID
            ))
        }

        for paneID in new.paneOrder {
            guard let pane = new.panes[paneID] else { continue }
            guard let previous = old.panes[paneID] else {
                events.append(PaneEvent(type: .paneCreated, window: pane.windowID, worklane: pane.worklaneID, pane: paneID))
                events += agentEvents(paneID: paneID, previous: Pane(windowID: pane.windowID, worklaneID: pane.worklaneID), current: pane)
                continue
            }
            if previous.worklaneID != pane.worklaneID || previous.windowID != pane.windowID {
                events.append(PaneEvent(
                    type: .paneMoved,
                    window: pane.windowID,
                    worklane: pane.worklaneID,
                    pane: paneID,
                    fromWorklane: previous.worklaneID
                ))
            }
            events += agentEvents(paneID: paneID, previous: previous, current: pane)
        }

        for worklaneID in new.worklaneOrder {
            guard let worklane = new.worklanes[worklaneID],
                  let focusedPaneID = worklane.focusedPaneID,
                  old.worklanes[worklaneID]?.focusedPaneID != focusedPaneID
            else { continue }
            events.append(PaneEvent(type: .paneFocused, window: worklane.windowID, worklane: worklaneID, pane: focusedPaneID))
        }

        for worklaneID in new.worklaneOrder {
            guard let worklane = new.worklanes[worklaneID],
                  worklane.isActive,
                  old.worklanes[worklaneID]?.isActive != true
            else { continue }
            events.append(PaneEvent(
                type: .worklaneActivated,
                window: worklane.windowID,
                worklane: worklaneID,
                pane: worklane.focusedPaneID
            ))
        }

        for paneID in old.paneOrder where new.panes[paneID] == nil {
            guard let pane = old.panes[paneID] else { continue }
            if pane.attention != nil {
                events.append(PaneEvent(
                    type: .attentionCleared,
                    window: pane.windowID,
                    worklane: pane.worklaneID,
                    pane: paneID,
                    agent: pane.agent,
                    previousAttention: pane.attention
                ))
            }
            events.append(PaneEvent(type: .paneClosed, window: pane.windowID, worklane: pane.worklaneID, pane: paneID))
        }

        for worklaneID in old.worklaneOrder where new.worklanes[worklaneID] == nil {
            events.append(PaneEvent(
                type: .worklaneClosed,
                window: old.worklanes[worklaneID]?.windowID,
                worklane: worklaneID
            ))
        }

        return events
    }

    private static func agentEvents(paneID: String, previous: Pane, current: Pane) -> [PaneEvent] {
        var events: [PaneEvent] = []
        let agentChanged = previous.agent != current.agent
            || previous.phase != current.phase
            || previous.interaction != current.interaction
        if agentChanged, previous.agent != nil || current.agent != nil {
            events.append(PaneEvent(
                type: .agentPhase,
                window: current.windowID,
                worklane: current.worklaneID,
                pane: paneID,
                agent: current.agent ?? previous.agent,
                phase: current.agent == nil ? "exited" : current.phase,
                previousPhase: previous.agent == nil ? nil : previous.phase,
                interaction: current.interaction
            ))
        }

        if previous.attention != current.attention {
            if let attention = current.attention {
                events.append(PaneEvent(
                    type: .attentionRaised,
                    window: current.windowID,
                    worklane: current.worklaneID,
                    pane: paneID,
                    agent: current.agent ?? previous.agent,
                    interaction: current.interaction,
                    attention: attention,
                    previousAttention: previous.attention
                ))
            } else {
                events.append(PaneEvent(
                    type: .attentionCleared,
                    window: current.windowID,
                    worklane: current.worklaneID,
                    pane: paneID,
                    agent: current.agent ?? previous.agent,
                    previousAttention: previous.attention
                ))
            }
        }
        return events
    }
}

extension PanePresentationPhase {
    /// Stable, CLI-facing phase name (`needs-input`, not `needsInput`).
    var eventName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .needsInput: "needs-input"
        case .unresolvedStop: "unresolved-stop"
        }
    }
}
