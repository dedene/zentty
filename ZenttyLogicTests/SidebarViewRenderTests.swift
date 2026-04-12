import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarViewRenderTests: XCTestCase {
    func test_render_skipsWorkWhenSummariesAndThemeAreUnchanged() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [makeSummary(worklaneID: "main", primaryText: "demo")]

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(
            sidebar.renderInvocationCountForTesting,
            1,
            "identical inputs should not trigger a second full render pass"
        )
    }

    func test_render_runsAgainWhenSummariesChange() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo updated")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 2)
    }

    func test_render_runsAgainWhenWorklaneListChanges() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo")],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 1)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "main", primaryText: "demo"),
                makeSummary(worklaneID: "second", primaryText: "another"),
            ],
            theme: theme
        )
        XCTAssertEqual(sidebar.renderInvocationCountForTesting, 2)
    }

    // MARK: - Structural mutation sequence (Phase 0 baseline)
    //
    // Drives a sequence of add/remove mutations through SidebarView.render()
    // and asserts button count + worklaneID order after each step. Locks the
    // current structural behavior before Phase 2 rewrites render() to use a
    // diff-based mutation path. Phase 2 will extend this test with identity
    // preservation assertions (ObjectIdentifier stability for surviving IDs).

    func test_render_structural_mutation_sequence_maintains_expected_ids() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        // Step 1: [] → [A]
        sidebar.render(
            summaries: [makeSummary(worklaneID: "A", primaryText: "a")],
            theme: theme
        )
        XCTAssertEqual(worklaneIDs(in: sidebar), [WorklaneID("A")])

        // Step 2: [A] → [A, B]
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
            ],
            theme: theme
        )
        XCTAssertEqual(worklaneIDs(in: sidebar), [WorklaneID("A"), WorklaneID("B")])

        // Step 3: [A, B] → [A, B, C]
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )
        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )

        // Step 4: [A, B, C] → [A, C] (remove middle)
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )
        XCTAssertEqual(worklaneIDs(in: sidebar), [WorklaneID("A"), WorklaneID("C")])

        // Step 5: [A, C] → [] (close all)
        sidebar.render(summaries: [], theme: theme)
        XCTAssertEqual(worklaneIDs(in: sidebar), [])
    }

    func test_render_mixed_insert_and_remove_resolves_to_target_order() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )
        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )

        // [A, B, C] → [D, A, E] (remove B+C, insert D at front, insert E at end, keep A in middle)
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "D", primaryText: "d"),
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "E", primaryText: "e"),
            ],
            theme: theme
        )
        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("D"), WorklaneID("A"), WorklaneID("E")]
        )
    }

    // MARK: - Identity preservation (Phase 2 baseline)
    //
    // These tests assert that surviving buttons are the SAME NSView instance
    // (by ObjectIdentifier) across structural mutations. This proves the
    // diff-based render path reuses buttons instead of destroying them,
    // preserving hover, focus, tooltip, and shimmer state.

    func test_render_preserves_button_identity_across_removal() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )

        let buttonA = worklaneButton(in: sidebar, id: "A")
        let buttonC = worklaneButton(in: sidebar, id: "C")
        XCTAssertNotNil(buttonA)
        XCTAssertNotNil(buttonC)

        // [A, B, C] → [A, C]  (remove B, keep A and C)
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )

        let buttonAAfter = worklaneButton(in: sidebar, id: "A")
        let buttonCAfter = worklaneButton(in: sidebar, id: "C")

        XCTAssertTrue(
            buttonA === buttonAAfter,
            "Button A should be the same instance after B is removed"
        )
        XCTAssertTrue(
            buttonC === buttonCAfter,
            "Button C should be the same instance after B is removed"
        )
    }

    func test_render_preserves_button_identity_across_insertion() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "A", primaryText: "a")],
            theme: theme
        )
        let buttonA = worklaneButton(in: sidebar, id: "A")
        XCTAssertNotNil(buttonA)

        // [A] → [A, B]
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
            ],
            theme: theme
        )

        let buttonAAfter = worklaneButton(in: sidebar, id: "A")
        XCTAssertTrue(
            buttonA === buttonAAfter,
            "Button A should be the same instance after B is inserted"
        )
    }

    func test_render_preserves_button_identity_across_mixed_mutation() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )
        let buttonA = worklaneButton(in: sidebar, id: "A")
        XCTAssertNotNil(buttonA)

        // [A, B, C] → [D, A, E]  (keep A, remove B+C, insert D+E)
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "D", primaryText: "d"),
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "E", primaryText: "e"),
            ],
            theme: theme
        )

        let buttonAAfter = worklaneButton(in: sidebar, id: "A")
        XCTAssertTrue(
            buttonA === buttonAAfter,
            "Button A should be the same instance across mixed insert+remove"
        )
    }

    func test_resize_proposal_does_not_preclamp_to_window_width() {
        let sidebar = makeSidebar()

        XCTAssertEqual(
            sidebar.proposedResizeWidthForTesting(
                startWidth: 280,
                translation: 80,
                availableWidth: 900
            ),
            360,
            accuracy: 0.001
        )
    }

    private func worklaneButton(
        in sidebar: SidebarView,
        id: String
    ) -> SidebarWorklaneRowButton? {
        sidebar.worklaneButtonsForTesting.compactMap {
            $0 as? SidebarWorklaneRowButton
        }.first { $0.worklaneID == WorklaneID(id) }
    }

    private func worklaneIDs(in sidebar: SidebarView) -> [WorklaneID] {
        sidebar.worklaneButtonsForTesting.compactMap {
            ($0 as? SidebarWorklaneRowButton)?.worklaneID
        }
    }

    private func makeSidebar() -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        return sidebar
    }

    private func makeSummary(
        worklaneID: String,
        primaryText: String,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID(worklaneID),
            badgeText: "1",
            topLabel: nil,
            primaryText: primaryText,
            statusText: nil,
            detailLines: [],
            attentionState: nil,
            isWorking: false,
            isActive: isActive
        )
    }
}
