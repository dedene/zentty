import AppKit
import XCTest

@testable import Zentty

@MainActor
final class SidebarSubagentBadgeTests: AppKitTestCase {
    private var rowWidthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]

    private let paneID = PaneID("worklane-main-agent")

    private var threeSubagents: PaneAgentSubagentSummary {
        PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "b", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "c", agentType: "codex-review", model: "claude-sonnet-5"),
        ])
    }

    func test_badge_shows_count_with_native_tooltip_and_no_list_at_rest() throws {
        let row = makeRow()
        row.configure(with: makeSummary(subagents: threeSubagents), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.layoutSubtreeIfNeeded()

        let snapshot = row.debugSnapshotForTesting
        XCTAssertEqual(snapshot.paneSubagentBadgeTexts, ["3"])
        XCTAssertEqual(snapshot.firstPaneSubagentBadgeToolTip, "3 subagents\nClick for details")
        XCTAssertEqual(snapshot.paneSubagentListTexts, [[]])

        let layout = SidebarWorklaneRowLayout(summary: makeSummary(subagents: threeSubagents))
        XCTAssertFalse(layout.visibleTextRows.contains(.paneSubagents(0)))
    }

    func test_badge_click_toggles_grouped_model_list_without_selecting_pane() throws {
        let row = makeRow()
        var selectedPaneIDs: [PaneID] = []
        row.onPaneSelected = { selectedPaneIDs.append($0) }
        row.configure(with: makeSummary(subagents: threeSubagents), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.layoutSubtreeIfNeeded()
        let collapsedHeight = row.intrinsicContentSize.height

        row.performDebugInteractionForTesting(.firstPaneSubagentBadgeClick)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(selectedPaneIDs, [])
        XCTAssertEqual(row.expandedSubagentPaneIDsForTesting, [paneID])
        XCTAssertEqual(
            row.debugSnapshotForTesting.paneSubagentListTexts,
            [["2 × opus general-purpose", "1 × sonnet codex-review"]]
        )
        XCTAssertEqual(
            row.intrinsicContentSize.height,
            collapsedHeight + 2 * ShellMetrics.sidebarDetailLineHeight + ShellMetrics.sidebarRowInterlineSpacing,
            accuracy: 0.001
        )

        row.performDebugInteractionForTesting(.firstPaneSubagentBadgeClick)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.expandedSubagentPaneIDsForTesting, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneSubagentListTexts, [[]])
        XCTAssertEqual(row.intrinsicContentSize.height, collapsedHeight, accuracy: 0.001)
    }

    func test_list_collapses_and_badge_hides_once_subagents_finish() throws {
        let row = makeRow()
        row.configure(with: makeSummary(subagents: threeSubagents), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.layoutSubtreeIfNeeded()
        row.performDebugInteractionForTesting(.firstPaneSubagentBadgeClick)
        XCTAssertEqual(row.expandedSubagentPaneIDsForTesting, [paneID])

        row.configure(with: makeSummary(subagents: .empty), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.expandedSubagentPaneIDsForTesting, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneSubagentBadgeTexts, [""])
        XCTAssertEqual(row.debugSnapshotForTesting.paneSubagentListTexts, [[]])
    }

    func test_badge_uses_pane_primary_text_color_as_fill() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let row = makeRow()
        row.configure(with: makeSummary(subagents: threeSubagents), theme: theme, animated: false)
        row.layoutSubtreeIfNeeded()

        let snapshot = row.debugSnapshotForTesting
        XCTAssertEqual(
            snapshot.firstPaneSubagentBadgeFillColor?.srgbClamped,
            snapshot.firstPanePrimaryTextColor?.srgbClamped
        )
    }

    // MARK: - Helpers

    private func makeRow(width: CGFloat = 220, height: CGFloat = 90) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
            reducedMotionProvider: { true }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let widthConstraint = row.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        rowWidthConstraints[ObjectIdentifier(row)] = widthConstraint
        return row
    }

    private func makeSummary(subagents: PaneAgentSubagentSummary?) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "1",
            primaryText: "agent",
            paneRows: [
                WorklaneSidebarPaneRow(
                    paneID: paneID,
                    primaryText: "1Password pane focus",
                    trailingText: nil,
                    detailText: "…/zentty",
                    statusText: "Running",
                    attentionState: .running,
                    isFocused: true,
                    isWorking: true,
                    subagents: subagents
                ),
            ],
            isWorking: true,
            isActive: true
        )
    }
}
