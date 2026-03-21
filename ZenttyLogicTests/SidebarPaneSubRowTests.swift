import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarPaneSubRowTests: XCTestCase {
    func test_working_row_starts_shimmer_animation() {
        let row = PaneSubRow(paneID: PaneID("workspace-main-agent"), reducedMotionProvider: { false })
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 28)

        row.configure(
            with: PaneSidebarSummary(
                paneID: PaneID("workspace-main-agent"),
                workspaceID: WorkspaceID("workspace-main"),
                primaryText: "Claude Code",
                attentionState: .running,
                gitContext: "feature/sidebar",
                isFocused: false,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
    }

    func test_idle_row_stops_existing_shimmer_animation() {
        let row = PaneSubRow(paneID: PaneID("workspace-main-agent"), reducedMotionProvider: { false })
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 28)

        row.configure(
            with: PaneSidebarSummary(
                paneID: PaneID("workspace-main-agent"),
                workspaceID: WorkspaceID("workspace-main"),
                primaryText: "Claude Code",
                attentionState: .running,
                gitContext: "",
                isFocused: false,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil)
        )
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)

        row.configure(
            with: PaneSidebarSummary(
                paneID: PaneID("workspace-main-agent"),
                workspaceID: WorkspaceID("workspace-main"),
                primaryText: "Claude Code",
                attentionState: .completed,
                gitContext: "",
                isFocused: false,
                isWorking: false
            ),
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertFalse(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
    }

    func test_reduced_motion_uses_static_working_state_without_shimmer_animation() {
        let row = PaneSubRow(paneID: PaneID("workspace-main-agent"), reducedMotionProvider: { true })
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 28)

        row.configure(
            with: PaneSidebarSummary(
                paneID: PaneID("workspace-main-agent"),
                workspaceID: WorkspaceID("workspace-main"),
                primaryText: "Claude Code",
                attentionState: nil,
                gitContext: "",
                isFocused: false,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
    }
}
