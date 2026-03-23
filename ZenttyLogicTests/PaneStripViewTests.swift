import AppKit
import XCTest
@testable import Zentty

final class PaneStripViewTests: XCTestCase {
    private let sidebarInset: CGFloat = 290

    @MainActor
    func test_pane_frames_keep_width_when_container_width_changes() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1400, height: 720))
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let wideFocusedWidth = paneStripView.descendantPaneViews()[1].frame.width
        let widePaneHeight = paneStripView.descendantPaneViews()[1].frame.height

        paneStripView.frame.size = NSSize(width: 900, height: 640)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let compactFocusedWidth = paneStripView.descendantPaneViews()[1].frame.width
        let compactPaneHeight = paneStripView.descendantPaneViews()[1].frame.height

        XCTAssertEqual(compactFocusedWidth, wideFocusedWidth, accuracy: 0.001)
        XCTAssertLessThan(compactPaneHeight, widePaneHeight)
    }

    @MainActor
    func test_pane_frames_grow_beyond_previous_fixed_height_when_container_is_tall() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820))
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(paneStripView.descendantPaneViews()[1].frame.height, 360)
    }

    @MainActor
    func test_single_pane_keeps_full_width_and_uses_balanced_bottom_gutter() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 1200),
            ],
            focusedPaneID: PaneID("shell")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(paneStripView.descendantPaneViews().first)

        XCTAssertEqual(paneView.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.maxX, paneStripView.bounds.width, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.minY, PaneLayoutSizing.balanced.bottomInset, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.maxY, paneStripView.bounds.height, accuracy: 0.001)
    }

    @MainActor
    func test_stacked_column_renders_first_pane_above_later_panes() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("top"), title: "top"),
                        PaneState(id: PaneID("middle"), title: "middle"),
                        PaneState(id: PaneID("bottom"), title: "bottom"),
                    ],
                    width: 640,
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let framesByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0.frame)
        })

        let topFrame = try XCTUnwrap(framesByTitle["top"])
        let middleFrame = try XCTUnwrap(framesByTitle["middle"])
        let bottomFrame = try XCTUnwrap(framesByTitle["bottom"])

        XCTAssertGreaterThan(topFrame.minY, middleFrame.minY)
        XCTAssertGreaterThan(middleFrame.minY, bottomFrame.minY)
    }

    @MainActor
    func test_stacked_column_height_resize_keeps_panes_disjoint_and_ordered() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("top"), title: "top"),
                        PaneState(id: PaneID("middle"), title: "middle"),
                        PaneState(id: PaneID("bottom"), title: "bottom"),
                    ],
                    width: 640,
                    focusedPaneID: PaneID("middle"),
                    lastFocusedPaneID: PaneID("middle")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.frame.size = NSSize(width: 1200, height: 820)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let framesByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0.frame)
        })

        let topFrame = try XCTUnwrap(framesByTitle["top"])
        let middleFrame = try XCTUnwrap(framesByTitle["middle"])
        let bottomFrame = try XCTUnwrap(framesByTitle["bottom"])

        XCTAssertGreaterThan(topFrame.minY, middleFrame.maxY)
        XCTAssertGreaterThan(middleFrame.minY, bottomFrame.maxY)
    }

    @MainActor
    func test_vertical_divider_translation_inverts_y_for_dragging() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))

        XCTAssertEqual(
            paneStripView.dividerTranslationForTesting(CGPoint(x: 0, y: 24), axis: .vertical),
            -24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            paneStripView.dividerTranslationForTesting(CGPoint(x: 18, y: 0), axis: .horizontal),
            18,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_horizontal_divider_uses_left_right_resize_cursor_affordance() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 420),
                PaneState(id: PaneID("right"), title: "right", width: 420),
            ],
            focusedPaneID: PaneID("left")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            paneStripView.dividerCursorDescriptionForTesting(.column(afterColumnID: PaneColumnID("column-left"))),
            "resizeLeftRight"
        )
    }

    @MainActor
    func test_vertical_divider_uses_up_down_resize_cursor_affordance() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("top"), title: "top"),
                        PaneState(id: PaneID("bottom"), title: "bottom"),
                    ],
                    width: 640,
                    focusedPaneID: PaneID("top"),
                    lastFocusedPaneID: PaneID("top")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            paneStripView.dividerCursorDescriptionForTesting(
                .pane(columnID: PaneColumnID("stack"), afterPaneID: PaneID("top"))
            ),
            "resizeUpDown"
        )
    }

    @MainActor
    func test_double_click_equalize_clears_divider_highlight_state() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let divider = PaneDivider.column(afterColumnID: PaneColumnID("column-left"))
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 420),
                PaneState(id: PaneID("right"), title: "right", width: 420),
            ],
            focusedPaneID: PaneID("left")
        )
        var equalizedDivider: PaneDivider?
        paneStripView.onDividerEqualizeRequested = { equalizedDivider = $0 }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.simulateDividerDoubleClickForTesting(divider)

        XCTAssertEqual(equalizedDivider, divider)
        XCTAssertEqual(paneStripView.dividerHighlightStateForTesting(divider)?.active, false)
        XCTAssertEqual(paneStripView.dividerHighlightStateForTesting(divider)?.highlighted, false)
    }

    @MainActor
    func test_render_publishes_border_chrome_snapshots_for_visible_panes() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 420),
                PaneState(id: PaneID("editor"), title: "editor", width: 420),
            ],
            focusedPaneID: PaneID("editor")
        )
        var snapshots: [PaneBorderChromeSnapshot] = []
        paneStripView.onBorderChromeSnapshotsDidChange = { snapshots = $0 }

        paneStripView.render(
            state,
            paneBorderContextByPaneID: [
                PaneID("editor"): PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(snapshots.map(\.paneID), [PaneID("shell"), PaneID("editor")])
        XCTAssertNil(snapshots[0].borderContext)
        XCTAssertEqual(snapshots[1].borderContext?.text, "~/src/zentty")
        XCTAssertTrue(snapshots[1].isFocused)
        XCTAssertEqual(
            snapshots[1].frame,
            try XCTUnwrap(paneStripView.descendantPaneViews().first { $0.titleText == "editor" }?.frame)
        )
    }

    @MainActor
    func test_pane_context_backdrop_stays_below_the_top_of_its_badge() throws {
        let overlayView = PaneBorderContextOverlayView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let paneID = PaneID("bottom")
        overlayView.render(
            snapshots: [
                PaneBorderChromeSnapshot(
                    paneID: paneID,
                    frame: CGRect(x: 0, y: 0, width: 640, height: 220),
                    isFocused: true,
                    emphasis: 1,
                    borderContext: PaneBorderContextDisplayModel(text: "peter@m1-pro-peter:~")
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        overlayView.layoutSubtreeIfNeeded()

        let badgeFrame = try XCTUnwrap(overlayView.paneContextFramesForTesting[paneID])
        let backdropFrame = try XCTUnwrap(overlayView.paneContextBackdropFramesForTesting[paneID])

        XCTAssertGreaterThan(backdropFrame.minY, 4)
        XCTAssertLessThan(backdropFrame.height, badgeFrame.height)
    }

    @MainActor
    func test_focus_change_repositions_visible_panes() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let editorFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
                makePane("shell"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let testsFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
                makePane("shell"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let initialFrames = Dictionary(uniqueKeysWithValues: paneStripView.descendantPaneViews().map { ($0.titleText, $0.frame) })

        paneStripView.render(testsFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let updatedFrames = Dictionary(uniqueKeysWithValues: paneStripView.descendantPaneViews().map { ($0.titleText, $0.frame) })

        XCTAssertLessThan(updatedFrames["editor"]!.minX, initialFrames["editor"]!.minX)
        XCTAssertLessThan(updatedFrames["tests"]!.midX, initialFrames["tests"]!.midX)
    }

    @MainActor
    func test_focus_change_keeps_panes_fully_opaque_during_animated_transition() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let editorFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let testsFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(testsFocused)

        let paneViewsByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })

        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["editor"]).alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["tests"]).alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func test_focus_change_restores_inactive_dimming_after_animation_settles() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let editorFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let testsFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(testsFocused)

        let settled = expectation(description: "focus animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        let paneViewsByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })

        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["editor"]).alphaValue,
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["tests"]).alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func test_rendered_pane_frames_stay_on_retina_pixel_grid_when_offset_is_fractional() {
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            backingScaleFactorProvider: { 2 }
        )
        paneStripView.leadingVisibleInset = 290.25
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 444.4),
                PaneState(id: PaneID("editor"), title: "editor", width: 355.55),
            ],
            focusedPaneID: PaneID("shell")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        for paneView in paneStripView.descendantPaneViews() {
            assertRetinaAligned(paneView.frame.minX)
            assertRetinaAligned(paneView.frame.maxX)
            assertRetinaAligned(paneView.frame.minY)
            assertRetinaAligned(paneView.frame.maxY)
        }
    }

    @MainActor
    func test_repeated_resize_round_trip_keeps_ratio_scaled_pane_frames_retina_aligned() {
        let initialContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1201,
            leadingVisibleInset: sidebarInset
        )
        let expandedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .largeDisplay,
            viewportWidth: 1437,
            leadingVisibleInset: sidebarInset
        )
        let store = WorkspaceStore(layoutContext: initialContext)
        store.send(.splitAfterFocusedPane)

        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1201, height: 680),
            backingScaleFactorProvider: { 2 }
        )
        paneStripView.leadingVisibleInset = sidebarInset

        paneStripView.render(store.state)
        paneStripView.layoutSubtreeIfNeeded()
        let initialFrames = paneStripView.descendantPaneViews().map { $0.frame }

        store.updateLayoutContext(expandedContext)
        paneStripView.frame.size = NSSize(width: 1437, height: 680)
        paneStripView.render(store.state)
        paneStripView.layoutSubtreeIfNeeded()
        let expandedFrames = paneStripView.descendantPaneViews().map { $0.frame }

        let returnedContext = PaneLayoutPreferences.default.makeLayoutContext(
            displayClass: .laptop,
            viewportWidth: 1201,
            leadingVisibleInset: sidebarInset
        )
        store.updateLayoutContext(returnedContext)
        paneStripView.frame.size = NSSize(width: 1201, height: 680)
        paneStripView.render(store.state)
        paneStripView.layoutSubtreeIfNeeded()
        let returnedFrames = paneStripView.descendantPaneViews().map { $0.frame }

        XCTAssertEqual(initialFrames.count, 2)
        XCTAssertEqual(expandedFrames.count, 2)
        XCTAssertEqual(returnedFrames.count, 2)

        for frame in initialFrames + expandedFrames + returnedFrames {
            assertRetinaAligned(frame.minX)
            assertRetinaAligned(frame.maxX)
            assertRetinaAligned(frame.minY)
            assertRetinaAligned(frame.maxY)
        }
    }

    @MainActor
    func test_leading_occlusion_mask_is_not_applied_at_rest() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = 290
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
            ],
            focusedPaneID: PaneID("shell")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneStripView.leadingMaskMinX, 0, accuracy: 0.001)
    }

    @MainActor
    func test_rightward_motion_does_not_toggle_occlusion_mask() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = 290
        let rightFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )
        let leftFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(rightFocused)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.render(leftFocused)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneStripView.leadingMaskMinX, 0, accuracy: 0.001)
    }

    @MainActor
    func test_leftward_motion_does_not_toggle_occlusion_mask() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = 290
        let leftFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let rightFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(leftFocused)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.render(rightFocused)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(paneStripView.leadingMaskMinX, 0, accuracy: 0.001)
    }

    @MainActor
    func test_leading_visible_inset_pushes_first_focused_pane_right_of_sidebar() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let insetStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        insetStripView.leadingVisibleInset = 290

        insetStripView.render(state)
        insetStripView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(insetStripView.descendantPaneViews()[0].frame.minX, 289.999)
    }

    @MainActor
    func test_navigate_back_to_first_pane_respects_leading_visible_inset_with_three_panes() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset

        let lastFocused = PaneStripState(
            panes: [makePane("shell"), makePane("editor"), makePane("tests")],
            focusedPaneID: PaneID("tests")
        )
        paneStripView.render(lastFocused)
        paneStripView.layoutSubtreeIfNeeded()

        let firstFocused = PaneStripState(
            panes: [makePane("shell"), makePane("editor"), makePane("tests")],
            focusedPaneID: PaneID("shell")
        )
        paneStripView.render(firstFocused)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            paneStripView.descendantPaneViews()[0].frame.minX,
            sidebarInset - 0.001
        )
    }

    @MainActor
    func test_leading_visible_inset_does_not_change_first_focused_pane_width() {
        let state = PaneStripState(
            panes: [
                makePane("shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let baselineStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let insetStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        insetStripView.leadingVisibleInset = 290

        baselineStripView.render(state)
        baselineStripView.layoutSubtreeIfNeeded()
        insetStripView.render(state)
        insetStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            insetStripView.descendantPaneViews()[0].frame.width,
            baselineStripView.descendantPaneViews()[0].frame.width,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_focus_change_does_not_change_rendered_pane_widths() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let firstFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let lastFocused = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(firstFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let firstFocusedWidths = paneStripView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.frame.width }

        paneStripView.render(lastFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let lastFocusedWidths = paneStripView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.frame.width }

        XCTAssertEqual(firstFocusedWidths, lastFocusedWidths)
    }

    @MainActor
    func test_workspace_switch_with_no_shared_panes_skips_cross_workspace_animation() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let mainState = PaneStripState(
            panes: [
                PaneState(id: PaneID("main-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("main-shell")
        )
        let workspace2State = PaneStripState(
            panes: [
                PaneState(id: PaneID("workspace-2-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("workspace-2-shell")
        )

        paneStripView.render(mainState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(workspace2State)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneStripView.lastRenderWasAnimated)
    }

    @MainActor
    func test_programmatic_resize_skips_inner_pane_animation() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.frame.size = NSSize(width: 1580, height: 820)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneStripView.lastRenderWasAnimated)
    }

    @MainActor
    func test_animation_resumes_for_same_size_state_changes_after_programmatic_resize() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let editorFocused = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let shellFocused = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("shell")
        )

        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.frame.size = NSSize(width: 1580, height: 820)
        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneStripView.lastRenderWasAnimated)

        paneStripView.render(shellFocused)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertTrue(paneStripView.lastRenderWasAnimated)
    }

    @MainActor
    func test_split_reuses_existing_pane_views_and_only_starts_one_new_session() {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 980, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellView = try? XCTUnwrap(paneStripView.descendantPaneViews().first)
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1])

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews()
        XCTAssertEqual(paneViews.count, 2)
        XCTAssertTrue(paneViews.contains(where: { $0 === originalShellView }))
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    @MainActor
    func test_resize_reuses_existing_pane_views_and_does_not_restart_sessions() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let originalPaneViews = try XCTUnwrap(
            Dictionary(
                uniqueKeysWithValues: paneStripView.descendantPaneViews().map { paneView in
                    (paneView.paneID, paneView)
                }
            )
        )
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])

        paneStripView.frame.size = NSSize(width: 1580, height: 820)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let resizedPaneViews = try XCTUnwrap(
            Dictionary(
                uniqueKeysWithValues: paneStripView.descendantPaneViews().map { paneView in
                    (paneView.paneID, paneView)
                }
            )
        )

        XCTAssertEqual(Set(resizedPaneViews.keys), Set(originalPaneViews.keys))
        for (paneID, paneView) in resizedPaneViews {
            XCTAssertTrue(paneView === originalPaneViews[paneID])
        }
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    @MainActor
    func test_single_pane_keeps_width_when_split_adds_new_column() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let originalWidth = originalShellView.frame.width

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()
        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertTrue(paneViews.contains(where: { $0 === originalShellView }))
        XCTAssertEqual(paneViews[0].frame.width, originalWidth, accuracy: 0.001)
        XCTAssertEqual(
            paneViews[1].frame.width,
            splitState.panes[1].width,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_first_split_scrolls_to_make_new_pane_visible_without_resizing_first_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let firstPane = try XCTUnwrap(paneViews.first)
        let lastPane = try XCTUnwrap(paneViews.last)

        XCTAssertEqual(firstPane.frame.width, splitState.panes[0].width, accuracy: 0.001)
        XCTAssertLessThan(firstPane.frame.minX, 0)
        XCTAssertLessThanOrEqual(lastPane.frame.maxX, paneStripView.bounds.width + 0.001)
    }

    @MainActor
    func test_split_from_single_pane_seeds_new_pane_from_right_edge_of_original_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellFrame = try XCTUnwrap(paneStripView.descendantPaneViews().first?.frame)
        let splitPresentation = PaneStripMotionController().presentation(
            for: splitState,
            in: paneStripView.bounds.size,
            leadingVisibleInset: sidebarInset
        )

        paneStripView.render(splitState)

        let transition = try XCTUnwrap(paneStripView.lastInsertionTransition)
        let finalFrame = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("pane-1") })?.frame
                .offsetBy(dx: -splitPresentation.targetOffset, dy: 0)
        )

        XCTAssertEqual(transition.side, .right)
        XCTAssertEqual(transition.paneID, PaneID("pane-1"))
        XCTAssertGreaterThan(transition.initialFrame.minX, originalShellFrame.maxX)
        XCTAssertGreaterThan(transition.initialFrame.minX, finalFrame.minX)
    }

    @MainActor
    func test_split_from_multi_pane_seeds_new_pane_from_right_of_left_neighbor() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let twoPaneState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(twoPaneState)
        paneStripView.layoutSubtreeIfNeeded()
        let editorFrame = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "editor" })?.frame
        )

        paneStripView.render(splitState)

        let transition = try XCTUnwrap(paneStripView.lastInsertionTransition)

        XCTAssertEqual(transition.side, .right)
        XCTAssertEqual(transition.paneID, PaneID("pane-1"))
        XCTAssertGreaterThan(transition.initialFrame.minX, editorFrame.maxX)
    }

    @MainActor
    func test_vertical_split_seeds_new_pane_below_focused_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let singlePane = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let splitState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                        PaneState(id: PaneID("pane-1"), title: "pane 1"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("pane-1"),
                    lastFocusedPaneID: PaneID("pane-1")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellFrame = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })?.frame
        )

        let splitPresentation = PaneStripMotionController().presentation(
            for: splitState,
            in: paneStripView.bounds.size
        )

        paneStripView.render(splitState)

        let transition = try XCTUnwrap(paneStripView.lastInsertionTransition)
        let finalFrame = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("pane-1") })?.frame
        )
        let sourceFrame = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("shell") })?.frame
        )

        XCTAssertEqual(transition.side, .bottom)
        XCTAssertEqual(transition.paneID, PaneID("pane-1"))
        XCTAssertEqual(transition.columnID, PaneColumnID("stack"))
        XCTAssertEqual(transition.sourcePaneID, PaneID("shell"))
        XCTAssertEqual(transition.initialAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(transition.initialFrame.height, 96, accuracy: 0.001)
        XCTAssertLessThan(transition.initialFrame.minY, finalFrame.minY)
        XCTAssertEqual(sourceFrame.maxY, originalShellFrame.maxY, accuracy: 0.001)
    }

    @MainActor
    func test_vertical_split_suspends_terminal_viewport_sync_until_animation_settles() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: adapterFactory.makeAdapter(for:))
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let singlePane = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let splitState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                        PaneState(id: PaneID("pane-1"), title: "pane 1"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("pane-1"),
                    lastFocusedPaneID: PaneID("pane-1")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let splitPresentation = PaneStripMotionController().presentation(
            for: splitState,
            in: paneStripView.bounds.size
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(splitState)

        let shellAdapter = try XCTUnwrap(adapterFactory.adapter(for: PaneID("shell")))
        let insertedAdapter = try XCTUnwrap(adapterFactory.adapter(for: PaneID("pane-1")))
        XCTAssertEqual(shellAdapter.terminalView.viewportSyncSuspensionUpdates.last, true)
        XCTAssertEqual(insertedAdapter.terminalView.viewportSyncSuspensionUpdates.last, true)

        let settled = expectation(description: "vertical split animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertEqual(shellAdapter.terminalView.viewportSyncSuspensionUpdates.suffix(2), [true, false])
        XCTAssertEqual(insertedAdapter.terminalView.viewportSyncSuspensionUpdates.suffix(2), [true, false])
        let shellResumeHeight = try XCTUnwrap(shellAdapter.terminalView.viewportSyncSuspensionBounds.last?.height)
        let insertedResumeHeight = try XCTUnwrap(insertedAdapter.terminalView.viewportSyncSuspensionBounds.last?.height)
        let expectedShellHeight = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("shell") })?.frame.height
        )
        let expectedInsertedHeight = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("pane-1") })?.frame.height
        )
        XCTAssertEqual(
            shellResumeHeight,
            expectedShellHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(
            insertedResumeHeight,
            expectedInsertedHeight,
            accuracy: 0.5
        )
    }

    @MainActor
    func test_vertical_split_freezes_source_terminal_layout_until_animation_settles() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let singlePane = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let splitState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                        PaneState(id: PaneID("pane-1"), title: "pane 1"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("pane-1"),
                    lastFocusedPaneID: PaneID("pane-1")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(splitState)

        let shellPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )
        let insertedPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "pane 1" })
        )
        XCTAssertTrue(shellPane.isTerminalAnimationFrozenForTesting)
        XCTAssertFalse(insertedPane.isTerminalAnimationFrozenForTesting)

        let settled = expectation(description: "vertical split animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertFalse(shellPane.isTerminalAnimationFrozenForTesting)
        XCTAssertFalse(insertedPane.isTerminalAnimationFrozenForTesting)
    }

    @MainActor
    func test_vertical_split_uses_neutral_background_until_animation_settles() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let singlePane = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let splitState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                        PaneState(id: PaneID("pane-1"), title: "pane 1"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("pane-1"),
                    lastFocusedPaneID: PaneID("pane-1")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(splitState)

        let shellPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )
        let insertedPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "pane 1" })
        )

        XCTAssertEqual(shellPane.backgroundColorTokenForTesting, theme.startupSurface.themeToken)
        XCTAssertEqual(insertedPane.backgroundColorTokenForTesting, theme.startupSurface.themeToken)
        XCTAssertEqual(shellPane.insetBorderColorToken, theme.paneBorderUnfocused.themeToken)
        XCTAssertEqual(insertedPane.insetBorderColorToken, theme.paneBorderFocused.themeToken)

        let settled = expectation(description: "vertical split neutral background settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertEqual(shellPane.backgroundColorTokenForTesting, theme.paneFillUnfocused.themeToken)
        XCTAssertEqual(insertedPane.backgroundColorTokenForTesting, theme.paneFillFocused.themeToken)
    }

    @MainActor
    func test_vertical_pane_removal_freezes_remaining_pane_until_animation_settles() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let splitState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                        PaneState(id: PaneID("pane-1"), title: "pane 1"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )
        let singlePane = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("stack"),
                    panes: [
                        PaneState(id: PaneID("shell"), title: "shell"),
                    ],
                    width: 910,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                )
            ],
            focusedColumnID: PaneColumnID("stack")
        )

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(singlePane)

        let shellPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )
        XCTAssertTrue(shellPane.isTerminalAnimationFrozenForTesting)

        let removalTransition = try XCTUnwrap(paneStripView.lastRemovalTransition)
        XCTAssertEqual(removalTransition.columnID, PaneColumnID("stack"))
        XCTAssertEqual(removalTransition.survivingPaneIDs, [PaneID("shell")])

        let settled = expectation(description: "removal animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2.0)

        XCTAssertFalse(shellPane.isTerminalAnimationFrozenForTesting)
    }

    @MainActor
    func test_split_from_multi_pane_preserves_existing_widths_and_reveals_new_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        paneStripView.leadingVisibleInset = sidebarInset
        let twoPaneState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(twoPaneState)
        paneStripView.layoutSubtreeIfNeeded()
        let twoPaneWidths = paneStripView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.frame.width }

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()
        let splitPaneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(splitPaneViews[0].frame.width, twoPaneWidths[0], accuracy: 0.001)
        XCTAssertEqual(splitPaneViews[1].frame.width, twoPaneWidths[1], accuracy: 0.001)
        XCTAssertEqual(
            splitPaneViews[2].frame.width,
            splitState.panes[2].width,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(splitPaneViews[2].frame.maxX, paneStripView.bounds.width + 0.001)
    }

    @MainActor
    func test_pane_strip_does_not_install_pan_gesture_recognizer() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))

        XCTAssertFalse(paneStripView.gestureRecognizers.contains(where: { $0 is NSPanGestureRecognizer }))
    }

    @MainActor
    func test_horizontal_scroll_changes_focus_once_per_gesture() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .began, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .changed, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 30, phase: .changed, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 0, phase: .ended, precise: true))

        XCTAssertEqual(settledPaneIDs, [PaneID("logs")])
    }

    @MainActor
    func test_subthreshold_horizontal_scroll_does_not_change_focus() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 12, phase: .began, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 12, phase: .ended, precise: true))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    @MainActor
    func test_shift_wheel_scroll_changes_focus_to_adjacent_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneID: PaneID?
        paneStripView.onFocusSettled = { settledPaneID = $0 }

        paneStripView.scrollWheel(with: try makeScrollEvent(
            deltaY: -1,
            precise: false,
            modifierFlags: [.shift]
        ))

        XCTAssertEqual(settledPaneID, PaneID("tests"))
    }

    @MainActor
    func test_plain_vertical_scroll_does_not_change_focus() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaY: -2, precise: false))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    @MainActor
    func test_scroll_switching_clamps_at_strip_edges() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("logs")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 60, precise: true))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
    }

    private func makeScrollTestState(focusedPaneID: PaneID) -> PaneStripState {
        PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: focusedPaneID
        )
    }

    private func assertRetinaAligned(_ value: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value * 2, (value * 2).rounded(), accuracy: 0.0001, file: file, line: line)
    }
}

