import XCTest
@testable import Zentty

final class MenuBarFleetSummaryTests: XCTestCase {
    func test_from_counts_fleet_states() {
        let snapshots = [
            snapshot(fleetState: .waiting),
            snapshot(fleetState: .waiting),
            snapshot(fleetState: .active),
            snapshot(fleetState: .idle),
        ]

        let summary = MenuBarFleetSummary.from(snapshots: snapshots)

        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertEqual(summary.activeCount, 1)
        XCTAssertEqual(summary.idleCount, 1)
        XCTAssertEqual(summary.totalCount, 4)
    }

    func test_sectionTitles_collapse_precise_states_into_three_buckets() {
        let summary = MenuBarFleetSummary(
            waitingCount: 2,
            stoppedCount: 1,
            compactingCount: 1,
            activeCount: 3,
            idleCount: 4
        )

        XCTAssertEqual(summary.sectionTitle(for: .waiting), "Waiting (3)")
        XCTAssertEqual(summary.sectionTitle(for: .active), "Running (4)")
        XCTAssertEqual(summary.sectionTitle(for: .idle), "Idle (4)")
    }

    func test_accessibilityLabel_includes_counts_for_multiple_panes() {
        let summary = MenuBarFleetSummary(
            waitingCount: 2,
            stoppedCount: 0,
            compactingCount: 0,
            activeCount: 1,
            idleCount: 0
        )

        XCTAssertEqual(
            summary.accessibilityLabel(fleetState: .waiting, hasAgentPanes: true),
            "Agent status: waiting for input. 2 waiting, 1 running"
        )
    }

    private func snapshot(fleetState: MenuBarFleetState) -> MenuBarPaneSnapshot {
        MenuBarPaneSnapshot(
            windowID: WindowID("win"),
            windowTitle: "Window",
            worklaneID: WorklaneID("wl"),
            paneID: PaneID("pn"),
            agentTool: .claudeCode,
            primaryText: "Agent",
            contextText: nil,
            statusLabel: fleetState.menuStatusLabel(),
            attentionState: fleetState.menuAttentionState,
            fleetState: fleetState,
            updatedAt: Date(timeIntervalSince1970: 0),
            taskProgress: nil,
            sortPriority: fleetState.priority
        )
    }
}
