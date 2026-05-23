import Foundation

struct MenuBarFleetSummary: Equatable, Sendable {
    let waitingCount: Int
    let stoppedCount: Int
    let compactingCount: Int
    let activeCount: Int
    let idleCount: Int

    var totalCount: Int {
        waitingCount + stoppedCount + compactingCount + activeCount + idleCount
    }

    func sectionCount(for fleetState: MenuBarFleetState) -> Int {
        switch fleetState {
        case .waiting, .stopped:
            return waitingCount + stoppedCount
        case .compacting, .active:
            return compactingCount + activeCount
        case .idle:
            return idleCount
        }
    }

    func sectionTitle(for fleetState: MenuBarFleetState) -> String {
        let count = sectionCount(for: fleetState)
        switch fleetState {
        case .waiting, .stopped:
            return "Waiting (\(count))"
        case .compacting, .active:
            return "Running (\(count))"
        case .idle:
            return "Idle (\(count))"
        }
    }

    static func from(snapshots: [MenuBarPaneSnapshot]) -> MenuBarFleetSummary {
        var waiting = 0
        var stopped = 0
        var compacting = 0
        var active = 0
        var idle = 0

        for snapshot in snapshots {
            switch snapshot.fleetState {
            case .waiting:
                waiting += 1
            case .stopped:
                stopped += 1
            case .compacting:
                compacting += 1
            case .active:
                active += 1
            case .idle:
                idle += 1
            }
        }

        return MenuBarFleetSummary(
            waitingCount: waiting,
            stoppedCount: stopped,
            compactingCount: compacting,
            activeCount: active,
            idleCount: idle
        )
    }

    var menuHeaderTitle: String {
        guard totalCount > 0 else {
            return "No agent panes"
        }

        var parts: [String] = []
        if waitingCount > 0 {
            parts.append("\(waitingCount) waiting")
        }
        if stoppedCount > 0 {
            parts.append("\(stoppedCount) stopped")
        }
        if compactingCount > 0 {
            parts.append("\(compactingCount) compacting")
        }
        if activeCount > 0 {
            parts.append("\(activeCount) active")
        }
        if idleCount > 0 {
            parts.append("\(idleCount) idle")
        }

        if parts.isEmpty {
            return "Agent panes"
        }
        return parts.joined(separator: " · ")
    }

    func accessibilityLabel(
        fleetState: MenuBarFleetState,
        hasAgentPanes: Bool
    ) -> String {
        let base = fleetState.accessibilityLabel(hasAgentPanes: hasAgentPanes)
        guard totalCount > 1 else {
            return base
        }

        var detailParts: [String] = []
        if waitingCount > 0 {
            detailParts.append("\(waitingCount) waiting")
        }
        if stoppedCount > 0 {
            detailParts.append("\(stoppedCount) stopped")
        }
        let runningCount = activeCount + compactingCount
        if runningCount > 0 {
            detailParts.append("\(runningCount) running")
        }
        if idleCount > 0 {
            detailParts.append("\(idleCount) idle")
        }

        guard !detailParts.isEmpty else {
            return base
        }
        return "\(base). \(detailParts.joined(separator: ", "))"
    }
}
