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
        XCTAssertEqual(layout.visibleTextRows, [.topLabel, .primary, .detail(0), .status])
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

    func test_layout_does_not_include_state_badge_as_separate_line() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            statusText: "Needs input",
            detailLines: [
                WorkspaceSidebarDetailLine(text: "feature/sidebar • zentty", emphasis: .primary),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.primary, .detail(0), .status])
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: true,
                detailLineCount: 1,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_flattens_pane_rows_in_order_with_local_status_lines() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            paneRows: [
                WorkspaceSidebarPaneRow(
                    paneID: PaneID("workspace-main-agent"),
                    primaryText: "General coding assistance session",
                    trailingText: "main",
                    detailText: "…/nimbu",
                    statusText: "╰ Completed",
                    attentionState: .completed,
                    isFocused: true,
                    isWorking: false
                ),
                WorkspaceSidebarPaneRow(
                    paneID: PaneID("workspace-main-build"),
                    primaryText: "npm test",
                    trailingText: nil,
                    detailText: "/tmp/project",
                    statusText: "╰ Running",
                    attentionState: .running,
                    isFocused: false,
                    isWorking: true
                ),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.panePrimary(0), .paneDetail(0), .paneStatus(0), .panePrimary(1), .paneDetail(1), .paneStatus(1)]
        )
        XCTAssertGreaterThan(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight)
    }

    func test_layout_places_primary_row_at_focused_pane_line_index() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            primaryText: "k8s-zenjoy",
            focusedPaneLineIndex: 1,
            detailLines: [
                WorkspaceSidebarDetailLine(text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                WorkspaceSidebarDetailLine(text: "Personal", emphasis: .secondary),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.detail(0), .primary, .detail(1)]
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
        XCTAssertGreaterThan(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 1,
                includesOverflow: false,
                includesArtifact: false
            )
        )
    }

    func test_layout_supports_more_than_three_detail_lines_without_overflow_row() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            detailLines: [
                WorkspaceSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorkspaceSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorkspaceSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
                WorkspaceSidebarDetailLine(text: "tests • specs", emphasis: .secondary),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.primary, .detail(0), .detail(1), .detail(2), .detail(3)]
        )
        XCTAssertEqual(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 4,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
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

    func test_layout_does_not_expand_for_sidebar_artifact_visibility() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            artifactLink: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #42",
                url: URL(string: "https://example.com/pr/42")!,
                isExplicit: true
            )
        ))

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertEqual(layout.visibleTextRows, [.primary])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.001)
    }

    func test_shell_metrics_preserve_current_fixed_row_heights_from_layout_budgets() {
        let metrics = WorkspaceRowLayoutMetrics.sidebar

        XCTAssertEqual(
            ShellMetrics.sidebarCompactRowHeight,
            ShellMetrics.sidebarRowTopInset
                + ShellMetrics.sidebarRowBottomInset
                + ShellMetrics.sidebarPrimaryLineHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ShellMetrics.sidebarExpandedRowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: true,
                includesStatus: true,
                detailLineCount: 1,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.001
        )
        XCTAssertEqual(ShellMetrics.sidebarRowTopInset, 8, accuracy: 0.001)
        XCTAssertEqual(ShellMetrics.sidebarRowBottomInset, 8, accuracy: 0.001)
        XCTAssertEqual(ShellMetrics.sidebarRowInterlineSpacing, 3, accuracy: 0.001)
        XCTAssertEqual(
            metrics.compactHeight,
            ShellMetrics.sidebarCompactRowHeight,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(metrics.titleLineHeight, 0)
        XCTAssertGreaterThan(metrics.primaryLineHeight, metrics.titleLineHeight)
        XCTAssertGreaterThan(metrics.detailLineHeight, 0)
    }

    func test_shell_metrics_use_actual_appkit_fitting_heights_for_11pt_sidebar_labels() {
        let statusLabel = NSTextField(labelWithString: "Needs input")
        statusLabel.font = ShellMetrics.sidebarStatusFont()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.sizeToFit()

        let detailLabel = NSTextField(labelWithString: "peter@m1-pro-peter:~/Development/Personal/worktrees/feature/sidebar")
        detailLabel.font = ShellMetrics.sidebarDetailFont()
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.sizeToFit()

        XCTAssertEqual(
            ShellMetrics.sidebarStatusLineHeight,
            statusLabel.fittingSize.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ShellMetrics.sidebarDetailLineHeight,
            detailLabel.fittingSize.height,
            accuracy: 0.001
        )
        XCTAssertEqual(ShellMetrics.sidebarStatusLineHeight, 14, accuracy: 0.001)
        XCTAssertEqual(ShellMetrics.sidebarDetailLineHeight, 14, accuracy: 0.001)
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
            includesArtifact: false
        )

        XCTAssertEqual(initialHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, initialHeight, accuracy: 0.5)
    }

    private func makeSummary(
        topLabel: String? = nil,
        primaryText: String = "shell",
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        stateBadgeText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        paneRows: [WorkspaceSidebarPaneRow] = [],
        overflowText: String? = nil,
        artifactLink: WorkspaceArtifactLink? = nil,
        leadingAccessory: WorkspaceSidebarLeadingAccessory? = nil
    ) -> WorkspaceSidebarSummary {
        WorkspaceSidebarSummary(
            workspaceID: WorkspaceID("workspace-main"),
            badgeText: "M",
            topLabel: topLabel,
            primaryText: primaryText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusText,
            stateBadgeText: stateBadgeText,
            detailLines: detailLines,
            paneRows: paneRows,
            overflowText: overflowText,
            leadingAccessory: leadingAccessory,
            attentionState: nil,
            artifactLink: artifactLink,
            isActive: true
        )
    }
}
