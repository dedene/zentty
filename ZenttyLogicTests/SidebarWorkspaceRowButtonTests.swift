import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorkspaceRowButtonTests: XCTestCase {
    func test_working_workspace_row_starts_shimmer_animation() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Running",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary)
                ],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
    }

    func test_idle_workspace_row_stops_existing_shimmer_animation() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Running",
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: nil,
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertFalse(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
    }
}
