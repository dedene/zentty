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

    // MARK: - Structural Mutation

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

    func test_render_pure_reorder_preserves_button_identity_and_target_order() {
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
        let buttonB = worklaneButton(in: sidebar, id: "B")
        let buttonC = worklaneButton(in: sidebar, id: "C")

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "C", primaryText: "c"),
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
            ],
            theme: theme
        )

        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("C"), WorklaneID("A"), WorklaneID("B")]
        )
        XCTAssertTrue(buttonA === worklaneButton(in: sidebar, id: "A"))
        XCTAssertTrue(buttonB === worklaneButton(in: sidebar, id: "B"))
        XCTAssertTrue(buttonC === worklaneButton(in: sidebar, id: "C"))
    }

    func test_dragPreview_reordersButtonsAndLeavesInvisibleSpacerAtDropSlot() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [
            makeSummary(worklaneID: "A", primaryText: "a"),
            makeSummary(
                worklaneID: "B",
                primaryText: "b",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "~/Development/project", emphasis: .primary),
                    WorklaneSidebarDetailLine(text: "main", emphasis: .secondary),
                ]
            ),
            makeSummary(worklaneID: "C", primaryText: "c"),
        ]

        sidebar.render(summaries: summaries, theme: theme)
        sidebar.layoutSubtreeIfNeeded()
        guard let buttonB = worklaneButton(in: sidebar, id: "B") else {
            XCTFail("Expected B row")
            return
        }
        let draggedHeight = buttonB.frame.height
        sidebar.prepareDraggedWorklaneButton(buttonB)

        sidebar.setDragPreview(
            draggedID: WorklaneID("B"),
            previewOrder: [WorklaneID("A"), WorklaneID("C"), WorklaneID("B")]
        )

        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("A"), WorklaneID("C"), WorklaneID("B")]
        )
        XCTAssertEqual(
            sidebar.arrangedWorklaneIDsForTesting,
            [WorklaneID("A"), WorklaneID("C")]
        )
        XCTAssertEqual(
            arrangedSidebarItems(in: sidebar),
            ["A", "C", "spacer"]
        )
        XCTAssertEqual(sidebar.reorderSpacerHeightForTesting, draggedHeight, accuracy: 0.001)
        XCTAssertTrue(buttonB === worklaneButton(in: sidebar, id: "B"))
        XCTAssertNotNil(buttonB.superview)
    }

    func test_clearDragPreview_restoresDetachedDraggedRowWhenOrderDidNotChange() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [
            makeSummary(worklaneID: "A", primaryText: "a"),
            makeSummary(worklaneID: "B", primaryText: "b"),
            makeSummary(worklaneID: "C", primaryText: "c"),
        ]

        sidebar.render(summaries: summaries, theme: theme)
        guard let buttonB = worklaneButton(in: sidebar, id: "B") else {
            XCTFail("Expected B row")
            return
        }

        sidebar.prepareDraggedWorklaneButton(buttonB)
        sidebar.setDragPreview(
            draggedID: WorklaneID("B"),
            previewOrder: [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )

        sidebar.clearDragPreview()

        XCTAssertEqual(
            sidebar.arrangedWorklaneIDsForTesting,
            [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )
    }

    func test_clearDragPreview_restoresCanonicalOrder() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [
            makeSummary(worklaneID: "A", primaryText: "a"),
            makeSummary(worklaneID: "B", primaryText: "b"),
            makeSummary(worklaneID: "C", primaryText: "c"),
        ]

        sidebar.render(summaries: summaries, theme: theme)
        sidebar.setDragPreview(
            draggedID: WorklaneID("B"),
            previewOrder: [WorklaneID("A"), WorklaneID("C"), WorklaneID("B")]
        )

        sidebar.clearDragPreview()

        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )
        XCTAssertEqual(
            sidebar.arrangedWorklaneIDsForTesting,
            [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )
    }

    func test_reorderRowFrames_useVisualTopToBottomCoordinateOrder() {
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
        sidebar.layoutSubtreeIfNeeded()

        let frames = sidebar.worklaneRowFramesForReorderingForTesting
        XCTAssertEqual(frames.map(\.0), [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")])
        XCTAssertLessThan(frames[0].1.midY, frames[1].1.midY)
        XCTAssertLessThan(frames[1].1.midY, frames[2].1.midY)
    }

    func test_render_removes_deleted_buttons_from_view_hierarchy_immediately() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
            ],
            theme: theme
        )

        let removedButton = worklaneButton(in: sidebar, id: "B")
        XCTAssertNotNil(removedButton?.superview)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
            ],
            theme: theme
        )

        XCTAssertNil(removedButton?.superview)
        if let removedButton {
            XCTAssertFalse(sidebar.listStackHasConstraintsReferencingViewForTesting(removedButton))
        }
        XCTAssertEqual(worklaneIDs(in: sidebar), [WorklaneID("A")])
    }

    func test_render_reconfigures_surviving_buttons_when_theme_changes_during_structural_mutation() {
        let sidebar = makeSidebar()
        let initialTheme = ZenttyTheme.fallback(for: nil)
        let nextTheme = makeDarkTheme(foreground: "#F0F3F6")
        let summaryA = makeSummary(worklaneID: "A", primaryText: "a")

        sidebar.render(
            summaries: [
                summaryA,
                makeSummary(worklaneID: "B", primaryText: "b"),
            ],
            theme: initialTheme
        )

        let buttonA = worklaneButton(in: sidebar, id: "A")
        XCTAssertNotNil(buttonA)

        sidebar.render(
            summaries: [summaryA],
            theme: nextTheme
        )

        XCTAssertTrue(buttonA === worklaneButton(in: sidebar, id: "A"))
        XCTAssertEqual(
            buttonA?.primaryTextColorForTesting.srgbClamped,
            nextTheme.sidebarButtonInactiveText.srgbClamped
        )
    }

    // MARK: - Identity Preservation

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
                translation: 80
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

    private func arrangedSidebarItems(in sidebar: SidebarView) -> [String] {
        guard let stack = findListStack(in: sidebar) else {
            return []
        }

        return stack.arrangedSubviews.compactMap { view in
            if let button = view as? SidebarWorklaneRowButton {
                return button.worklaneID?.rawValue ?? "unknown"
            }
            if view is SidebarReorderSpacerView {
                return "spacer"
            }
            return nil
        }
    }

    private func findListStack(in view: NSView) -> NSStackView? {
        if let stack = view as? NSStackView,
           stack.arrangedSubviews.contains(where: { $0 is SidebarWorklaneRowButton }) {
            return stack
        }

        for subview in view.subviews {
            if let stack = findListStack(in: subview) {
                return stack
            }
        }
        return nil
    }

    private func makeSidebar() -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        return sidebar
    }

    private func makeDarkTheme(foreground: String) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: foreground)!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )
    }

    private func makeSummary(
        worklaneID: String,
        primaryText: String,
        isActive: Bool = false,
        detailLines: [WorklaneSidebarDetailLine] = []
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID(worklaneID),
            badgeText: "1",
            topLabel: nil,
            primaryText: primaryText,
            statusText: nil,
            detailLines: detailLines,
            attentionState: nil,
            isWorking: false,
            isActive: isActive
        )
    }
}
