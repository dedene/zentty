import XCTest

@testable import Zentty

final class SidebarWorklaneRowRenderPlanTests: XCTestCase {
    func test_presentation_resolves_top_level_status_once() {
        let summary = WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-api"),
            badgeText: "1",
            primaryText: "API",
            statusText: nil,
            attentionState: .needsInput,
            interactionKind: .approval,
            interactionLabel: "Editing",
            interactionSymbolName: "pencil",
            isActive: true
        )

        let presentation = SidebarWorklaneRowRenderPlan(summary: summary, availableWidth: 280)

        XCTAssertEqual(presentation.statusDisplayText, "Editing")
        XCTAssertEqual(presentation.statusSymbolName, "pencil")
        XCTAssertEqual(presentation.statusLineCount, 1)
    }

    func test_presentation_changes_pane_mode_with_width() {
        let paneRow = WorklaneSidebarPaneRow(
            paneID: PaneID("pane-api"),
            primaryText: "Very long pane title that cannot fit with trailing branch",
            trailingText: "feature/sidebar-presentation",
            detailText: nil,
            statusText: "Running",
            attentionState: .running,
            isFocused: true,
            isWorking: true
        )
        let summary = WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-api"),
            badgeText: "1",
            primaryText: "API",
            paneRows: [paneRow],
            isActive: true
        )

        let wide = SidebarWorklaneRowRenderPlan(summary: summary, availableWidth: 900)
        let narrow = SidebarWorklaneRowRenderPlan(summary: summary, availableWidth: 220)

        XCTAssertEqual(wide.paneRows.first?.presentationMode, .inline)
        XCTAssertEqual(narrow.paneRows.first?.presentationMode, .adaptive)
        XCTAssertFalse(wide.paneRows.first?.statusTrailingLayout.isVisible ?? true)
        XCTAssertEqual(narrow.paneRows.first?.statusDisplayText, "Running")
        XCTAssertEqual(narrow.paneRows.first?.statusSymbolName, "")
    }

    func test_presentation_carries_pane_server_ports() throws {
        let paneRow = WorklaneSidebarPaneRow(
            paneID: PaneID("pane-api"),
            primaryText: "api",
            trailingText: nil,
            detailText: nil,
            statusText: "Running",
            attentionState: .running,
            isFocused: true,
            isWorking: true,
            serverPorts: [
                WorklaneSidebarServerPort(serverID: "server-3000", port: 3000),
                WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
            ]
        )
        let summary = WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-api"),
            badgeText: "1",
            primaryText: "API",
            paneRows: [paneRow],
            isActive: true
        )

        let presentation = SidebarWorklaneRowRenderPlan(summary: summary, availableWidth: 280)

        XCTAssertEqual(
            presentation.paneRows.first?.serverPorts.map(\.port),
            [3000, 5173]
        )
    }
}
