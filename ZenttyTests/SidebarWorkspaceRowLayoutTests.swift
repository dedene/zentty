import XCTest
@testable import Zentty

@MainActor
final class SidebarWorkspaceRowLayoutTests: XCTestCase {
    func test_layout_uses_compact_mode_for_primary_only_rows() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary())

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertEqual(layout.visibleTextRows, [.primary])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.001)
    }

    func test_layout_expands_when_top_label_status_and_detail_line_are_visible() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            topLabel: "Docs",
            statusText: "Needs input",
            detailLines: [
                WorkspaceSidebarDetailLine(
                    text: "feature/sidebar • zentty",
                    emphasis: .primary
                )
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.topLabel, .primary, .status, .detail(0)])
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: true,
                includesStatus: true,
                detailLineCount: 1,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_height_grows_with_detail_line_count() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            detailLines: [
                WorkspaceSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorkspaceSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorkspaceSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.primary, .detail(0), .detail(1), .detail(2)]
        )
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 3,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight)
    }

    func test_layout_includes_overflow_line_in_visible_rows_and_height() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            detailLines: [
                WorkspaceSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorkspaceSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorkspaceSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
            ],
            overflowText: "+1 more pane"
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.primary, .detail(0), .detail(1), .detail(2), .overflow]
        )
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 3,
                includesOverflow: true,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_expands_when_artifact_is_visible() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            artifactLink: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #42",
                url: URL(string: "https://example.com/pr/42")!,
                isExplicit: true
            )
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.primary])
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 0,
                includesOverflow: false,
                includesArtifact: true
            ),
            accuracy: 0.001
        )
    }

    func test_shell_metrics_preserve_current_fixed_row_heights_from_layout_budgets() {
        XCTAssertEqual(
            ShellMetrics.sidebarCompactRowHeight,
            ShellMetrics.sidebarRowVerticalPadding + ShellMetrics.sidebarPrimaryLineHeightBudget,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ShellMetrics.sidebarExpandedRowHeight,
            ShellMetrics.sidebarRowVerticalPadding
                + ShellMetrics.sidebarTitleLineHeightBudget
                + ShellMetrics.sidebarPrimaryLineHeightBudget
                + ShellMetrics.sidebarStatusLineHeightBudget
                + ShellMetrics.sidebarContextLineHeightBudget
                + (3 * ShellMetrics.sidebarRowInterlineSpacing),
            accuracy: 0.001
        )
        XCTAssertEqual(ShellMetrics.sidebarCompactRowHeight, 34, accuracy: 0.001)
        XCTAssertEqual(ShellMetrics.sidebarExpandedRowHeight, 58, accuracy: 0.001)
    }

    func test_sidebar_row_height_is_stable_across_width_changes_when_labels_truncate() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSummary(
                    topLabel: "Claude Code Session Workspace",
                    primaryText: "Claude Code working on a very long branch name for layout checks",
                    statusText: "Needs input from the operator immediately",
                    detailLines: [
                        WorkspaceSidebarDetailLine(
                            text: "~/Development/Personal/zentty/a/really/long/path/that/should/truncate",
                            emphasis: .primary
                        ),
                        WorkspaceSidebarDetailLine(
                            text: "refresh-homepage-copy • marketing-site",
                            emphasis: .secondary
                        ),
                    ],
                    overflowText: "+1 more pane",
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #4242 with a long label",
                        url: URL(string: "https://example.com/pr/4242")!,
                        isExplicit: true
                    )
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()
        let initialHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        sidebarView.frame.size.width = 220
        sidebarView.layoutSubtreeIfNeeded()
        let resizedHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        let expectedHeight = ShellMetrics.sidebarRowHeight(
            includesTopLabel: true,
            includesStatus: true,
            detailLineCount: 2,
            includesOverflow: true,
            includesArtifact: true
        )

        XCTAssertEqual(initialHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, initialHeight, accuracy: 0.5)
    }

    private func makeSummary(
        topLabel: String? = nil,
        primaryText: String = "shell",
        statusText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        overflowText: String? = nil,
        artifactLink: WorkspaceArtifactLink? = nil,
        leadingAccessory: WorkspaceSidebarLeadingAccessory? = nil
    ) -> WorkspaceSidebarSummary {
        WorkspaceSidebarSummary(
            workspaceID: WorkspaceID("workspace-main"),
            badgeText: "M",
            topLabel: topLabel,
            primaryText: primaryText,
            statusText: statusText,
            detailLines: detailLines,
            overflowText: overflowText,
            leadingAccessory: leadingAccessory,
            attentionState: nil,
            artifactLink: artifactLink,
            isActive: true
        )
    }
}
