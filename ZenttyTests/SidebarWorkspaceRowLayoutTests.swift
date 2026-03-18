import XCTest
@testable import Zentty

@MainActor
final class SidebarWorkspaceRowLayoutTests: XCTestCase {
    private let metrics = WorkspaceRowLayoutMetrics.sidebar

    func test_content_aware_heights() {
        let primaryOnly = metrics.height(for: [.primary])
        let primaryContext = metrics.height(for: [.primary, .context])
        let primaryStatusContext = metrics.height(for: [.primary, .status, .context])

        XCTAssertEqual(primaryOnly, 34, accuracy: 0.001)
        XCTAssertEqual(primaryContext, 42, accuracy: 0.001)
        XCTAssertEqual(primaryStatusContext, 50, accuracy: 0.001)
    }

    func test_sidebar_row_height_is_stable_across_width_changes_when_labels_truncate() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                WorkspaceSidebarNode(
                    header: WorkspaceHeaderSummary(
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "Claude Code working on a very long branch name for layout checks",
                        paneCount: 1,
                        attentionState: nil,
                        statusText: "Needs input from the operator immediately",
                        gitContext: "~/Development/Personal/zentty/a/really/long/path/that/should/truncate",
                        artifactLink: WorkspaceArtifactLink(
                            kind: .pullRequest,
                            label: "PR #4242 with a long label",
                            url: URL(string: "https://example.com/pr/4242")!,
                            isExplicit: true
                        ),
                        isActive: true
                    ),
                    panes: []
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()
        let initialHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        sidebarView.frame.size.width = 220
        sidebarView.layoutSubtreeIfNeeded()
        let resizedHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        let expectedHeight = metrics.height(for: [.primary, .status, .context])
        XCTAssertEqual(initialHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, initialHeight, accuracy: 0.5)
    }

    // MARK: - Group Layout Tests

    func test_group_single_pane_height_equals_header() {
        let group = SidebarWorkspaceGroupLayout(
            headerStatusText: nil,
            headerContextText: "",
            paneCount: 1,
            isExpanded: true
        )
        XCTAssertEqual(group.totalHeight, group.headerHeight, accuracy: 0.001)
        XCTAssertEqual(group.expandedPaneCount, 0)
    }

    func test_group_expanded_includes_pane_rows() {
        let group = SidebarWorkspaceGroupLayout(
            headerStatusText: nil,
            headerContextText: "main",
            paneCount: 3,
            isExpanded: true
        )
        let expectedHeight = group.headerHeight + 3 * ShellMetrics.paneSubRowHeight
        XCTAssertEqual(group.totalHeight, expectedHeight, accuracy: 0.001)
        XCTAssertEqual(group.expandedPaneCount, 3)
    }

    func test_group_collapsed_equals_header_only() {
        let group = SidebarWorkspaceGroupLayout(
            headerStatusText: "Running",
            headerContextText: "zentty • main",
            paneCount: 3,
            isExpanded: false
        )
        XCTAssertEqual(group.totalHeight, group.headerHeight, accuracy: 0.001)
        XCTAssertEqual(group.expandedPaneCount, 0)
    }

    func test_pane_sub_row_height_is_24() {
        XCTAssertEqual(ShellMetrics.paneSubRowHeight, 24, accuracy: 0.001)
    }
}