@MainActor
private final class TerminalAdapterFactorySpy {
    private(set) var adapters: [PaneStripTerminalAdapterSpy] = []

    func makeAdapter(for paneID: PaneID) -> any TerminalAdapter {
        let adapter = PaneStripTerminalAdapterSpy(paneID: paneID)
        adapters.append(adapter)
        return adapter
    }

    func adapter(for paneID: PaneID) -> PaneStripTerminalAdapterSpy? {
        adapters.first(where: { $0.paneID == paneID })
    }
}

@MainActor
private final class PaneStripTerminalAdapterSpy: TerminalAdapter {
    let paneID: PaneID
    let terminalView = PaneStripTerminalViewSpy()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity()

    init(paneID: PaneID) {
        self.paneID = paneID
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startSessionCallCount += 1
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private final class PaneStripTerminalViewSpy: NSView, TerminalViewportSyncControlling {
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []
    private(set) var viewportSyncSuspensionBounds: [CGSize] = []

    func setViewportSyncSuspended(_ suspended: Bool) {
        viewportSyncSuspensionUpdates.append(suspended)
        viewportSyncSuspensionBounds.append(bounds.size)
    }
}

private extension NSView {
    func descendantPaneViews() -> [PaneContainerView] {
        var paneViews: [PaneContainerView] = []

        func walk(_ view: NSView) {
            if let paneView = view as? PaneContainerView {
                paneViews.append(paneView)
            }

            view.subviews.forEach(walk)
        }

        walk(self)
        return paneViews
    }
}

private func makeScrollEvent(
    deltaX: Int32 = 0,
    deltaY: Int32 = 0,
    phase: NSEvent.Phase = [],
    precise: Bool,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let units: CGScrollEventUnit = precise ? .pixel : .line
    let cgEvent = try XCTUnwrap(
        CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )
    )

    cgEvent.flags = makeCGEventFlags(from: modifierFlags)
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))

    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
}

private func makeCGEventFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []

    if modifierFlags.contains(.shift) {
        flags.insert(.maskShift)
    }
    if modifierFlags.contains(.control) {
        flags.insert(.maskControl)
    }
    if modifierFlags.contains(.option) {
        flags.insert(.maskAlternate)
    }
    if modifierFlags.contains(.command) {
        flags.insert(.maskCommand)
    }

    return flags
}
