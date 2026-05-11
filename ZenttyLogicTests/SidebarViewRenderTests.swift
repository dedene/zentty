import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarViewRenderTests: XCTestCase {
    func test_sidebar_toggle_tooltip_uses_configured_shortcut() {
        let button = SidebarToggleButton()

        button.updateShortcutTooltip(ShortcutManager(shortcuts: .default))

        XCTAssertEqual(button.toolTip, "Toggle Sidebar (⌘S)")
    }

    func test_sidebar_control_tooltips_update_for_custom_and_unassigned_shortcuts() {
        let sidebar = makeSidebar()
        let customManager = ShortcutManager(
            shortcuts: AppConfig.Shortcuts(
                bindings: [
                    ShortcutBindingOverride(
                        commandID: .newWorklane,
                        shortcut: .init(key: .character("n"), modifiers: [.command, .control])
                    ),
                    ShortcutBindingOverride(commandID: .openBookmarksPopover, shortcut: nil),
                ]
            )
        )

        sidebar.updateShortcutTooltips(customManager)

        XCTAssertEqual(sidebar.addWorklaneToolTipForTesting, "New Worklane (⌘⌃N)")
        XCTAssertEqual(sidebar.bookmarksToolTipForTesting, "Bookmarks & Presets")
    }

    func test_render_skipsWorkWhenSummariesAndThemeAreUnchanged() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        let summaries = [makeSummary(worklaneID: "main", primaryText: "demo")]

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(sidebar.debugSnapshotForTesting.renderInvocationCount, 1)

        sidebar.render(summaries: summaries, theme: theme)
        XCTAssertEqual(
            sidebar.debugSnapshotForTesting.renderInvocationCount,
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
        XCTAssertEqual(sidebar.debugSnapshotForTesting.renderInvocationCount, 1)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo updated")],
            theme: theme
        )
        XCTAssertEqual(sidebar.debugSnapshotForTesting.renderInvocationCount, 2)
    }

    func test_render_runsAgainWhenWorklaneListChanges() {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)

        sidebar.render(
            summaries: [makeSummary(worklaneID: "main", primaryText: "demo")],
            theme: theme
        )
        XCTAssertEqual(sidebar.debugSnapshotForTesting.renderInvocationCount, 1)

        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "main", primaryText: "demo"),
                makeSummary(worklaneID: "second", primaryText: "another"),
            ],
            theme: theme
        )
        XCTAssertEqual(sidebar.debugSnapshotForTesting.renderInvocationCount, 2)
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

    func test_dragPreview_reordersButtonsAndLeavesInvisibleSpacerAtDropSlot() throws {
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
        XCTAssertEqual(buttonB.alphaValue, 1)
        let dragBackgroundAlpha = try XCTUnwrap(buttonB.debugSnapshotForTesting.backgroundColor?.alphaComponent)
        XCTAssertEqual(dragBackgroundAlpha, 1, accuracy: 0.001)

        sidebar.setDragPreview(
            draggedID: WorklaneID("B"),
            previewOrder: [WorklaneID("A"), WorklaneID("C"), WorklaneID("B")]
        )

        XCTAssertEqual(
            worklaneIDs(in: sidebar),
            [WorklaneID("A"), WorklaneID("C"), WorklaneID("B")]
        )
        XCTAssertEqual(
            sidebar.debugSnapshotForTesting.arrangedWorklaneIDs,
            [WorklaneID("A"), WorklaneID("C")]
        )
        XCTAssertEqual(
            arrangedSidebarItems(in: sidebar),
            ["A", "C", "spacer"]
        )
        XCTAssertEqual(sidebar.debugSnapshotForTesting.reorderSpacerHeight, draggedHeight, accuracy: 0.001)
        XCTAssertEqual(sidebar.debugSnapshotForTesting.reorderPreviewLastAnimationDuration, 0)
        XCTAssertTrue(buttonB === worklaneButton(in: sidebar, id: "B"))
        XCTAssertNotNil(buttonB.superview)

        sidebar.setDragPreview(
            draggedID: WorklaneID("B"),
            previewOrder: [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")]
        )

        XCTAssertEqual(
            arrangedSidebarItems(in: sidebar),
            ["A", "spacer", "C"]
        )
        XCTAssertGreaterThan(sidebar.debugSnapshotForTesting.reorderPreviewLastAnimationDuration ?? 0, 0)
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
            sidebar.debugSnapshotForTesting.arrangedWorklaneIDs,
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
            sidebar.debugSnapshotForTesting.arrangedWorklaneIDs,
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

        let frames = sidebar.debugSnapshotForTesting.worklaneRowFramesForReordering
        XCTAssertEqual(frames.map(\.0), [WorklaneID("A"), WorklaneID("B"), WorklaneID("C")])
        XCTAssertLessThan(frames[0].1.midY, frames[1].1.midY)
        XCTAssertLessThan(frames[1].1.midY, frames[2].1.midY)
    }

    func test_sidebarPaneInsertionLine_rendersAboveRaisedActiveRowsAndClipsToRoundedShape() throws {
        let lineContainer = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        lineContainer.wantsLayer = true
        let targetStack = NSStackView(frame: lineContainer.bounds)
        lineContainer.addSubview(targetStack)
        let targetButton = SidebarWorklaneRowButton(worklaneID: WorklaneID("active"))
        targetButton.frame = NSRect(x: 0, y: 48, width: 240, height: 80)
        targetButton.layer?.zPosition = 10
        lineContainer.addSubview(targetButton)

        let presenter = SidebarPaneDropPresenter(targetStack: targetStack, lineContainer: lineContainer)

        presenter.showInsertionLine(
            SidebarPaneInsertionLineTarget(worklaneID: WorklaneID("active"), y: 88),
            buttons: [targetButton]
        )

        let line = try XCTUnwrap(lineContainer.subviews.compactMap { $0 as? PaneDragInsertionLineView }.first)
        XCTAssertGreaterThan(line.layer?.zPosition ?? 0, targetButton.layer?.zPosition ?? 0)
        XCTAssertEqual(line.layer?.masksToBounds, true)
        XCTAssertEqual(line.layer?.cornerRadius ?? 0, 2, accuracy: 0.001)
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
            XCTAssertFalse(sidebar.debugListStackHasConstraintsReferencingView(removedButton))
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
            buttonA?.debugSnapshotForTesting.primaryTextColor.srgbClamped,
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
        XCTAssertEqual(
            SidebarResizeModel.proposedWidth(
                startWidth: 280,
                translation: 80
            ),
            360,
            accuracy: 0.001
        )
    }

    func test_bookmark_icon_sits_slightly_above_button_center() throws {
        let sidebar = makeSidebar()

        sidebar.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(bookmarksButton(in: sidebar))
        button.layoutSubtreeIfNeeded()
        let iconView = try XCTUnwrap(button.subviews.compactMap { $0 as? NSImageView }.first)
        let verticalOffset = button.isFlipped
            ? button.bounds.midY - iconView.frame.midY
            : iconView.frame.midY - button.bounds.midY

        XCTAssertTrue(
            (3...4).contains(verticalOffset),
            "Expected bookmark icon to sit 3-4px above center, got \(verticalOffset)"
        )
    }

    func test_worklaneContextMenusReflectCanonicalMoveAvailability() throws {
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

        let event = try makeContextMenuEvent()
        let buttons = try sidebarWorklaneButtons(in: sidebar)

        XCTAssertEqual(
            menuTitles(buttons[0].menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Down",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )
        XCTAssertEqual(
            menuTitles(buttons[1].menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Up",
                "Move Worklane Down",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )
        XCTAssertEqual(
            menuTitles(buttons[2].menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Up",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )
    }

    func test_worklaneContextMoveCommandsCommitAdjacentTargetIndexes() throws {
        let sidebar = makeSidebar()
        let theme = ZenttyTheme.fallback(for: nil)
        var moves: [(WorklaneID, Int)] = []
        sidebar.onWorklaneReorderCommitted = { worklaneID, targetIndex in
            moves.append((worklaneID, targetIndex))
            return true
        }
        sidebar.render(
            summaries: [
                makeSummary(worklaneID: "A", primaryText: "a"),
                makeSummary(worklaneID: "B", primaryText: "b"),
                makeSummary(worklaneID: "C", primaryText: "c"),
            ],
            theme: theme
        )

        let button = try XCTUnwrap(worklaneButton(in: sidebar, id: "B"))
        let menu = try XCTUnwrap(button.menu(for: try makeContextMenuEvent()))
        let moveUp = try XCTUnwrap(menu.item(withTitle: "Move Worklane Up"))
        let moveDown = try XCTUnwrap(menu.item(withTitle: "Move Worklane Down"))

        NSApp.sendAction(try XCTUnwrap(moveUp.action), to: moveUp.target, from: moveUp)
        NSApp.sendAction(try XCTUnwrap(moveDown.action), to: moveDown.target, from: moveDown)

        XCTAssertEqual(moves.map(\.0), [WorklaneID("B"), WorklaneID("B")])
        XCTAssertEqual(moves.map(\.1), [0, 2])
    }

    private func worklaneButton(
        in sidebar: SidebarView,
        id: String
    ) -> SidebarWorklaneRowButton? {
        sidebar.debugSnapshotForTesting.worklaneButtons.compactMap {
            $0 as? SidebarWorklaneRowButton
        }.first { $0.worklaneID == WorklaneID(id) }
    }

    private func worklaneIDs(in sidebar: SidebarView) -> [WorklaneID] {
        sidebar.debugSnapshotForTesting.worklaneButtons.compactMap {
            ($0 as? SidebarWorklaneRowButton)?.worklaneID
        }
    }

    private func bookmarksButton(in view: NSView) -> SidebarBookmarksButton? {
        if let button = view as? SidebarBookmarksButton {
            return button
        }

        for subview in view.subviews {
            if let button = bookmarksButton(in: subview) {
                return button
            }
        }
        return nil
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

    private func makeContextMenuEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: 12, y: 12),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )
    }

    private func menuTitles(_ menu: NSMenu?) -> [String] {
        menuTitles(menu ?? NSMenu())
    }

    private func menuTitles(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { item in
            item.isSeparatorItem ? nil : item.title
        }
    }

    private func sidebarWorklaneButtons(in sidebarView: SidebarView) throws
        -> [SidebarWorklaneRowButton]
    {
        try sidebarView.debugSnapshotForTesting.worklaneButtons.map { button in
            try XCTUnwrap(button as? SidebarWorklaneRowButton)
        }
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
