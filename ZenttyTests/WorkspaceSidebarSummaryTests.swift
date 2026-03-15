import XCTest
@testable import Zentty

final class WorkspaceSidebarSummaryTests: XCTestCase {
    func test_builder_prefers_terminal_title_and_compacts_context_line() {
        let paneID = PaneID("workspace-main-shell")
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "Claude Code",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "main"
                )
            ]
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: true)

        XCTAssertEqual(summary.title, "MAIN")
        XCTAssertEqual(summary.summaryText, "Claude Code")
        XCTAssertEqual(summary.detailText, "project • main")
        XCTAssertEqual(summary.paneCountText, "1 pane")
        XCTAssertEqual(summary.badgeText, "M")
        XCTAssertTrue(summary.isActive)
    }

    func test_builder_falls_back_to_focused_pane_title_and_pane_count_when_metadata_missing() {
        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: PaneID("workspace-main-shell"), title: "shell"),
                    PaneState(id: PaneID("workspace-main-pane-1"), title: "pane 1"),
                ],
                focusedPaneID: PaneID("workspace-main-pane-1")
            )
        )

        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: false)

        XCTAssertEqual(summary.summaryText, "pane 1")
        XCTAssertEqual(summary.detailText, "2 panes")
        XCTAssertEqual(summary.paneCountText, "2 panes")
        XCTAssertFalse(summary.isActive)
    }
}
