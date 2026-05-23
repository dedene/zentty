import XCTest
@testable import Zentty

final class MenuBarStatusPresentationTests: XCTestCase {
    func test_resolve_carries_fleet_state_and_accessibility_label() {
        let summary = MenuBarFleetSummary(
            waitingCount: 1,
            stoppedCount: 0,
            compactingCount: 0,
            activeCount: 0,
            idleCount: 0
        )
        let presentation = MenuBarStatusPresentation.resolve(
            fleetState: .waiting,
            fleetSummary: summary
        )

        XCTAssertEqual(presentation.fleetState, .waiting)
        XCTAssertEqual(presentation.accessibilityLabel, "Agent status: waiting for input")
    }

    func test_idle_accessibility_when_agent_panes_exist() {
        let summary = MenuBarFleetSummary(
            waitingCount: 0,
            stoppedCount: 0,
            compactingCount: 0,
            activeCount: 0,
            idleCount: 2
        )
        let presentation = MenuBarStatusPresentation.resolve(
            fleetState: .idle,
            fleetSummary: summary
        )

        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Agent status: idle. 2 idle"
        )
    }

    func test_idle_accessibility_when_no_agent_panes() {
        let presentation = MenuBarStatusPresentation.resolve(
            fleetState: .idle,
            fleetSummary: MenuBarFleetSummary.from(snapshots: [])
        )

        XCTAssertEqual(presentation.accessibilityLabel, "No agent panes")
    }
}
