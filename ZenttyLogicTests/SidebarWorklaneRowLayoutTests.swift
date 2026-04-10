import XCTest
@testable import Zentty

@MainActor
final class SidebarWorklaneRowLayoutTests: XCTestCase {
    func test_layout_uses_compact_mode_for_primary_only_rows() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary())

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertEqual(layout.visibleTextRows, [.primary])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.001)
    }

    func test_layout_expands_when_top_label_status_and_detail_line_are_visible() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            topLabel: "Docs",
            statusText: "Needs input",
            detailLines: [
                WorklaneSidebarDetailLine(
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
                includesOverflow: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_does_not_include_state_badge_as_separate_line() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            statusText: "Needs input",
            detailLines: [
                WorklaneSidebarDetailLine(text: "feature/sidebar • zentty", emphasis: .primary),
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
                includesOverflow: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_flattens_pane_rows_in_order_with_local_status_lines() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-agent"),
                    primaryText: "General coding assistance session",
                    trailingText: "main",
                    detailText: "…/nimbu",
                    statusText: "╰ Idle",
                    attentionState: nil,
                    isFocused: true,
                    isWorking: false
                ),
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-build"),
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

    func test_layout_expands_for_multiple_pane_primary_rows_even_without_detail_or_status() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-1"),
                    primaryText: "main · …/nimbu",
                    trailingText: nil,
                    detailText: nil,
                    statusText: nil,
                    attentionState: nil,
                    isFocused: true,
                    isWorking: false
                ),
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-2"),
                    primaryText: "build",
                    trailingText: nil,
                    detailText: nil,
                    statusText: nil,
                    attentionState: nil,
                    isFocused: false,
                    isWorking: false
                ),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.panePrimary(0), .panePrimary(1)])
        XCTAssertGreaterThan(layout.rowHeight, ShellMetrics.sidebarCompactRowHeight)
    }

    func test_layout_places_primary_row_at_focused_pane_line_index() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            primaryText: "k8s-zenjoy",
            focusedPaneLineIndex: 1,
            detailLines: [
                WorklaneSidebarDetailLine(text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                WorklaneSidebarDetailLine(text: "Personal", emphasis: .secondary),
            ]
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.detail(0), .primary, .detail(1)]
        )
    }

    func test_layout_height_grows_with_detail_line_count() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            detailLines: [
                WorklaneSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorklaneSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorklaneSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
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
                includesOverflow: false
            ),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            layout.rowHeight,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 1,
                includesOverflow: false
            )
        )
    }

    func test_layout_supports_more_than_three_detail_lines_without_overflow_row() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            detailLines: [
                WorklaneSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorklaneSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorklaneSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
                WorklaneSidebarDetailLine(text: "tests • specs", emphasis: .secondary),
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
                includesOverflow: false
            ),
            accuracy: 0.001
        )
    }

    func test_layout_includes_overflow_line_in_visible_rows_and_height() {
        let layout = SidebarWorklaneRowLayout(summary: makeSummary(
            detailLines: [
                WorklaneSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                WorklaneSidebarDetailLine(text: "main • git", emphasis: .secondary),
                WorklaneSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
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
                includesOverflow: true
            ),
            accuracy: 0.001
        )
    }

    func test_shell_metrics_preserve_current_fixed_row_heights_from_layout_budgets() {
        let metrics = WorklaneRowLayoutMetrics.sidebar

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
                includesOverflow: false
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
    }

    func test_sidebar_row_height_is_stable_across_width_changes_when_labels_truncate() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSummary(
                    topLabel: "Claude Code Session Worklane",
                    primaryText: "Claude Code working on a very long branch name for layout checks",
                    statusText: "Needs input from the operator immediately",
                    detailLines: [
                        WorklaneSidebarDetailLine(
                            text: "~/Development/Personal/zentty/a/really/long/path/that/should/truncate",
                            emphasis: .primary
                        ),
                        WorklaneSidebarDetailLine(
                            text: "refresh-homepage-copy • marketing-site",
                            emphasis: .secondary
                        ),
                    ],
                    overflowText: "+1 more pane"
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()
        let initialHeight = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.first?.frame.height)

        sidebarView.frame.size.width = 220
        sidebarView.layoutSubtreeIfNeeded()
        let resizedHeight = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.first?.frame.height)

        let expectedHeight = ShellMetrics.sidebarRowHeight(
            includesTopLabel: true,
            includesStatus: true,
            detailLineCount: 2,
            includesOverflow: true
        )

        XCTAssertEqual(initialHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, initialHeight, accuracy: 0.5)
    }

    func test_sidebar_row_worklane_primary_stays_single_line_across_widths() {
        // Regression: worklane primary rows must stay single-line with tail
        // truncation so the shimmer overlay (`SidebarShimmerTextView`) keeps
        // drawing when an agent is running. Wrapping the primary would force
        // the shimmer view to be hidden.
        let summary = makeSummary(
            primaryText: "Requires approval for a longer sidebar copy check that would have wrapped to a second line in tight widths"
        )

        let wideLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 900)
        let narrowLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 220)

        XCTAssertEqual(narrowLayout.rowHeight, wideLayout.rowHeight, accuracy: 0.001)
        XCTAssertEqual(narrowLayout.rowHeight, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.001)
        XCTAssertEqual(narrowLayout.visibleTextRows, [.primary])
        XCTAssertEqual(narrowLayout.mode, .compact)
    }

    func test_sidebar_row_inserts_context_prefix_between_primary_and_status() {
        let summary = makeSummary(
            primaryText: "main · zentty",
            contextPrefixText: "…/Development",
            statusText: "Running"
        )

        let layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 320)

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.primary, .contextPrefix, .status]
        )
        XCTAssertGreaterThan(layout.rowHeight, ShellMetrics.sidebarCompactRowHeight + 0.5)
    }

    func test_sidebar_row_expands_for_context_prefix_even_without_status() {
        let summary = makeSummary(
            primaryText: "main · zentty",
            contextPrefixText: "…/Development"
        )

        let layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 320)

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.primary, .contextPrefix])
    }

    func test_sidebar_row_height_grows_for_tight_worklane_rows_when_status_wraps() {
        let summary = makeSummary(
            primaryText: "Claude Code",
            statusText: "Needs approval from Peter before continuing with the longer follow-up action in this row"
        )

        let wideLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 900)
        let narrowLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 220)

        XCTAssertGreaterThan(narrowLayout.rowHeight, wideLayout.rowHeight + 0.5)
    }

    func test_sidebar_row_height_grows_for_tight_pane_rows_when_status_wraps() {
        let summary = makeSummary(
            primaryText: "General coding assistance session",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-agent"),
                    primaryText: "Claude Code",
                    trailingText: nil,
                    detailText: nil,
                    statusText: "Needs approval from Peter before continuing with the longer follow-up action in this pane row",
                    attentionState: .needsInput,
                    isFocused: true,
                    isWorking: false
                ),
            ]
        )

        let wideLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 900)
        let narrowLayout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 220)

        XCTAssertGreaterThan(narrowLayout.rowHeight, wideLayout.rowHeight + 0.5)
    }

    func test_sidebar_row_hides_long_branch_in_status_measurement_when_status_needs_the_width() {
        let status = "Run fix/tmpdir-redirect-to-shared-tmp-files"
        let summaryWithBranch = makeSummary(
            primaryText: "General coding assistance session",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-agent"),
                    primaryText: "Debug Claude API review failure in GitHub Actions",
                    trailingText: "fix/tmpdir-redirect-to-shared-tmp-files",
                    detailText: "…/nimbu",
                    statusText: status,
                    attentionState: .running,
                    isFocused: true,
                    isWorking: true
                ),
            ]
        )
        let summaryWithoutBranch = makeSummary(
            primaryText: "General coding assistance session",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-agent"),
                    primaryText: "Debug Claude API review failure in GitHub Actions",
                    trailingText: nil,
                    detailText: "…/nimbu",
                    statusText: status,
                    attentionState: .running,
                    isFocused: true,
                    isWorking: true
                ),
            ]
        )

        let withBranch = SidebarWorklaneRowLayout(summary: summaryWithBranch, availableWidth: 220)
        let withoutBranch = SidebarWorklaneRowLayout(summary: summaryWithoutBranch, availableWidth: 220)

        XCTAssertEqual(withBranch.rowHeight, withoutBranch.rowHeight, accuracy: 0.5)
    }

    // MARK: - Branch baselines for Phase 1 visibleTextRows collapse
    //
    // These two tests lock the exact visibleTextRows output for the two
    // current branches in SidebarWorklaneRowLayout.visibleTextRows (the
    // pane-rows-empty path at lines 251-285 and the pane-rows-present path
    // at lines 208-248 in the current code). Phase 1 collapses them into a
    // single construction; these assertions catch any drift.

    func test_visible_rows_branch_b_max_expansion_pane_rows_empty() {
        // Branch B (paneRows.isEmpty == true) — every optional row present.
        // Expected expansion order: topLabel → primary → contextPrefix → status → overflow.
        let summary = makeSummary(
            topLabel: "Docs",
            primaryText: "main · zentty",
            contextPrefixText: "…/Development",
            statusText: "Running",
            detailLines: [],
            overflowText: "+3 more"
        )

        let layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 320)

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [.topLabel, .primary, .contextPrefix, .status, .overflow]
        )
    }

    func test_visible_rows_branch_a_single_pane_row_with_context_prefix() {
        // Branch A (paneRows.isEmpty == false) with exactly one pane row.
        // contextPrefix only appears in this branch when paneRows.count == 1;
        // it should be inserted after the first panePrimary.
        let summary = makeSummary(
            topLabel: "Docs",
            contextPrefixText: "…/Development",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: PaneID("worklane-main-agent"),
                    primaryText: "Claude Code",
                    trailingText: "main",
                    detailText: "…/zentty",
                    statusText: "Running",
                    attentionState: .running,
                    isFocused: true,
                    isWorking: true
                )
            ],
            overflowText: "+2 pending"
        )

        let layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: 320)

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(
            layout.visibleTextRows,
            [
                .topLabel,
                .panePrimary(0),
                .paneDetail(0),
                .contextPrefix,
                .paneStatus(0),
                .overflow,
            ]
        )
    }

    func test_sidebar_row_status_trailing_layout_hides_long_branch_when_narrow_and_restores_when_wider() {
        let paneRow = WorklaneSidebarPaneRow(
            paneID: PaneID("worklane-main-agent"),
            primaryText: "Debug Claude API review failure in GitHub Actions",
            trailingText: "fix/tmpdir-redirect-to-shared-tmp-files",
            detailText: "…/nimbu",
            statusText: "Run fix/tmpdir-redirect-to-shared-tmp-files",
            attentionState: .running,
            isFocused: true,
            isWorking: true
        )

        let narrowLayout = SidebarWorklaneRowLayout.paneRowStatusTrailingLayout(
            for: paneRow,
            availableWidth: 220
        )
        let wideLayout = SidebarWorklaneRowLayout.paneRowStatusTrailingLayout(
            for: paneRow,
            availableWidth: 360
        )

        XCTAssertEqual(narrowLayout, .hidden)
        XCTAssertTrue(wideLayout.isVisible)
        XCTAssertGreaterThan(wideLayout.width, 0)
    }

    private func makeSummary(
        topLabel: String? = nil,
        primaryText: String = "shell",
        contextPrefixText: String? = nil,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        detailLines: [WorklaneSidebarDetailLine] = [],
        paneRows: [WorklaneSidebarPaneRow] = [],
        overflowText: String? = nil
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "M",
            topLabel: topLabel,
            primaryText: primaryText,
            contextPrefixText: contextPrefixText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusText,
            detailLines: detailLines,
            paneRows: paneRows,
            overflowText: overflowText,
            attentionState: nil,
            isActive: true
        )
    }
}
