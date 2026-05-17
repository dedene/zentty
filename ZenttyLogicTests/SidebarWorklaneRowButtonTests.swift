import AppKit
import XCTest

@testable import Zentty

@MainActor
final class SidebarWorklaneRowButtonTests: AppKitTestCase {
    private var rowWidthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]

    func test_working_worklane_row_does_not_animate_until_it_is_hosted_in_a_visible_sidebar() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary)
                ],
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertTrue(row.debugSnapshotForTesting.isWorking)
        XCTAssertFalse(row.debugSnapshotForTesting.shimmerIsAnimating)
        XCTAssertFalse(row.debugSnapshotForTesting.statusShimmerIsAnimating)
    }

    func test_working_worklane_row_keeps_primary_single_line_and_exposes_context_prefix_row() throws
    {
        // Regression: commit 191703a added wrap support for the primary text
        // and hid `primaryLabel` (the shimmer overlay) when the text wrapped,
        // which killed the shimmer animation on running agents. We instead
        // keep the primary single-line with tail truncation and surface the
        // disambiguation delta on a dedicated small-font row.
        let sidebarView = makeRenderableSidebarView(width: 260, height: 240)
        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "1",
                    primaryText: "feature/shimmer-regression · zentty",
                    contextPrefixText: "…/Development",
                    statusText: "Running",
                    attentionState: .running,
                    isWorking: true,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        let window = makeVisibleWindow(containing: sidebarView)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
        }
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)
        sidebarView.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            sidebarView.debugSnapshotForTesting.worklaneButtons.first as? SidebarWorklaneRowButton
        )

        XCTAssertTrue(row.debugSnapshotForTesting.isWorking)
        XCTAssertFalse(
            row.debugSnapshotForTesting.primaryShimmerViewIsHidden,
            "primary shimmer view must stay visible on running rows — this is the 191703a regression"
        )
        XCTAssertEqual(row.debugSnapshotForTesting.primaryBaseLabelMaximumNumberOfLines, 1)
        XCTAssertTrue(row.debugSnapshotForTesting.shimmerIsAnimating)
        XCTAssertTrue(row.debugSnapshotForTesting.contextPrefixRowIsVisible)
        XCTAssertEqual(row.debugSnapshotForTesting.contextPrefixText, "…/Development")
    }

    func test_idle_worklane_row_stays_static_when_it_is_not_hosted_in_a_visible_sidebar() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        XCTAssertFalse(row.debugSnapshotForTesting.shimmerIsAnimating)
        XCTAssertFalse(row.debugSnapshotForTesting.statusShimmerIsAnimating)

        row.configure(
            with: makeSummary(primaryText: "project"),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertFalse(row.debugSnapshotForTesting.isWorking)
        XCTAssertFalse(row.debugSnapshotForTesting.shimmerIsAnimating)
        XCTAssertFalse(row.debugSnapshotForTesting.statusShimmerIsAnimating)
    }

    func test_working_active_worklane_row_uses_distinct_background_tint() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: makeSummary(primaryText: "Claude Code", isActive: true),
            theme: theme,
            animated: false
        )
        let idleBackground = try! XCTUnwrap(
            row.debugSnapshotForTesting.backgroundColor?.usingColorSpace(.deviceRGB))

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true,
                isActive: true
            ),
            theme: theme,
            animated: false
        )
        let workingBackground = try! XCTUnwrap(
            row.debugSnapshotForTesting.backgroundColor?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(
            abs(idleBackground.redComponent - workingBackground.redComponent), 0.001)
        XCTAssertGreaterThan(
            abs(idleBackground.greenComponent - workingBackground.greenComponent), 0.001)
        XCTAssertFalse(row.debugSnapshotForTesting.shimmerIsAnimating)
    }

    func test_working_inactive_worklane_row_keeps_same_background_as_idle_inactive_row() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: makeSummary(primaryText: "Claude Code", isActive: false),
            theme: theme,
            animated: false
        )
        let idleBackground = try! XCTUnwrap(
            row.debugSnapshotForTesting.backgroundColor?.usingColorSpace(.deviceRGB))

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true,
                isActive: false
            ),
            theme: theme,
            animated: false
        )
        let workingBackground = try! XCTUnwrap(
            row.debugSnapshotForTesting.backgroundColor?.usingColorSpace(.deviceRGB))

        XCTAssertEqual(idleBackground.redComponent, workingBackground.redComponent, accuracy: 0.001)
        XCTAssertEqual(
            idleBackground.greenComponent, workingBackground.greenComponent, accuracy: 0.001)
        XCTAssertEqual(
            idleBackground.blueComponent, workingBackground.blueComponent, accuracy: 0.001)
        XCTAssertEqual(
            idleBackground.alphaComponent, workingBackground.alphaComponent, accuracy: 0.001)
    }

    func test_reorderDragAppearance_usesSolidVersionOfSidebarRowBackground() throws {
        let row = makeRow()
        let theme = darkTheme(foreground: "#E8EEF7")

        row.configure(
            with: makeSummary(primaryText: "Claude Code", isActive: false),
            theme: theme,
            animated: false
        )
        let normalBackground = try XCTUnwrap(row.debugSnapshotForTesting.backgroundColor?.srgbClamped)
        XCTAssertLessThan(normalBackground.alphaComponent, 1)

        row.setReorderDragActive(true)

        let dragBackground = try XCTUnwrap(row.debugSnapshotForTesting.backgroundColor?.srgbClamped)
        let sidebarSurface = theme.sidebarBackground.composited(over: theme.windowBackground)
        let expectedBackground = normalBackground
            .composited(over: sidebarSurface)
            .srgbClamped
            .withAlphaComponent(1)
        XCTAssertEqual(dragBackground.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(dragBackground.redComponent, expectedBackground.redComponent, accuracy: 0.001)
        XCTAssertEqual(dragBackground.greenComponent, expectedBackground.greenComponent, accuracy: 0.001)
        XCTAssertEqual(dragBackground.blueComponent, expectedBackground.blueComponent, accuracy: 0.001)

        row.setReorderDragActive(false)

        let restoredBackground = try XCTUnwrap(row.debugSnapshotForTesting.backgroundColor?.srgbClamped)
        XCTAssertEqual(restoredBackground.alphaComponent, normalBackground.alphaComponent, accuracy: 0.001)
        XCTAssertEqual(restoredBackground.redComponent, normalBackground.redComponent, accuracy: 0.001)
        XCTAssertEqual(restoredBackground.greenComponent, normalBackground.greenComponent, accuracy: 0.001)
        XCTAssertEqual(restoredBackground.blueComponent, normalBackground.blueComponent, accuracy: 0.001)
    }

    func test_worklaneContextMenu_hidesUnavailableMoveCommandsAtEdges() throws {
        let event = try makeContextMenuEvent()
        let row = makeRow()
        row.configure(
            with: makeSummary(primaryText: "Claude Code"),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        row.setWorklaneMoveAvailability(.init(canMoveUp: false, canMoveDown: false))
        XCTAssertEqual(
            menuTitles(row.menu(for: event)),
            ["Close Worklane", "Worklane Color", "Bookmark Worklane…", "Save as Preset…"]
        )

        row.setWorklaneMoveAvailability(.init(canMoveUp: false, canMoveDown: true))
        XCTAssertEqual(
            menuTitles(row.menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Down",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )

        row.setWorklaneMoveAvailability(.init(canMoveUp: true, canMoveDown: true))
        XCTAssertEqual(
            menuTitles(row.menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Up",
                "Move Worklane Down",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )

        row.setWorklaneMoveAvailability(.init(canMoveUp: true, canMoveDown: false))
        XCTAssertEqual(
            menuTitles(row.menu(for: event)),
            [
                "Close Worklane",
                "Move Worklane Up",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
            ]
        )
    }

    func test_worklaneContextMenu_worklaneItemsUseIconsAndInvokeCallbacks() throws {
        let event = try makeContextMenuEvent()
        let row = makeRow()
        var closeCount = 0
        var moves: [(WorklaneID, SidebarWorklaneMoveDirection)] = []
        row.onCloseWorklaneRequested = {
            closeCount += 1
        }
        row.onWorklaneMoveRequested = { worklaneID, direction in
            moves.append((worklaneID, direction))
        }
        row.setWorklaneMoveAvailability(.init(canMoveUp: true, canMoveDown: true))
        row.configure(
            with: makeSummary(primaryText: "Claude Code"),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.menu(for: event))
        let closeWorklane = try XCTUnwrap(menu.item(withTitle: "Close Worklane"))
        let moveUp = try XCTUnwrap(menu.item(withTitle: "Move Worklane Up"))
        let moveDown = try XCTUnwrap(menu.item(withTitle: "Move Worklane Down"))
        let color = try XCTUnwrap(menu.item(withTitle: "Worklane Color"))

        XCTAssertNotNil(closeWorklane.image)
        XCTAssertNotNil(moveUp.image)
        XCTAssertNotNil(moveDown.image)
        XCTAssertNotNil(color.image)

        NSApp.sendAction(try XCTUnwrap(closeWorklane.action), to: closeWorklane.target, from: closeWorklane)
        NSApp.sendAction(try XCTUnwrap(moveUp.action), to: moveUp.target, from: moveUp)
        NSApp.sendAction(try XCTUnwrap(moveDown.action), to: moveDown.target, from: moveDown)

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(moves.map(\.0), [WorklaneID("worklane-main"), WorklaneID("worklane-main")])
        XCTAssertEqual(moves.map(\.1), [.up, .down])
    }

    func test_paneRowContextMenu_sharesWorklaneItemsAndIncludesPaneOnlyItems() throws {
        let row = makeRow(width: 320, height: 110)
        row.setWorklaneMoveAvailability(.init(canMoveUp: true, canMoveDown: true))
        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [makePaneRow(isFocused: true)]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.debugMenuForTesting(.firstPaneRow, event: try makeContextMenuEvent()))

        XCTAssertEqual(
            menuTitles(menu),
            [
                "Close Worklane",
                "Move Worklane Up",
                "Move Worklane Down",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
                "Add Pane Right",
                "Add Pane Left",
                "New Pane Below",
                "Split Right",
                "Move Pane to New Window",
            ]
        )
        for title in menuTitles(menu) {
            XCTAssertNotNil(menu.item(withTitle: title)?.image, "\(title) should have an icon")
        }
    }

    func test_paneRowContextMenu_places_restored_command_rerun_first_when_available() throws {
        let row = makeRow(width: 320, height: 110)
        let command = "pnpm start:staging\nnpm run smoke"
        row.restoredRerunnableCommandProvider = { paneID in
            paneID == PaneID("worklane-main-pane") ? command : nil
        }
        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [makePaneRow(isFocused: true)]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.debugMenuForTesting(.firstPaneRow, event: try makeContextMenuEvent()))

        XCTAssertEqual(menu.items[0].title, "Run Last Command Again")
        XCTAssertEqual(menu.items[0].toolTip, command)
        XCTAssertNotNil(menu.items[0].image)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }

    func test_paneRowContextMenu_rerunCommandInvokesPaneCallback() throws {
        let row = makeRow(width: 320, height: 110)
        let paneID = PaneID("worklane-main-pane")
        var requestedPaneID: PaneID?
        row.restoredRerunnableCommandProvider = { $0 == paneID ? "pnpm start:staging" : nil }
        row.onRunRestoredCommand = { requestedPaneID = $0 }
        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [makePaneRow(isFocused: true)]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.debugMenuForTesting(.firstPaneRow, event: try makeContextMenuEvent()))
        let item = try XCTUnwrap(menu.item(withTitle: "Run Last Command Again"))

        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertEqual(requestedPaneID, paneID)
    }

    func test_paneRowContextMenu_showsClosePaneOnlyWhenMultiplePanesExist() throws {
        let row = makeRow(width: 320, height: 170)
        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    makePaneRow(paneID: "worklane-main-pane-a", isFocused: true),
                    makePaneRow(paneID: "worklane-main-pane-b", isFocused: false),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.debugMenuForTesting(.firstPaneRow, event: try makeContextMenuEvent()))

        XCTAssertNotNil(menu.item(withTitle: "Close Pane"))
        XCTAssertEqual(
            menuTitles(menu),
            [
                "Close Worklane",
                "Close Pane",
                "Worklane Color",
                "Bookmark Worklane…",
                "Save as Preset…",
                "Add Pane Right",
                "Add Pane Left",
                "New Pane Below",
                "Split Right",
                "Move Pane to New Window",
            ]
        )
    }

    func test_paneRowContextMenu_disablesMoveToWindowForOnlyPaneInOnlyWorklane() throws {
        let row = makeRow(width: 320, height: 110)
        row.isOnlyWorklane = true
        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [makePaneRow(isFocused: true)]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let menu = try XCTUnwrap(row.debugMenuForTesting(.firstPaneRow, event: try makeContextMenuEvent()))
        let moveToWindow = try XCTUnwrap(menu.item(withTitle: "Move Pane to New Window"))

        XCTAssertFalse(moveToWindow.isEnabled)
    }

    func test_worklane_row_exposes_plain_status_copy() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary)
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Needs input")
        XCTAssertEqual(row.debugSnapshotForTesting.statusSymbolName, "")
    }

    func test_worklane_row_prefers_specific_top_level_question_copy_and_icon() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                attentionState: .needsInput,
                interactionKind: .question,
                interactionLabel: "Needs decision",
                interactionSymbolName: "list.bullet"
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Needs decision")
        XCTAssertEqual(row.debugSnapshotForTesting.statusSymbolName, "list.bullet")
        let theme = ZenttyTheme.fallback(for: nil)
        XCTAssertEqual(
            row.debugSnapshotForTesting.statusTextColor.srgbClamped,
            theme.statusNeedsInput.srgbClamped
        )
    }

    func test_worklane_row_renders_pane_local_branch_detail_and_status_lines() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
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
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTexts, ["General coding assistance session"])
        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, ["main"])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, ["…/nimbu"])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["╰ Idle"])

        let paneRowMinX = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowMinX)
        let paneRowMaxTrailingInset = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowMaxTrailingInset)
        let paneRowContentMinX = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowContentMinX)
        let paneRowContentMaxTrailingInset = try! XCTUnwrap(
            row.debugSnapshotForTesting.firstPaneRowContentMaxTrailingInset
        )
        let paneRowMinY = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowMinY)
        let paneRowMaxTopInset = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowMaxTopInset)
        let paneRowContentMinY = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowContentMinY)
        let paneRowContentMaxTopInset = try! XCTUnwrap(
            row.debugSnapshotForTesting.firstPaneRowContentMaxTopInset
        )
        let paneRowCornerRadius = try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowCornerRadius)

        XCTAssertEqual(
            paneRowMinX,
            ShellMetrics.sidebarPaneRowHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowMaxTrailingInset,
            ShellMetrics.sidebarPaneRowHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowContentMinX,
            ShellMetrics.sidebarPaneButtonHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowContentMaxTrailingInset,
            ShellMetrics.sidebarPaneButtonHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowMinY,
            ShellMetrics.sidebarPaneRowVerticalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowMaxTopInset,
            ShellMetrics.sidebarPaneRowVerticalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowContentMinY,
            ShellMetrics.sidebarPaneButtonVerticalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            paneRowContentMaxTopInset,
            ShellMetrics.sidebarPaneButtonVerticalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(ShellMetrics.sidebarPaneRowHorizontalInset, 6)
        XCTAssertEqual(ShellMetrics.sidebarPaneRowVerticalInset, 6)
        XCTAssertEqual(ShellMetrics.sidebarPaneButtonHorizontalInset, 6)
        XCTAssertEqual(ShellMetrics.sidebarPaneButtonVerticalInset, 3.5, accuracy: 0.001)
        XCTAssertEqual(
            paneRowCornerRadius,
            ChromeGeometry.innerRadius(
                outerRadius: ShellMetrics.sidebarRowCornerRadius,
                inset: ShellMetrics.sidebarPaneRowHorizontalInset
            ),
            accuracy: 0.001
        )
    }

    func test_pane_server_ports_render_on_dedicated_line_with_delimiters_and_click_open() throws {
        let row = makeRow(width: 180)
        var selectedServerIDs: [String] = []
        row.onServerPortSelected = { selectedServerIDs.append($0) }

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                            WorklaneSidebarServerPort(serverID: "server-3000", port: 3000),
                        ]
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.paneServerPortTexts, [["5173", "/", "3000"]])
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneServerIconIsVisible)

        let serverRow = try XCTUnwrap(row.debugAccessForTesting.paneServerRows.first)
        let delimiterCenter = try XCTUnwrap(serverRow.delimiterCenterForTesting(index: 0))
        XCTAssertNil(serverRow.serverID(at: delimiterCenter))
        let firstPortFrame = try XCTUnwrap(serverRow.portFrameForTesting(index: 0))
        let delimiterFrame = try XCTUnwrap(serverRow.delimiterFrameForTesting(index: 0))
        let secondPortFrame = try XCTUnwrap(serverRow.portFrameForTesting(index: 1))
        XCTAssertGreaterThanOrEqual(delimiterFrame.width, 6)
        XCTAssertGreaterThanOrEqual(delimiterFrame.height, ShellMetrics.sidebarStatusLineHeight)
        XCTAssertLessThanOrEqual(delimiterFrame.minX - firstPortFrame.maxX, 1.5)
        XCTAssertLessThanOrEqual(secondPortFrame.minX - delimiterFrame.maxX, 1.5)

        row.performDebugInteractionForTesting(.firstPaneServerPortClick(index: 1))

        XCTAssertEqual(selectedServerIDs, ["server-3000"])
    }

    func test_pane_server_port_hover_uses_running_status_color_for_hovered_port_only() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let row = makeRow(width: 180)

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                            WorklaneSidebarServerPort(serverID: "server-3000", port: 3000),
                        ]
                    )
                ]
            ),
            theme: theme,
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let serverRow = try XCTUnwrap(row.debugAccessForTesting.paneServerRows.first)
        let normalPortColors = serverRow.portTextColorsForTesting.map(\.srgbClamped)

        serverRow.setHoveredPortForTesting(index: 1)

        let hoveredPortColors = serverRow.portTextColorsForTesting.map(\.srgbClamped)
        XCTAssertEqual(hoveredPortColors[1], theme.statusRunning.srgbClamped)
        XCTAssertEqual(hoveredPortColors[0], normalPortColors[0])
        XCTAssertEqual(serverRow.delimiterTextColorsForTesting.first?.srgbClamped, normalPortColors[0])
    }

    func test_pane_server_port_left_click_opens_server_without_selecting_pane() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
        let row = makeRow(width: 220, height: 120)
        row.frame.origin = NSPoint(x: 18, y: 7)
        container.addSubview(row)
        var selectedPaneIDs: [PaneID] = []
        var selectedServerIDs: [String] = []
        row.onPaneSelected = { selectedPaneIDs.append($0) }
        row.onServerPortSelected = { selectedServerIDs.append($0) }

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                        ]
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        container.layoutSubtreeIfNeeded()

        let serverRow = try XCTUnwrap(row.debugAccessForTesting.paneServerRows.first)
        let pointInServerRow = try XCTUnwrap(serverRow.firstPortCenterForTesting())
        let paneButton = try XCTUnwrap(row.debugAccessForTesting.paneRowButtons.first)

        paneButton.performPrimaryClickForTesting(at: paneButton.convert(pointInServerRow, from: serverRow))

        XCTAssertEqual(selectedServerIDs, ["server-5173"])
        XCTAssertEqual(selectedPaneIDs, [])
    }

    func test_pane_row_plain_text_left_click_selects_pane() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
        let row = makeRow(width: 220, height: 120)
        row.frame.origin = NSPoint(x: 18, y: 7)
        container.addSubview(row)
        var selectedPaneIDs: [PaneID] = []
        var selectedServerIDs: [String] = []
        row.onPaneSelected = { selectedPaneIDs.append($0) }
        row.onServerPortSelected = { selectedServerIDs.append($0) }

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                        ]
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        container.layoutSubtreeIfNeeded()

        let access = row.debugAccessForTesting
        let primaryRow = try XCTUnwrap(access.panePrimaryRows.first)
        let pointInPrimaryRow = NSPoint(x: primaryRow.bounds.midX, y: primaryRow.bounds.midY)
        let paneButton = try XCTUnwrap(access.paneRowButtons.first)

        paneButton.performPrimaryClickForTesting(at: paneButton.convert(pointInPrimaryRow, from: primaryRow))

        XCTAssertEqual(selectedPaneIDs, [PaneID("worklane-main-api")])
        XCTAssertEqual(selectedServerIDs, [])
    }

    func test_pane_server_port_right_click_uses_pane_context_menu() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
        let row = makeRow(width: 220, height: 120)
        row.frame.origin = NSPoint(x: 18, y: 7)
        container.addSubview(row)
        let window = makeVisibleWindow(containing: container)
        defer { window.close() }

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                        ]
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        container.layoutSubtreeIfNeeded()

        let access = row.debugAccessForTesting
        let serverRow = try XCTUnwrap(access.paneServerRows.first)
        let pointInServerRow = try XCTUnwrap(serverRow.firstPortCenterForTesting())
        let paneButton = try XCTUnwrap(access.paneRowButtons.first)
        let event = try makeMouseEvent(
            type: .rightMouseDown,
            location: paneButton.convert(pointInServerRow, from: serverRow),
            in: paneButton
        )

        let menu = try XCTUnwrap(paneButton.menu(for: event))

        XCTAssertTrue(menuTitles(menu).contains("Add Pane Right"))
        XCTAssertTrue(menuTitles(menu).contains("Split Right"))
    }

    func test_worklane_hit_test_uses_superview_coordinates_for_pane_rows() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        let row = makeRow(width: 220, height: 120)
        row.frame.origin = NSPoint(x: 300, y: 40)
        container.addSubview(row)

        row.configure(
            with: makeSummary(
                primaryText: "api",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-api"),
                        primaryText: "api",
                        trailingText: nil,
                        detailText: "…/api",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        serverPorts: [
                            WorklaneSidebarServerPort(serverID: "server-5173", port: 5173),
                        ]
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        container.layoutSubtreeIfNeeded()

        let paneButton = try XCTUnwrap(row.debugAccessForTesting.paneRowButtons.first)
        let pointInContainer = container.convert(
            NSPoint(x: paneButton.bounds.midX, y: paneButton.bounds.midY),
            from: paneButton
        )

        XCTAssertTrue(row.hitTest(pointInContainer) === paneButton)
    }

    func test_paneRowInsertionBoundaries_use_visual_edges_in_nonFlipped_target() throws {
        let target = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let row = makeRow(width: 320, height: 150)
        target.addSubview(row)
        row.frame = NSRect(x: 0, y: 20, width: 320, height: 150)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    makePaneRow(paneID: "top", isFocused: true),
                    makePaneRow(paneID: "bottom", isFocused: false),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        target.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()

        let access = row.debugAccessForTesting
        let frames = access.paneRowContainers.prefix(2).map {
            $0.convert($0.bounds, to: target)
        }
        XCTAssertEqual(frames.count, 2)

        let boundaries = row.paneRowInsertionBoundaries(in: target).map(\.y)

        XCTAssertEqual(boundaries.count, 3)
        XCTAssertEqual(boundaries[0], frames[0].maxY, accuracy: 0.5)
        XCTAssertEqual(boundaries[1], (frames[0].minY + frames[1].maxY) / 2, accuracy: 0.5)
        XCTAssertEqual(boundaries[2], frames[1].minY, accuracy: 0.5)
    }

    func test_paneRowInsertionBoundaries_only_use_currentPaneRows_afterReconfigure() {
        let target = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        let row = makeRow(width: 320, height: 190)
        target.addSubview(row)
        row.frame = NSRect(x: 0, y: 20, width: 320, height: 190)
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    makePaneRow(paneID: "one", isFocused: true),
                    makePaneRow(paneID: "two", isFocused: false),
                    makePaneRow(paneID: "three", isFocused: false),
                ]
            ),
            theme: theme,
            animated: false
        )
        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    makePaneRow(paneID: "one", isFocused: true),
                ]
            ),
            theme: theme,
            animated: false
        )
        target.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.paneRowInsertionBoundaries(in: target).count, 2)
    }

    func test_worklane_row_uses_tighter_main_text_inset() {
        let row = makeRow(width: 320, height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/sidebar", emphasis: .primary)
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let primaryTextMinX = try! XCTUnwrap(row.debugSnapshotForTesting.primaryTextMinX)
        let primaryTextMaxTrailingInset = try! XCTUnwrap(row.debugSnapshotForTesting.primaryTextMaxTrailingInset)

        XCTAssertEqual(
            primaryTextMinX,
            ShellMetrics.sidebarWorklaneTextHorizontalInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            primaryTextMaxTrailingInset,
            ShellMetrics.sidebarWorklaneTextHorizontalInset,
            accuracy: 0.5
        )
    }

    func test_single_pane_layout_uses_exact_pane_geometry_height() {
        let summary = makeSummary(
            primaryText: "General coding assistance session",
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
                )
            ]
        )

        let layout = SidebarWorklaneRowLayout(summary: summary)

        XCTAssertEqual(
            layout.rowHeight,
            (ShellMetrics.sidebarPaneRowVerticalInset * 2)
                + (ShellMetrics.sidebarPaneButtonVerticalInset * 2)
                + ShellMetrics.sidebarPrimaryLineHeight
                + ShellMetrics.sidebarDetailLineHeight
                + ShellMetrics.sidebarStatusLineHeight
                + (ShellMetrics.sidebarRowInterlineSpacing * 2),
            accuracy: 0.5
        )
    }

    func test_worklane_row_prefers_specific_pane_question_copy_and_icon() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: nil,
                        detailText: nil,
                        statusText: "╰ Needs input",
                        attentionState: .needsInput,
                        interactionKind: .question,
                        interactionLabel: "Needs decision",
                        interactionSymbolName: "list.bullet",
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["╰ Needs decision"])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusSymbolNames, ["list.bullet"])
        let theme = ZenttyTheme.fallback(for: nil)
        XCTAssertEqual(
            row.debugSnapshotForTesting.statusTextColor.srgbClamped,
            theme.statusNeedsInput.srgbClamped
        )
    }

    func test_worklane_row_renders_agent_ready_with_success_icon_from_sidebar_summary() {
        let row = makeRow(width: 320, height: 110)
        let paneID = PaneID("worklane-main-agent-ready")
        var auxiliaryState = PaneAuxiliaryState(
            metadata: TerminalMetadata(
                title: "General coding assistance session",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                processName: "codex",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true
            )
        )
        auxiliaryState.raw.lastDesktopNotificationText = "Agent run complete"
        auxiliaryState.raw.lastDesktopNotificationDate = Date(timeIntervalSince1970: 42)
        auxiliaryState.raw.showsReadyStatus = true
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "agent",
            raw: auxiliaryState.raw,
            previous: nil
        )
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        row.configure(
            with: WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Agent ready"])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusSymbolNames, ["checkmark.circle.fill"])
    }

    func test_worklane_row_renders_idle_with_sleep_icon_from_sidebar_summary() {
        let row = makeRow(width: 320, height: 110)
        let paneID = PaneID("worklane-main-agent-idle")
        let auxiliaryState = PaneAuxiliaryState(
            metadata: TerminalMetadata(
                title: "General coding assistance session",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                processName: "codex",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true
            )
        )
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        row.configure(
            with: WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Idle"])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusSymbolNames, ["moon.fill"])
    }

    func test_worklane_row_keeps_short_branch_trailing_for_single_pane_agent_rows() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "General coding assistance session",
                        trailingText: "main",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTexts, ["General coding assistance session"])
        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, ["main"])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, [])
    }

    func test_worklane_row_renders_path_primary_with_branch_in_trailing_slot() {
        let row = makeRow(width: 320, height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "zentty",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-path"),
                        primaryText: "…/zentty",
                        trailingText: "main",
                        detailText: nil,
                        statusText: nil,
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTexts, ["…/zentty"])
        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, ["main"])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, [])
    }

    func test_agent_ready_and_stopped_early_use_distinct_status_colors() {
        let readyRow = makeRow(width: 320, height: 110)
        let stoppedRow = makeRow(width: 320, height: 110)
        let theme = ZenttyTheme.fallback(for: nil)

        readyRow.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-ready"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: nil,
                        statusText: "Agent ready",
                        statusSymbolName: "checkmark.circle.fill",
                        attentionState: .ready,
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        stoppedRow.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-stopped"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: nil,
                        statusText: "Stopped early",
                        attentionState: .unresolvedStop,
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            readyRow.debugSnapshotForTesting.statusTextColor.srgbClamped, theme.statusReady.srgbClamped)
        XCTAssertEqual(
            stoppedRow.debugSnapshotForTesting.statusTextColor.srgbClamped, theme.statusStopped.srgbClamped)
        XCTAssertNotEqual(
            readyRow.debugSnapshotForTesting.statusTextColor.srgbClamped,
            stoppedRow.debugSnapshotForTesting.statusTextColor.srgbClamped)
    }

    func test_worklane_row_moves_long_branch_to_lower_metadata_row_when_width_is_tight() throws {
        let row = makeRow(width: 220, height: 130)
        let branch = "feature/autoresearch/zsh-startup-2026-03-22"
        let status = "Running"

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: branch,
                        detailText: nil,
                        statusText: status,
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTexts, ["Fix zsh startup"])
        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, [])

        let branchLabel = try XCTUnwrap(findLabel(withText: branch, in: row))
        let statusLabel = try XCTUnwrap(findLabel(withText: status, in: row))
        let branchMidY = row.convert(branchLabel.bounds, from: branchLabel).midY
        let statusMidY = row.convert(statusLabel.bounds, from: statusLabel).midY

        XCTAssertEqual(branchMidY, statusMidY, accuracy: 1.0)
    }

    func test_worklane_row_hides_long_branch_in_status_row_before_crushing_status_text() {
        let row = makeRow(width: 220, height: 130)
        let branch = "fix/tmpdir-redirect-to-shared-tmp-files"
        let status = "Run fix/tmpdir-redirect-to-shared-tmp-files"

        row.configure(
            with: makeSummary(
                primaryText: "Debug Claude API review failure in GitHub Actions",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Debug Claude API review failure in GitHub Actions",
                        trailingText: branch,
                        detailText: "…/nimbu",
                        statusText: status,
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, [status])
    }

    func test_worklane_row_restores_long_branch_to_trailing_slot_after_growing_wider() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, [])

        setRowWidth(row, to: 720)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            row.debugSnapshotForTesting.primaryTrailingTexts,
            ["feature/autoresearch/zsh-startup-2026-03-22"]
        )
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, [])
    }

    func test_worklane_row_restores_long_branch_in_status_row_after_growing_wider() {
        let row = makeRow(width: 220, height: 130)
        let branch = "fix/tmpdir-redirect-to-shared-tmp-files"
        let status = "Run fix/tmpdir-redirect-to-shared-tmp-files"

        row.configure(
            with: makeSummary(
                primaryText: "Debug Claude API review failure in GitHub Actions",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Debug Claude API review failure in GitHub Actions",
                        trailingText: branch,
                        detailText: "…/nimbu",
                        statusText: status,
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTrailingTexts, [])

        setRowWidth(row, to: 360)
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTrailingTexts, [branch])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, [status])
    }

    func test_worklane_row_moves_long_branch_to_lower_metadata_row_when_detail_is_already_present()
        throws
    {
        let row = makeRow(width: 220, height: 150)
        let branch = "feature/autoresearch/zsh-startup-2026-03-22"
        let status = "Agent ready"

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Ready | zentty · Verify adaptive multiline sidebar rows",
                        trailingText: branch,
                        detailText: "…/zentty",
                        statusText: status,
                        attentionState: .ready,
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, ["…/zentty"])

        let branchLabel = try XCTUnwrap(findLabel(withText: branch, in: row))
        let statusLabel = try XCTUnwrap(findLabel(withText: status, in: row))
        let branchMidY = row.convert(branchLabel.bounds, from: branchLabel).midY
        let statusMidY = row.convert(statusLabel.bounds, from: statusLabel).midY

        XCTAssertEqual(branchMidY, statusMidY, accuracy: 1.0)
    }

    func test_worklane_row_renders_branch_only_metadata_row_flush_left() throws {
        let row = makeRow(width: 220, height: 120)
        let branch = "feature/automatic-api-docs"

        row.configure(
            with: makeSummary(
                primaryText: "Ready | automatic-api-docs · Verify the adaptive sidebar branch row",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText:
                            "Ready | automatic-api-docs · Verify the adaptive sidebar branch row",
                        trailingText: branch,
                        detailText: nil,
                        statusText: nil,
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.debugSnapshotForTesting.primaryTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTrailingTexts, [])
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, [])

        let branchLabel = try XCTUnwrap(findLabel(withText: branch, in: row))
        let branchFrame = row.convert(branchLabel.bounds, from: branchLabel)
        let paneRowMinX = try XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowMinX)
        let paneContentMinX = try XCTUnwrap(row.debugSnapshotForTesting.firstPaneRowContentMinX)

        XCTAssertLessThanOrEqual(branchFrame.minX, paneRowMinX + paneContentMinX + 0.5)
    }

    func test_worklane_row_uses_middle_truncation_for_branch_in_shared_metadata_row() throws {
        let row = makeRow(width: 280, height: 150)
        let branch = "feature/automatic-api-docs"

        row.configure(
            with: makeSummary(
                primaryText: "Use AskUserQuestionTool",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Use AskUserQuestionTool",
                        trailingText: branch,
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let branchLabel = try XCTUnwrap(findLabel(withText: branch, in: row))

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTrailingTexts, [branch])
        XCTAssertEqual(branchLabel.lineBreakMode, .byTruncatingMiddle)
    }

    func test_sidebar_view_grows_worklane_row_to_keep_wrapped_worklane_labels_inside_bounds() throws
    {
        let primaryText =
            "Requires approval for a longer sidebar copy check that should wrap to a second line in tight widths"
        let statusText =
            "Needs approval from Peter before continuing with the longer follow-up action in this row"
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 320))

        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "1",
                    primaryText: primaryText,
                    statusText: statusText,
                    attentionState: .needsInput,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            sidebarView.debugSnapshotForTesting.worklaneButtons.first as? SidebarWorklaneRowButton)
        let primaryLabel = try XCTUnwrap(findLabel(withText: primaryText, in: row))
        let statusLabel = try XCTUnwrap(findLabel(withText: statusText, in: row))
        let primaryFrame = row.convert(primaryLabel.bounds, from: primaryLabel)
        let statusFrame = row.convert(statusLabel.bounds, from: statusLabel)

        XCTAssertGreaterThan(row.frame.height, ShellMetrics.sidebarCompactRowHeight + 0.5)
        XCTAssertLessThanOrEqual(primaryFrame.maxY, row.bounds.maxY + 0.5)
        XCTAssertLessThanOrEqual(statusFrame.maxY, row.bounds.maxY + 0.5)
    }

    func test_sidebar_view_keeps_long_pane_status_inside_single_line_bounds() throws {
        let primaryText = "Ready | zentty"
        let statusText =
            "Needs approval from Peter before continuing with the longer follow-up action in this pane row"
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 320))

        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "1",
                    primaryText: primaryText,
                    paneRows: [
                        WorklaneSidebarPaneRow(
                            paneID: PaneID("worklane-main-agent"),
                            primaryText: primaryText,
                            trailingText: nil,
                            detailText: nil,
                            statusText: statusText,
                            attentionState: .needsInput,
                            isFocused: true,
                            isWorking: false
                        )
                    ],
                    attentionState: .needsInput,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            sidebarView.debugSnapshotForTesting.worklaneButtons.first as? SidebarWorklaneRowButton)
        let statusLabel = try XCTUnwrap(findLabel(withText: statusText, in: row))
        let statusFrame = row.convert(statusLabel.bounds, from: statusLabel)

        XCTAssertGreaterThan(row.frame.height, ShellMetrics.sidebarCompactRowHeight + 0.5)
        XCTAssertLessThanOrEqual(statusFrame.maxY, row.bounds.maxY + 0.5)
    }

    func test_worklane_row_does_not_accumulate_duplicate_width_constraints_across_resizes() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneRowWidthConstraintCount, 1)

        setRowWidth(row, to: 260)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.debugSnapshotForTesting.paneRowWidthConstraintCount, 1)

        setRowWidth(row, to: 720)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.debugSnapshotForTesting.paneRowWidthConstraintCount, 1)
    }

    func
        test_worklane_row_deactivates_pane_width_constraints_when_switching_to_single_summary_layout()
    {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneRowWidthConstraintCount, 1)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneRowWidthConstraintCount, 0)
    }

    func test_worklane_row_moves_primary_view_to_focused_pane_position() {
        let row = makeRow(height: 92)

        row.configure(
            with: makeSummary(
                primaryText: "k8s-zenjoy",
                focusedPaneLineIndex: 1,
                detailLines: [
                    WorklaneSidebarDetailLine(
                        text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                    WorklaneSidebarDetailLine(text: "Personal", emphasis: .secondary),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.primaryRowIndex, 1)
        XCTAssertEqual(
            row.debugSnapshotForTesting.detailTexts, ["feature/scaleway-transactional-mails", "Personal"])
    }

    func test_working_worklane_row_uses_bright_title_shimmer_overlay() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertGreaterThanOrEqual(
            row.debugSnapshotForTesting.shimmerColor.perceivedLuminance,
            row.debugSnapshotForTesting.primaryTextColor.perceivedLuminance
        )
        XCTAssertEqual(
            row.debugSnapshotForTesting.primaryTextColor.srgbClamped,
            theme.sidebarButtonInactiveText.srgbClamped
        )
    }

    func test_running_status_uses_theme_status_running_color() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.statusTextColor.srgbClamped,
            theme.statusRunning.srgbClamped
        )
    }

    func test_worklane_status_task_progress_renders_indicator_between_icon_and_text() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Running")
        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressIndicatorIsVisible)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressFraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressToolTip, "")
        XCTAssertEqual(
            row.debugSnapshotForTesting.statusProgressColor.srgbClamped, theme.statusRunning.srgbClamped)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressRevealText, "2/5 tasks ・")
        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
    }

    func test_task_progress_indicator_starts_fill_at_top_and_advances_clockwise_through_right_side()
        throws
    {
        let indicator = SidebarTaskProgressIndicatorView(
            frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let arc = indicator.progressArcConfigurationForTesting

        XCTAssertEqual(arc.startAngle, .pi / 2, accuracy: 0.001)
        XCTAssertEqual(arc.endAngle, -(3 * .pi) / 2, accuracy: 0.001)
        XCTAssertTrue(arc.clockwise)
    }

    func test_worklane_status_task_progress_reveals_count_from_icon_until_status_line_exits() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)

        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: true))

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressRevealText, "2/5 tasks ・")
        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Running")
        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealLastUpdateWasAnimated)

        row.performDebugInteractionForTesting(.statusLineExit(pointerStillInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealLastUpdateWasAnimated)
        XCTAssertEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.statusProgressRevealLastAnimationDuration),
            0.12,
            accuracy: 0.001
        )
    }

    func test_worklane_status_task_progress_reveals_count_from_status_line_hover() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.statusLineHover)

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressRevealText, "2/5 tasks ・")
        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealLastUpdateWasAnimated)
        XCTAssertEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.statusProgressRevealLastAnimationDuration),
            0.16,
            accuracy: 0.001
        )
    }

    func
        test_worklane_status_task_progress_reveal_keeps_running_status_visible_when_space_is_tight()
    {
        let row = makeRow(width: 170, reducedMotion: true)
        let window = makeVisibleWindow(containing: row)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
        }
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 10),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: false))
        row.layoutSubtreeIfNeeded()

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsHidden)
        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Running")
        XCTAssertGreaterThanOrEqual(
            row.debugSnapshotForTesting.statusTextContainerWidth,
            SidebarTextMetrics.measuredWidth(for: "Running", font: ShellMetrics.sidebarStatusFont())
                - 1
        )
        XCTAssertGreaterThanOrEqual(
            row.debugSnapshotForTesting.statusProgressRevealWidth,
            SidebarTextMetrics.measuredWidth(
                for: "2/10 tasks ・", font: ShellMetrics.sidebarStatusFont()) - 1
        )
    }

    func test_worklane_status_task_progress_value_change_while_hovered_keeps_count_revealed() {
        let row = makeRow(width: 190, reducedMotion: true)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 10),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )
        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: false))

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 10),
                isWorking: true
            ),
            theme: theme,
            animated: true
        )
        row.layoutSubtreeIfNeeded()

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressRevealText, "2/10 tasks ・")
        XCTAssertGreaterThanOrEqual(
            row.debugSnapshotForTesting.statusProgressRevealWidth,
            SidebarTextMetrics.measuredWidth(
                for: "2/10 tasks ・", font: ShellMetrics.sidebarStatusFont()) - 1
        )
    }

    func
        test_worklane_status_task_progress_ignores_layout_exit_while_pointer_remains_on_status_line()
    {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: true))
        row.performDebugInteractionForTesting(.statusLineExit(pointerStillInsideLine: true))

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)

        row.performDebugInteractionForTesting(.statusLineExit(pointerStillInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
    }

    func test_worklane_status_task_progress_reconciliation_hides_after_missed_exit() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: true))
        row.performDebugInteractionForTesting(.statusLineHoverReconciliation(pointerInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
    }

    func test_worklane_status_task_progress_reveal_respects_reduced_motion() {
        let row = makeRow(reducedMotion: true)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.statusProgressIconHover(animated: true))

        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressRevealIsExpanded)
        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressRevealLastUpdateWasAnimated)
    }

    func test_worklane_status_task_progress_animates_value_changes() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )
        XCTAssertFalse(row.debugSnapshotForTesting.statusProgressLastUpdateWasAnimated)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 3, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: true
        )

        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressFraction, 0.6, accuracy: 0.001)
        XCTAssertTrue(row.debugSnapshotForTesting.statusProgressLastUpdateWasAnimated)
    }

    func test_pane_status_task_progress_renders_indicator_between_icon_and_text() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: "…/zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Idle"])
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressIndicatorIsVisible)
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusProgressFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusProgressToolTip, "")
        XCTAssertEqual(
            row.debugSnapshotForTesting.firstPaneStatusProgressColor?.srgbClamped, theme.statusRunning.srgbClamped
        )
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusProgressRevealText, "1/4 tasks ・")
        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
    }

    func test_pane_status_task_progress_reveals_count_from_icon_until_status_line_exits() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: "…/zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: true))

        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusProgressRevealText, "1/4 tasks ・")
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Idle"])
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastUpdateWasAnimated)

        row.performDebugInteractionForTesting(.firstPaneStatusLineExit(pointerStillInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastUpdateWasAnimated)
        XCTAssertEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastAnimationDuration),
            0.12,
            accuracy: 0.001
        )
    }

    func test_pane_status_task_progress_reveals_count_from_status_line_hover() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: ".../zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.firstPaneStatusLineHover)

        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusProgressRevealText, "1/4 tasks ・")
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastUpdateWasAnimated)
        XCTAssertEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastAnimationDuration),
            0.16,
            accuracy: 0.001
        )
    }

    func
        test_pane_status_task_progress_reveal_keeps_count_and_running_visible_by_shrinking_trailing_text()
    {
        let row = makeRow(width: 200, height: 110, reducedMotion: true)
        let window = makeVisibleWindow(containing: row)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
        }
        let theme = darkTheme(foreground: "#F0F3F6")
        let trailingText = "feature/reorder-worklanes"

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: trailingText,
                        detailText: ".../zentty",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 10)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: false))
        row.layoutSubtreeIfNeeded()

        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertFalse(try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsHidden))
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Running"])
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusTextContainerWidth),
            SidebarTextMetrics.measuredWidth(for: "Running", font: ShellMetrics.sidebarStatusFont())
                - 1
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealWidth),
            SidebarTextMetrics.measuredWidth(
                for: "1/10 tasks ・", font: ShellMetrics.sidebarStatusFont()) - 1
        )
        XCTAssertLessThan(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusTrailingLabelWidth),
            SidebarTextMetrics.measuredWidth(
                for: trailingText, font: ShellMetrics.sidebarDetailFont())
        )
    }

    func
        test_pane_status_task_progress_reveal_keeps_count_and_idle_visible_by_shrinking_trailing_text()
    {
        let row = makeRow(width: 170, height: 110, reducedMotion: true)
        let window = makeVisibleWindow(containing: row)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
        }
        let theme = darkTheme(foreground: "#F0F3F6")
        let trailingText = "feature/reorder-worklanes"

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: trailingText,
                        detailText: ".../zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 8)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: false))
        row.layoutSubtreeIfNeeded()

        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertFalse(try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsHidden))
        XCTAssertEqual(row.debugSnapshotForTesting.paneStatusTexts, ["Idle"])
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusTextContainerWidth),
            SidebarTextMetrics.measuredWidth(for: "Idle", font: ShellMetrics.sidebarStatusFont())
                - 1
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusProgressRevealWidth),
            SidebarTextMetrics.measuredWidth(
                for: "2/8 tasks ・", font: ShellMetrics.sidebarStatusFont()) - 1
        )
        XCTAssertLessThan(
            try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusTrailingLabelWidth),
            SidebarTextMetrics.measuredWidth(
                for: trailingText, font: ShellMetrics.sidebarDetailFont())
        )
    }

    func test_pane_status_task_progress_ignores_layout_exit_while_pointer_remains_on_status_line() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: ".../zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: true))
        row.performDebugInteractionForTesting(.firstPaneStatusLineExit(pointerStillInsideLine: true))

        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)

        row.performDebugInteractionForTesting(.firstPaneStatusLineExit(pointerStillInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
    }

    func test_pane_status_task_progress_reconciliation_hides_after_missed_exit() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: ".../zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: true))
        row.performDebugInteractionForTesting(.firstPaneStatusLineHoverReconciliation(pointerInsideLine: false))

        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
    }

    func test_pane_status_task_progress_exit_animation_survives_pane_hover_appearance_update() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: ".../zentty",
                        statusText: "Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false,
                        taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 4)
                    )
                ]
            ),
            theme: theme,
            animated: false
        )

        row.performDebugInteractionForTesting(.firstPaneStatusProgressIconHover(animated: true))
        row.performDebugInteractionForTesting(.firstPaneStatusLineExit(pointerStillInsideLine: false))
        row.paneRowHoverChanged(isHovered: false)

        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealIsExpanded)
        XCTAssertTrue(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastUpdateWasAnimated)
        XCTAssertFalse(row.debugSnapshotForTesting.firstPaneStatusProgressRevealLastConfigureSyncedPresentation)
    }

    func test_running_status_shimmer_preserves_hue_and_increases_saturation() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        let baseComponents = try! XCTUnwrap(hsbComponents(theme.statusRunning))
        let shimmerComponents = try! XCTUnwrap(hsbComponents(row.debugSnapshotForTesting.statusShimmerColor))

        XCTAssertEqual(shimmerComponents.hue, baseComponents.hue, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(shimmerComponents.saturation, baseComponents.saturation)
    }

    func test_working_pane_branch_stays_neutral_while_status_remains_semantic() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
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
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneTrailingTextColor).srgbClamped,
            theme.sidebarButtonInactiveText.withAlphaComponent(0.62).srgbClamped
        )
        XCTAssertEqual(
            try! XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusTextColor).srgbClamped,
            theme.statusRunning.srgbClamped
        )
    }

    func test_active_working_main_title_keeps_bright_base_text_and_uses_dark_shimmer_overlay() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true,
                isActive: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.primaryTextColor.srgbClamped,
            theme.sidebarButtonActiveText.srgbClamped
        )
        XCTAssertLessThan(
            row.debugSnapshotForTesting.shimmerColor.perceivedLuminance,
            row.debugSnapshotForTesting.primaryTextColor.perceivedLuminance
        )
    }

    func test_active_working_pane_title_keeps_bright_base_text_and_uses_dark_shimmer_overlay() {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: "…/zentty",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ],
                isWorking: true,
                isActive: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.firstPanePrimaryTextColor?.srgbClamped,
            theme.sidebarButtonActiveText.srgbClamped
        )
        XCTAssertLessThan(
            try! XCTUnwrap(row.debugSnapshotForTesting.firstPanePrimaryShimmerColor).perceivedLuminance,
            try! XCTUnwrap(row.debugSnapshotForTesting.firstPanePrimaryTextColor).perceivedLuminance
        )
    }

    func test_working_worklane_row_lifts_top_label_out_of_tertiary_text() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.topLabelColor.srgbClamped,
            theme.tertiaryText.srgbClamped
        )
    }

    func test_dark_background_with_dark_foreground_keeps_sidebar_row_text_light() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#101418")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "peter@m1-pro-peter:~/Development/Zentty"
            ),
            theme: theme,
            animated: false
        )

        XCTAssertGreaterThan(
            row.debugSnapshotForTesting.primaryTextColor.perceivedLuminance,
            theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(
            row.debugSnapshotForTesting.topLabelColor.perceivedLuminance,
            theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(
            row.debugSnapshotForTesting.primaryTextColor.contrastRatio(against: theme.sidebarBackground), 4.5)
    }

    func test_dark_sidebar_theme_forces_dark_row_appearance() {
        let row = makeRow()
        row.appearance = NSAppearance(named: .aqua)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "~"
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.appearanceMatch, .darkAqua)
    }

    func test_sidebar_row_disables_vibrancy() {
        XCTAssertFalse(makeRow().allowsVibrancy)
    }

    func test_worklane_row_ignores_legacy_sidebar_accessory_and_artifact_concepts() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "main • …/project", emphasis: .primary)
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.detailTexts, ["main • …/project"])
        XCTAssertEqual(row.debugSnapshotForTesting.statusText, "Needs input")
    }

    func test_sidebar_view_uses_a_single_shared_shimmer_driver_for_visible_working_rows() throws {
        let sidebarView = makeRenderableSidebarView(width: 280, height: 220)
        let window = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-web"),
                    primaryText: "Web",
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(
            buttons[0].debugSnapshotForTesting.shimmerCoordinatorIdentifier,
            buttons[1].debugSnapshotForTesting.shimmerCoordinatorIdentifier
        )
        XCTAssertTrue(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)
        XCTAssertTrue(buttons.allSatisfy(\.debugSnapshotForTesting.shimmerIsAnimating))
        XCTAssertTrue(window.isVisible)
    }

    func test_sidebar_view_uses_injected_window_renderability_policy_for_shimmer() throws {
        var isRenderable = false
        let sidebarView = SidebarView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 220),
            windowRenderabilityResolver: { _ in isRenderable }
        )
        _ = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API")
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        var buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertFalse(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)
        XCTAssertFalse(buttons.first?.debugSnapshotForTesting.shimmerIsAnimating ?? true)

        isRenderable = true
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertTrue(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)
        XCTAssertTrue(buttons.first?.debugSnapshotForTesting.shimmerIsAnimating ?? false)
    }

    func test_sidebar_view_assigns_distinct_phase_offsets_to_visible_working_rows() throws {
        let sidebarView = makeRenderableSidebarView(width: 280, height: 220)
        _ = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-web"), primaryText: "Web"),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertNotEqual(
            buttons[0].debugSnapshotForTesting.shimmerPhaseOffset,
            buttons[1].debugSnapshotForTesting.shimmerPhaseOffset
        )
    }

    func test_worklane_row_keeps_primary_and_status_shimmer_offsets_aligned() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.shimmerPhaseOffset,
            row.debugSnapshotForTesting.statusShimmerPhaseOffset
        )
    }

    func test_pane_row_keeps_primary_and_status_shimmer_offsets_aligned() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: "…/zentty",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    )
                ],
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(
            row.debugSnapshotForTesting.panePrimaryShimmerPhaseOffsets,
            row.debugSnapshotForTesting.paneStatusShimmerPhaseOffsets
        )
    }

    func test_pane_row_shimmer_offsets_follow_pane_ids_across_rerenders() {
        let row = makeRow(width: 320, height: 140)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-api"),
                        primaryText: "API",
                        trailingText: "main",
                        detailText: "…/api",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-web"),
                        primaryText: "Web",
                        trailingText: "feat/shimmer",
                        detailText: "…/web",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: false,
                        isWorking: true
                    ),
                ],
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let initialOffsets = row.debugSnapshotForTesting.panePrimaryShimmerPhaseOffsets
        XCTAssertEqual(initialOffsets.count, 2)
        XCTAssertNotEqual(initialOffsets[0], initialOffsets[1])

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-web"),
                        primaryText: "Web",
                        trailingText: "feat/shimmer",
                        detailText: "…/web",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-api"),
                        primaryText: "API",
                        trailingText: "main",
                        detailText: "…/api",
                        statusText: "╰ Running",
                        attentionState: .running,
                        isFocused: false,
                        isWorking: true
                    ),
                ],
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        let rerenderedOffsets = row.debugSnapshotForTesting.panePrimaryShimmerPhaseOffsets
        XCTAssertEqual(rerenderedOffsets.count, 2)
        XCTAssertEqual(rerenderedOffsets[0], initialOffsets[1])
        XCTAssertEqual(rerenderedOffsets[1], initialOffsets[0])
    }

    func test_sidebar_view_keeps_offscreen_working_rows_static() throws {
        let sidebarView = makeRenderableSidebarView(width: 280, height: 140)
        _ = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-web"), primaryText: "Web"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-cli"), primaryText: "CLI"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-docs"), primaryText: "Docs"),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertEqual(buttons.count, 4)
        XCTAssertTrue(buttons[0].debugSnapshotForTesting.shimmerIsAnimating)
        XCTAssertFalse(buttons.last?.debugSnapshotForTesting.shimmerIsAnimating ?? true)
        XCTAssertTrue(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)
    }

    func test_sidebar_view_pauses_shared_shimmer_driver_when_window_is_hidden() throws {
        let sidebarView = SidebarView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 220),
            windowRenderabilityResolver: { $0?.isVisible == true }
        )
        let window = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API")
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        XCTAssertTrue(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)

        window.orderOut(nil)
        sidebarView.performDebugActionForTesting(.updateShimmerVisibility)

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertFalse(sidebarView.debugSnapshotForTesting.shimmerDriverIsRunning)
        XCTAssertFalse(buttons.first?.debugSnapshotForTesting.shimmerIsAnimating ?? true)
    }

    func test_drop_target_highlight_keeps_layer_geometry_stable() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let row = makeRow(width: 280, height: 72)
        row.frame.origin = CGPoint(x: 20, y: 44)
        container.addSubview(row)
        container.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()

        let layer = try XCTUnwrap(row.layer)
        let originalAnchorPoint = layer.anchorPoint
        let originalPosition = layer.position
        let originalFrame = row.frame

        row.setDropTargetHighlighted(true)

        XCTAssertEqual(layer.anchorPoint.x, originalAnchorPoint.x, accuracy: 0.001)
        XCTAssertEqual(layer.anchorPoint.y, originalAnchorPoint.y, accuracy: 0.001)
        XCTAssertEqual(layer.position.x, originalPosition.x, accuracy: 0.001)
        XCTAssertEqual(layer.position.y, originalPosition.y, accuracy: 0.001)
        XCTAssertEqual(row.frame.origin.x, originalFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(row.frame.origin.y, originalFrame.origin.y, accuracy: 0.001)
        XCTAssertEqual(row.frame.size.width, originalFrame.size.width, accuracy: 0.001)
        XCTAssertEqual(row.frame.size.height, originalFrame.size.height, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m11, 1, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m22, 1, accuracy: 0.001)
    }

    func test_clearing_drop_target_highlight_restores_visual_state_without_moving_layer_geometry()
        throws
    {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let row = makeRow(width: 280, height: 72)
        row.configure(
            with: makeSummary(primaryText: "demo", statusText: "Running"),
            theme: .fallback(for: nil),
            animated: false
        )
        row.frame.origin = CGPoint(x: 20, y: 44)
        container.addSubview(row)
        container.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()

        let layer = try XCTUnwrap(row.layer)
        let originalAnchorPoint = layer.anchorPoint
        let originalPosition = layer.position
        let originalShadowOpacity = layer.shadowOpacity
        let originalShadowRadius = layer.shadowRadius

        row.setDropTargetHighlighted(true)
        row.setDropTargetHighlighted(false)

        XCTAssertEqual(layer.anchorPoint.x, originalAnchorPoint.x, accuracy: 0.001)
        XCTAssertEqual(layer.anchorPoint.y, originalAnchorPoint.y, accuracy: 0.001)
        XCTAssertEqual(layer.position.x, originalPosition.x, accuracy: 0.001)
        XCTAssertEqual(layer.position.y, originalPosition.y, accuracy: 0.001)
        XCTAssertEqual(layer.shadowOpacity, originalShadowOpacity, accuracy: 0.001)
        XCTAssertEqual(layer.shadowRadius, originalShadowRadius, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m11, 1, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m22, 1, accuracy: 0.001)
    }

    func test_drop_target_highlight_survives_appearance_refresh() throws {
        let row = makeRow(width: 280, height: 72)
        row.configure(
            with: makeSummary(primaryText: "demo", statusText: "Running"),
            theme: .fallback(for: nil),
            animated: false
        )
        row.layoutSubtreeIfNeeded()

        let layer = try XCTUnwrap(row.layer)
        row.setDropTargetHighlighted(true)
        let highlightedShadowOpacity = layer.shadowOpacity
        let highlightedShadowRadius = layer.shadowRadius
        let highlightedScale = layer.transform.m11

        row.performDebugInteractionForTesting(.setHovered(true))

        XCTAssertEqual(layer.shadowOpacity, highlightedShadowOpacity, accuracy: 0.001)
        XCTAssertEqual(layer.shadowRadius, highlightedShadowRadius, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m11, highlightedScale, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m11, 1, accuracy: 0.001)
        XCTAssertEqual(layer.transform.m22, 1, accuracy: 0.001)
    }

    func test_sidebar_insertion_line_is_rounded_and_inset_to_target_worklane() throws {
        let lineContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        lineContainer.addSubview(stack)

        let rowA = SidebarWorklaneRowButton(worklaneID: WorklaneID("A"), reducedMotionProvider: { true })
        rowA.frame = NSRect(x: 10, y: 150, width: 280, height: 44)
        let rowB = SidebarWorklaneRowButton(worklaneID: WorklaneID("B"), reducedMotionProvider: { true })
        rowB.frame = NSRect(x: 10, y: 80, width: 280, height: 44)
        stack.addSubview(rowA)
        stack.addSubview(rowB)

        let presenter = SidebarPaneDropPresenter(targetStack: stack, lineContainer: lineContainer)
        presenter.showInsertionLine(
            SidebarPaneInsertionLineTarget(worklaneID: WorklaneID("B"), y: 102),
            buttons: [rowA, rowB]
        )

        let line = try XCTUnwrap(lineContainer.subviews.compactMap { $0 as? PaneDragInsertionLineView }.first)
        XCTAssertEqual(line.frame.minX, rowB.frame.minX + ShellMetrics.sidebarPaneRowHorizontalInset, accuracy: 0.001)
        XCTAssertEqual(line.frame.width, rowB.frame.width - (ShellMetrics.sidebarPaneRowHorizontalInset * 2), accuracy: 0.001)
        XCTAssertEqual(line.frame.height, 4, accuracy: 0.001)
        XCTAssertEqual(line.frame.midY, 102, accuracy: 0.001)
        XCTAssertEqual(line.layer?.cornerRadius ?? 0, 2, accuracy: 0.001)
    }

    func test_configure_skipsWorkWhenSummaryThemeAndBoundsWidthAreUnchanged() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)
        let summary = makeSummary(primaryText: "demo", statusText: "Running")

        row.configure(with: summary, theme: theme, animated: false)
        XCTAssertEqual(row.debugSnapshotForTesting.configureApplyCount, 1)

        row.configure(with: summary, theme: theme, animated: false)
        XCTAssertEqual(
            row.debugSnapshotForTesting.configureApplyCount,
            1,
            "identical configure should not re-apply the resolved summary"
        )
    }

    func test_configure_runsAgainWhenSummaryChanges() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: makeSummary(primaryText: "demo", statusText: "Running"),
            theme: theme,
            animated: false
        )
        XCTAssertEqual(row.debugSnapshotForTesting.configureApplyCount, 1)

        row.configure(
            with: makeSummary(primaryText: "demo updated", statusText: "Running"),
            theme: theme,
            animated: false
        )
        XCTAssertEqual(row.debugSnapshotForTesting.configureApplyCount, 2)
    }

    func test_configure_runsAgainWhenBoundsWidthChanges() {
        let row = makeRow(width: 220)
        let theme = ZenttyTheme.fallback(for: nil)
        let summary = makeSummary(primaryText: "demo", statusText: "Running")

        row.configure(with: summary, theme: theme, animated: false)
        XCTAssertEqual(row.debugSnapshotForTesting.configureApplyCount, 1)

        setRowWidth(row, to: 360)
        row.configure(with: summary, theme: theme, animated: false)
        XCTAssertEqual(
            row.debugSnapshotForTesting.configureApplyCount,
            2,
            "bounds.width change must re-run configure to re-apply adaptive row layout"
        )
    }

    private func makeRow(
        width: CGFloat = 280,
        height: CGFloat = 72,
        reducedMotion: Bool = false
    ) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
            reducedMotionProvider: { reducedMotion }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let widthConstraint = row.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        rowWidthConstraints[ObjectIdentifier(row)] = widthConstraint
        return row
    }

    private func setRowWidth(_ row: SidebarWorklaneRowButton, to width: CGFloat) {
        rowWidthConstraints[ObjectIdentifier(row)]?.constant = width
        row.frame.size.width = width
    }

    private func makeSummary(
        topLabel: String? = nil,
        primaryText: String,
        contextPrefixText: String? = nil,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        detailLines: [WorklaneSidebarDetailLine] = [],
        paneRows: [WorklaneSidebarPaneRow] = [],
        attentionState: WorklaneAttentionState? = nil,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        taskProgress: PaneAgentTaskProgress? = nil,
        isWorking: Bool = false,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "1",
            topLabel: topLabel,
            primaryText: primaryText,
            contextPrefixText: contextPrefixText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusText,
            detailLines: detailLines,
            paneRows: paneRows,
            overflowText: nil,
            attentionState: attentionState,
            interactionKind: interactionKind,
            interactionLabel: interactionLabel,
            interactionSymbolName: interactionSymbolName,
            taskProgress: taskProgress,
            isWorking: isWorking,
            isActive: isActive
        )
    }

    private func makeSidebarSummary(
        worklaneID: WorklaneID,
        primaryText: String,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: worklaneID,
            badgeText: "1",
            topLabel: nil,
            primaryText: primaryText,
            statusText: "Running",
            detailLines: [],
            attentionState: .running,
            isWorking: true,
            isActive: isActive
        )
    }

    private func makePaneRow(
        paneID: String = "worklane-main-pane",
        isFocused: Bool
    ) -> WorklaneSidebarPaneRow {
        WorklaneSidebarPaneRow(
            paneID: PaneID(paneID),
            primaryText: "Claude Code",
            trailingText: "main",
            detailText: "…/zentty",
            statusText: "╰ Idle",
            attentionState: nil,
            isFocused: isFocused,
            isWorking: false
        )
    }

    private func makeRenderableSidebarView(width: CGFloat, height: CGFloat) -> SidebarView {
        SidebarView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            windowRenderabilityResolver: SidebarWindowRenderability.alwaysRenderableWindow
        )
    }

    private func makeVisibleWindow(containing sidebarView: SidebarView) -> NSWindow {
        let window = NSWindow(
            contentRect: sidebarView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        window.contentView = sidebarView
        window.orderFrontRegardless()
        return window
    }

    private func makeVisibleWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        window.contentView = view
        window.orderFrontRegardless()
        return window
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

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        in view: NSView
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(location, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
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

    private func darkTheme(foreground: String) -> ZenttyTheme {
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

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.srgbClamped
        let right = rhs.srgbClamped
        let red = left.redComponent - right.redComponent
        let green = left.greenComponent - right.greenComponent
        let blue = left.blueComponent - right.blueComponent
        return sqrt((red * red) + (green * green) + (blue * blue))
    }

    private func hsbComponents(_ color: NSColor) -> (
        hue: CGFloat, saturation: CGFloat, brightness: CGFloat
    )? {
        guard let converted = color.usingColorSpace(.deviceRGB) else {
            return nil
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
    }

    private func findLabel(withText text: String, in view: NSView) -> NSTextField? {
        if let label = view as? NSTextField, label.stringValue == text {
            return label
        }

        for subview in view.subviews {
            if let label = findLabel(withText: text, in: subview) {
                return label
            }
        }

        return nil
    }
}
