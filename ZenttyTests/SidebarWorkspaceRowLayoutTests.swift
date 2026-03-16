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

    func test_layout_expands_when_generated_title_is_visible() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(
            title: "Claude Code",
            showsGeneratedTitle: true
        ))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.title, .primary])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.001)
    }

    func test_layout_expands_when_status_is_visible() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(statusText: "Needs input"))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.primary, .status])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.001)
    }

    func test_layout_expands_when_context_is_visible() {
        let layout = SidebarWorkspaceRowLayout(summary: makeSummary(contextText: "main • ~/src/zentty"))

        XCTAssertEqual(layout.mode, .expanded)
        XCTAssertEqual(layout.visibleTextRows, [.primary, .context])
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.001)
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
        XCTAssertEqual(layout.rowHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.001)
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
                    title: "Claude Code Session Workspace",
                    primaryText: "Claude Code working on a very long branch name for layout checks",
                    statusText: "Needs input from the operator immediately",
                    contextText: "~/Development/Personal/zentty/a/really/long/path/that/should/truncate",
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #4242 with a long label",
                        url: URL(string: "https://example.com/pr/4242")!,
                        isExplicit: true
                    ),
                    showsGeneratedTitle: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()
        let initialHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        sidebarView.frame.size.width = 220
        sidebarView.layoutSubtreeIfNeeded()
        let resizedHeight = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame.height)

        XCTAssertEqual(initialHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.5)
        XCTAssertEqual(resizedHeight, initialHeight, accuracy: 0.5)
    }

    private func makeSummary(
        title: String = "MAIN",
        primaryText: String = "shell",
        statusText: String? = nil,
        contextText: String = "",
        artifactLink: WorkspaceArtifactLink? = nil,
        showsGeneratedTitle: Bool = false
    ) -> WorkspaceSidebarSummary {
        WorkspaceSidebarSummary(
            workspaceID: WorkspaceID("workspace-main"),
            title: title,
            badgeText: "M",
            primaryText: primaryText,
            statusText: statusText,
            contextText: contextText,
            attentionState: nil,
            artifactLink: artifactLink,
            isActive: true,
            showsGeneratedTitle: showsGeneratedTitle
        )
    }
}
