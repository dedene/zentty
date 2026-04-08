import AppKit
import XCTest
@testable import Zentty

final class PaneStripViewTests: XCTestCase {
    private let sidebarInset: CGFloat = 290

    @MainActor
    private func stubRegistry() -> PaneRuntimeRegistry {
        PaneRuntimeRegistry { paneID in PaneStripTerminalAdapterSpy(paneID: paneID) }
    }

    @MainActor
    private func makePaneStripView(width: CGFloat = 1200, height: CGFloat = 680) -> PaneStripView {
        PaneStripView(frame: NSRect(x: 0, y: 0, width: width, height: height), runtimeRegistry: stubRegistry())
    }

    @MainActor
    func test_pane_frames_keep_width_when_container_width_changes() {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
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
        let paneStripView = makePaneStripView(height: 820)
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()

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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
    func test_drag_zone_mouse_down_activates_drag_immediately_and_mouse_up_ends_drag() throws {
        let paneID = PaneID("shell")
        let dragZone = PaneDragZoneView(paneID: paneID)
        dragZone.frame = CGRect(x: 0, y: 0, width: 320, height: PaneDragZoneView.height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }
        window.contentView = dragZone
        window.makeKeyAndOrderFront(nil)

        var activatedPaneID: PaneID?
        var activatedPoint: CGPoint?
        var movedPoints: [CGPoint] = []
        var endedPoint: CGPoint?

        dragZone.onDragActivated = { receivedPaneID, point in
            activatedPaneID = receivedPaneID
            activatedPoint = point
        }
        dragZone.onDragMoved = { movedPoints.append($0) }
        dragZone.onDragEnded = { endedPoint = $0 }

        let mouseDown = try XCTUnwrap(
            makeDragZoneMouseEvent(type: .leftMouseDown, at: CGPoint(x: 120, y: 8), in: dragZone, window: window)
        )
        let mouseDragged = try XCTUnwrap(
            makeDragZoneMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 168, y: 8), in: dragZone, window: window)
        )
        let mouseUp = try XCTUnwrap(
            makeDragZoneMouseEvent(type: .leftMouseUp, at: CGPoint(x: 168, y: 8), in: dragZone, window: window)
        )

        dragZone.mouseDown(with: mouseDown)

        XCTAssertEqual(activatedPaneID, paneID)
        XCTAssertEqual(activatedPoint, mouseDown.locationInWindow)
        XCTAssertEqual(dragZone.cursorDescriptionForTesting, "closedHand")

        dragZone.mouseDragged(with: mouseDragged)
        dragZone.mouseUp(with: mouseUp)

        XCTAssertEqual(movedPoints, [mouseDragged.locationInWindow])
        XCTAssertEqual(endedPoint, mouseUp.locationInWindow)
        XCTAssertEqual(dragZone.cursorDescriptionForTesting, "openHand")
    }

    @MainActor
    func test_double_click_equalize_clears_divider_highlight_state() {
        let paneStripView = makePaneStripView()
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
    func test_horizontal_drag_retargets_non_adjacent_divider_to_the_focused_split() throws {
        let paneStripView = makePaneStripView(width: 1400)
        let grabbedDivider = PaneDivider.column(afterColumnID: PaneColumnID("left"))
        let activeDivider = PaneDivider.column(afterColumnID: PaneColumnID("middle-left"))
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle-left", paneIDs: ["middle-left"], width: 360),
                makeColumn("focused", paneIDs: ["focused"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("focused")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                grabbedDivider,
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )

        XCTAssertEqual(
            target,
            .horizontalEdge(
                PaneHorizontalResizeTarget(
                    columnID: PaneColumnID("focused"),
                    edge: .left,
                    divider: activeDivider
                )
            )
        )
        XCTAssertEqual(paneStripView.dividerHighlightStateForTesting(grabbedDivider)?.active, false)
        XCTAssertEqual(paneStripView.dividerHighlightStateForTesting(activeDivider)?.active, true)
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_pane_drag_preview_uses_opaque_window_background_while_dragging() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let paneStripView = makePaneStripView(width: 980)
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 420),
                PaneState(id: PaneID("editor"), title: "editor", width: 420),
            ],
            focusedPaneID: PaneID("shell")
        )
        paneStripView.dragOverlayView = paneStripView
        paneStripView.apply(theme: theme, animated: false)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )
        let dragPoint = CGPoint(
            x: paneView.frame.midX,
            y: paneView.frame.maxY - (PaneContainerView.dragZoneHeight / 2)
        )

        paneStripView.beginPaneDragForTesting(
            paneID: PaneID("shell"),
            cursorInStrip: dragPoint
        )

        let backgroundColor = try XCTUnwrap(paneStripView.dragPreviewBackgroundColorForTesting)

        XCTAssertLessThan(theme.windowBackground.srgbClamped.alphaComponent, 1.0)
        XCTAssertEqual(
            backgroundColor.themeToken,
            theme.windowBackground.srgbClamped.withAlphaComponent(1).themeToken
        )
        XCTAssertEqual(backgroundColor.srgbClamped.alphaComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(paneView.backgroundColorTokenForTesting, theme.paneFillFocused.themeToken)
    }

    @MainActor
    func test_pane_drag_preview_samples_rendered_backdrop_color_when_available() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let sampledBackdrop = NSColor(srgbRed: 0.87, green: 0.42, blue: 0.26, alpha: 1)
        let paneStripView = makePaneStripView(width: 980)
        let backdropView = NSView(frame: paneStripView.bounds)
        backdropView.wantsLayer = true
        backdropView.layer?.backgroundColor = sampledBackdrop.cgColor
        backdropView.autoresizingMask = [.width, .height]
        paneStripView.addSubview(backdropView, positioned: .below, relativeTo: paneStripView.subviews.first)
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 420),
                PaneState(id: PaneID("editor"), title: "editor", width: 420),
            ],
            focusedPaneID: PaneID("shell")
        )
        paneStripView.dragOverlayView = paneStripView
        paneStripView.apply(theme: theme, animated: false)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )
        let dragPoint = CGPoint(
            x: paneView.frame.midX,
            y: paneView.frame.maxY - (PaneContainerView.dragZoneHeight / 2)
        )

        paneStripView.beginPaneDragForTesting(
            paneID: PaneID("shell"),
            cursorInStrip: dragPoint
        )

        let backgroundColor = try XCTUnwrap(paneStripView.dragPreviewBackgroundColorForTesting)

        let resolvedBackground = backgroundColor.srgbClamped
        let expectedBackdrop = sampledBackdrop.srgbClamped

        XCTAssertEqual(resolvedBackground.redComponent, expectedBackdrop.redComponent, accuracy: 0.01)
        XCTAssertEqual(resolvedBackground.greenComponent, expectedBackdrop.greenComponent, accuracy: 0.01)
        XCTAssertEqual(resolvedBackground.blueComponent, expectedBackdrop.blueComponent, accuracy: 0.01)
        XCTAssertNotEqual(
            backgroundColor.themeToken,
            theme.windowBackground.srgbClamped.withAlphaComponent(1).themeToken
        )
    }

    @MainActor
    func test_render_applies_border_context_to_visible_pane_views() throws {
        let paneStripView = makePaneStripView()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 420),
                PaneState(id: PaneID("editor"), title: "editor", width: 420),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(
            state,
            paneBorderContextByPaneID: [
                PaneID("editor"): PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        let paneViewsByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })

        XCTAssertNil(try XCTUnwrap(paneViewsByTitle["shell"]).paneBorderContextTextForTesting)
        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["editor"]).paneBorderContextTextForTesting,
            "~/src/zentty"
        )
        XCTAssertTrue(try XCTUnwrap(paneViewsByTitle["editor"]).hasPaneContextChrome)
    }

    @MainActor
    func test_render_omits_border_context_and_gap_when_pane_labels_are_hidden() throws {
        let paneStripView = makePaneStripView()
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 420),
                PaneState(id: PaneID("editor"), title: "editor", width: 420),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(
            state,
            paneBorderContextByPaneID: [
                PaneID("editor"): PaneBorderContextDisplayModel(text: "~/src/zentty")
            ],
            showsPaneLabels: false
        )
        paneStripView.layoutSubtreeIfNeeded()

        let editorPane = try XCTUnwrap(paneStripView.descendantPaneViews().first { $0.titleText == "editor" })
        XCTAssertNil(editorPane.paneBorderContextTextForTesting)
        XCTAssertEqual(editorPane.borderLabelGapWidthForTesting, 0, accuracy: 0.001)
    }

    @MainActor
    func test_left_edge_drag_keeps_in_pane_border_context_aligned_to_live_border_gap() throws {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let paneBorderContextByPaneID = [
            PaneID("middle"): PaneBorderContextDisplayModel(text: "~/src/zentty")
        ]
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1400, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state, paneBorderContextByPaneID: paneBorderContextByPaneID)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )
        paneStripView.handleDividerDragDeltaForTesting(-60)
        paneStripView.render(stateProxy, paneBorderContextByPaneID: paneBorderContextByPaneID)
        paneStripView.layoutSubtreeIfNeeded()

        let middlePaneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "middle" })
        )
        let labelFrame = try XCTUnwrap(middlePaneView.paneBorderContextFrameForTesting)
        let borderFrame = middlePaneView.insetBorderFrame
        let expectedMinX = borderFrame.minX + (24 - middlePaneView.insetBorderInset)
        let expectedMidY = borderFrame.maxY - 0.5

        XCTAssertEqual(labelFrame.minX, expectedMinX, accuracy: 0.001)
        XCTAssertEqual(labelFrame.midY, expectedMidY, accuracy: 0.001)
        XCTAssertEqual(middlePaneView.borderLabelGapWidthForTesting, labelFrame.width, accuracy: 0.001)

        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_focus_change_repositions_visible_panes() {
        let paneStripView = makePaneStripView(width: 980)
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
    func test_focus_change_keeps_unrelated_panes_dimmed_during_animated_transition() throws {
        let paneStripView = makePaneStripView(width: 980)
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

        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["logs"]).alphaValue,
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["editor"]).alphaValue,
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["tests"]).alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func test_focus_change_uses_configured_inactive_opacity_during_animated_transition() throws {
        let paneStripView = makePaneStripView(width: 980)
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

        paneStripView.render(editorFocused, inactivePaneOpacity: 0.82)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(testsFocused, inactivePaneOpacity: 0.82)

        let paneViewsByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })

        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["logs"]).alphaValue, 0.82, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["editor"]).alphaValue, 0.82, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["tests"]).alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func test_column_focus_change_keeps_non_handoff_columns_dimmed_during_animated_transition() throws {
        let paneStripView = makePaneStripView()
        let leftFocused = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 360),
                makeColumn("right", paneIDs: ["right"], width: 420),
            ],
            focusedColumnID: PaneColumnID("middle")
        )
        let rightFocused = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 360),
                makeColumn("right", paneIDs: ["right"], width: 420),
            ],
            focusedColumnID: PaneColumnID("right")
        )

        paneStripView.render(leftFocused)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(rightFocused)

        let paneViewsByTitle = Dictionary(uniqueKeysWithValues: try paneStripView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })

        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["left"]).alphaValue,
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(paneViewsByTitle["middle"]).alphaValue,
            PaneContainerView.presentationAlpha(forEmphasis: 0.92),
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(paneViewsByTitle["right"]).alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func test_focus_change_restores_inactive_dimming_after_animation_settles() throws {
        let paneStripView = makePaneStripView(width: 980)
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

        paneStripView.settlePresentationNow()

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
        let store = WorklaneStore(layoutContext: initialContext)
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let insetStripView = makePaneStripView()
        insetStripView.leadingVisibleInset = 290

        insetStripView.render(state)
        insetStripView.layoutSubtreeIfNeeded()

        let visibleBorderFrame = insetStripView.descendantPaneViews()[0].visibleInsetBorderFrameForTesting
        let expectedLaneMinX = 290 + insetStripView.descendantPaneViews()[0].insetBorderInset
        XCTAssertGreaterThanOrEqual(visibleBorderFrame.minX, expectedLaneMinX - 0.001)
    }

    @MainActor
    func test_navigate_back_to_first_pane_respects_leading_visible_inset_with_three_panes() {
        let paneStripView = makePaneStripView()
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

        let visibleBorderFrame = paneStripView.descendantPaneViews()[0].visibleInsetBorderFrameForTesting
        let expectedLaneMinX = sidebarInset + paneStripView.descendantPaneViews()[0].insetBorderInset
        XCTAssertGreaterThanOrEqual(
            visibleBorderFrame.minX,
            expectedLaneMinX - 0.001
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
        let baselineStripView = makePaneStripView()
        let insetStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
    func test_centering_hint_recenters_focused_middle_pane_on_next_render() {
        let paneStripView = makePaneStripView()
        paneStripView.leadingVisibleInset = sidebarInset

        let leftFocusedState = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 420),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 420),
            ],
            focusedColumnID: PaneColumnID("left")
        )
        let resizedMiddleState = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 420),
                makeColumn("middle", paneIDs: ["middle"], width: 360),
                makeColumn("right", paneIDs: ["right"], width: 420),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        paneStripView.render(leftFocusedState)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.centerFocusedInteriorPaneOnNextRender()
        paneStripView.render(resizedMiddleState)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.count, 3)
        let middleVisibleFrame = paneViews[1].visibleInsetBorderFrameForTesting
        let visibleLaneMidX = (sidebarInset + paneViews[1].insetBorderInset + (paneStripView.bounds.width - paneViews[1].insetBorderInset)) / 2

        XCTAssertEqual(middleVisibleFrame.midX, visibleLaneMidX, accuracy: 0.001)
    }

    @MainActor
    func test_worklane_switch_with_no_shared_panes_skips_cross_worklane_animation() {
        let paneStripView = makePaneStripView(width: 980)
        let mainState = PaneStripState(
            panes: [
                PaneState(id: PaneID("main-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("main-shell")
        )
        let worklane2State = PaneStripState(
            panes: [
                PaneState(id: PaneID("worklane-2-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("worklane-2-shell")
        )

        paneStripView.render(mainState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(worklane2State)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneStripView.lastRenderWasAnimated)
    }

    @MainActor
    func test_programmatic_resize_skips_inner_pane_animation() {
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView()
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
    func test_split_renders_border_context_for_inserted_pane() throws {
        let paneStripView = makePaneStripView()
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

        paneStripView.render(
            singlePane,
            paneBorderContextByPaneID: [
                PaneID("shell"): PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(
            splitState,
            paneBorderContextByPaneID: [
                PaneID("shell"): PaneBorderContextDisplayModel(text: "~/src/zentty"),
                PaneID("pane-1"): PaneBorderContextDisplayModel(text: "~/src/new-pane")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        let insertedPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "pane 1" })
        )
        let existingPane = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "shell" })
        )

        XCTAssertEqual(insertedPane.paneBorderContextTextForTesting, "~/src/new-pane")
        XCTAssertEqual(existingPane.paneBorderContextTextForTesting, "~/src/zentty")
    }

    @MainActor
    func test_drop_settle_suppresses_insertion_transition_inference() throws {
        let paneStripView = makePaneStripView()
        let previousState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let nextState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(previousState)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.beginDropSettle(paneID: PaneID("editor")) {}

        paneStripView.render(nextState)

        XCTAssertNil(paneStripView.lastInsertionTransition)
    }

    @MainActor
    func test_insertion_transition_ignores_duplicate_previous_column_ids() throws {
        let paneStripView = makePaneStripView()
        let previousState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("duplicate"),
                    panes: [PaneState(id: PaneID("shell"), title: "shell")],
                    width: 430,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                ),
                PaneColumnState(
                    id: PaneColumnID("duplicate"),
                    panes: [PaneState(id: PaneID("editor"), title: "editor")],
                    width: 430,
                    focusedPaneID: PaneID("editor"),
                    lastFocusedPaneID: PaneID("editor")
                ),
            ],
            focusedColumnID: PaneColumnID("duplicate")
        )
        let nextState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("duplicate"),
                    panes: [PaneState(id: PaneID("shell"), title: "shell")],
                    width: 286,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                ),
                PaneColumnState(
                    id: PaneColumnID("duplicate"),
                    panes: [PaneState(id: PaneID("editor"), title: "editor")],
                    width: 286,
                    focusedPaneID: PaneID("editor"),
                    lastFocusedPaneID: PaneID("editor")
                ),
                PaneColumnState(
                    id: PaneColumnID("column-pane-1"),
                    panes: [PaneState(id: PaneID("pane-1"), title: "pane 1")],
                    width: 286,
                    focusedPaneID: PaneID("pane-1"),
                    lastFocusedPaneID: PaneID("pane-1")
                ),
            ],
            focusedColumnID: PaneColumnID("column-pane-1")
        )

        paneStripView.render(previousState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(nextState)

        XCTAssertNil(paneStripView.lastInsertionTransition)
    }

    @MainActor
    func test_vertical_split_seeds_new_pane_below_focused_pane() throws {
        let paneStripView = makePaneStripView()
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

        XCTAssertEqual(shellAdapter.terminalView.viewportSyncSuspensionUpdates.last, false)
        XCTAssertEqual(insertedAdapter.terminalView.viewportSyncSuspensionUpdates.last, false)
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
        let paneStripView = makePaneStripView()
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

        paneStripView.settlePresentationNow()

        XCTAssertFalse(shellPane.isTerminalAnimationFrozenForTesting)
        XCTAssertFalse(insertedPane.isTerminalAnimationFrozenForTesting)
    }

    @MainActor
    func test_vertical_split_uses_neutral_background_until_animation_settles() throws {
        let theme = ZenttyTheme.fallback(for: nil)
        let paneStripView = makePaneStripView()
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

        paneStripView.settlePresentationNow()

        XCTAssertEqual(shellPane.backgroundColorTokenForTesting, theme.paneFillUnfocused.themeToken)
        XCTAssertEqual(insertedPane.backgroundColorTokenForTesting, theme.paneFillFocused.themeToken)
    }

    @MainActor
    func test_vertical_pane_removal_freezes_remaining_pane_until_animation_settles() throws {
        let paneStripView = makePaneStripView()
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

        paneStripView.settlePresentationNow()

        XCTAssertFalse(shellPane.isTerminalAnimationFrozenForTesting)
    }

    @MainActor
    func test_closing_stacked_pane_resumes_terminal_viewport_sync_with_surviving_pane_height() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: adapterFactory.makeAdapter(for:))
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
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
        let singlePanePresentation = PaneStripMotionController().presentation(
            for: singlePane,
            in: paneStripView.bounds.size
        )

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(singlePane)

        let shellAdapter = try XCTUnwrap(adapterFactory.adapter(for: PaneID("shell")))
        XCTAssertEqual(shellAdapter.terminalView.viewportSyncSuspensionUpdates.last, true)

        let settled = expectation(description: "close animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertEqual(shellAdapter.terminalView.viewportSyncSuspensionUpdates.last, false)
        let resumedHeight = try XCTUnwrap(shellAdapter.terminalView.viewportSyncSuspensionBounds.last?.height)
        let expectedHeight = try XCTUnwrap(
            singlePanePresentation.panes.first(where: { $0.paneID == PaneID("shell") })?.frame.height
        )
        XCTAssertEqual(resumedHeight, expectedHeight, accuracy: 0.5)
    }

    @MainActor
    func test_closing_stacked_pane_requests_terminal_redraw_after_size_change() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: adapterFactory.makeAdapter(for:))
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
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

        let shellAdapter = try XCTUnwrap(adapterFactory.adapter(for: PaneID("shell")))
        let initialDisplayCallCount = shellAdapter.terminalView.displayIfNeededCallCount

        paneStripView.render(singlePane)

        let settled = expectation(description: "close animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertGreaterThan(
            shellAdapter.terminalView.displayIfNeededCallCount,
            initialDisplayCallCount,
            "The surviving terminal should be explicitly redrawn after a pane close changes its size"
        )
    }

    @MainActor
    func test_nonanimated_pane_width_change_requests_terminal_redraw() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: adapterFactory.makeAdapter(for:))
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let initialState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [PaneState(id: PaneID("shell"), title: "shell")],
                    width: 597,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("editor"), title: "editor")],
                    width: 597,
                    focusedPaneID: PaneID("editor"),
                    lastFocusedPaneID: PaneID("editor")
                )
            ],
            focusedColumnID: PaneColumnID("left")
        )
        let resizedState = PaneStripState(
            columns: [
                PaneColumnState(
                    id: PaneColumnID("left"),
                    panes: [PaneState(id: PaneID("shell"), title: "shell")],
                    width: 760,
                    focusedPaneID: PaneID("shell"),
                    lastFocusedPaneID: PaneID("shell")
                ),
                PaneColumnState(
                    id: PaneColumnID("right"),
                    panes: [PaneState(id: PaneID("editor"), title: "editor")],
                    width: 434,
                    focusedPaneID: PaneID("editor"),
                    lastFocusedPaneID: PaneID("editor")
                )
            ],
            focusedColumnID: PaneColumnID("left")
        )

        paneStripView.render(initialState)
        paneStripView.layoutSubtreeIfNeeded()

        let shellAdapter = try XCTUnwrap(adapterFactory.adapter(for: PaneID("shell")))
        let initialDisplayCallCount = shellAdapter.terminalView.displayIfNeededCallCount

        paneStripView.render(resizedState, animated: false)

        XCTAssertGreaterThan(
            shellAdapter.terminalView.displayIfNeededCallCount,
            initialDisplayCallCount,
            "Non-animated pane size changes should still redraw the embedded terminal"
        )
    }

    @MainActor
    func test_split_from_multi_pane_preserves_existing_widths_and_reveals_new_pane() throws {
        let paneStripView = makePaneStripView()
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
        let paneStripView = makePaneStripView(width: 980)

        XCTAssertFalse(paneStripView.gestureRecognizers.contains(where: { $0 is NSPanGestureRecognizer }))
    }

    @MainActor
    func test_horizontal_scroll_changes_focus_once_per_gesture() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .began, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .changed, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 30, phase: .changed, precise: true))
        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 0, phase: .ended, precise: true))

        XCTAssertEqual(settledPaneIDs, [PaneID("tests")])
    }

    @MainActor
    func test_subthreshold_horizontal_scroll_does_not_change_focus() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("logs")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .began, precise: true))

        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 24, phase: .changed, precise: true))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    @MainActor
    func test_shift_wheel_scroll_changes_focus_to_adjacent_pane() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneID: PaneID?
        paneStripView.onFocusSettled = { settledPaneID = $0 }

        paneStripView.scrollWheel(with: try makeScrollEvent(
            deltaY: -1,
            precise: false,
            modifierFlags: [.shift]
        ))

        XCTAssertEqual(settledPaneID, PaneID("logs"))
    }

    @MainActor
    func test_plain_vertical_scroll_does_not_change_focus() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("editor")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaY: -2, precise: false))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    @MainActor
    func test_scroll_switching_clamps_at_strip_edges() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.render(makeScrollTestState(focusedPaneID: PaneID("tests")))
        paneStripView.layoutSubtreeIfNeeded()

        var settledPaneIDs: [PaneID] = []
        paneStripView.onFocusSettled = { settledPaneIDs.append($0) }

        paneStripView.scrollWheel(with: try makeScrollEvent(deltaX: 60, precise: true))

        XCTAssertTrue(settledPaneIDs.isEmpty)
    }

    @MainActor
    func test_search_hud_close_button_hit_testing_beats_pane_drag_zone() throws {
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            PaneStripTerminalAdapterSpy(paneID: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 980, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let state = PaneStripState(
            panes: [pane],
            focusedPaneID: pane.id
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()
        let runtime = try XCTUnwrap(runtimeRegistry.runtime(for: pane.id))
        runtime.showSearch()
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let closePoint = paneStripView.convert(
            CGPoint(
                x: paneView.searchHUDCloseButtonForTesting.bounds.midX,
                y: paneView.searchHUDCloseButtonForTesting.bounds.midY
            ),
            from: paneView.searchHUDCloseButtonForTesting
        )

        XCTAssertTrue(
            paneStripView.hitTest(closePoint) === paneView.searchHUDCloseButtonForTesting,
            "The search HUD must win hit testing over the pane drag strip when they overlap near the top edge"
        )
    }

    @MainActor
    func test_left_edge_drag_compensates_scroll_by_applied_width_delta() throws {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1400, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )
        if case .horizontalEdge(let horizontalTarget) = target {
            XCTAssertEqual(horizontalTarget.edge, .left)
        } else {
            XCTFail("Expected horizontal-edge target, got \(target)")
        }

        let initialScroll = paneStripView.dragScrollOffsetXForTesting
        paneStripView.handleDividerDragDeltaForTesting(-60)

        XCTAssertEqual(paneStripView.dragScrollOffsetXForTesting - initialScroll, 60, accuracy: 0.001)
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_right_edge_drag_does_not_touch_drag_scroll_offset() throws {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1400, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("middle")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )

        let initialScroll = paneStripView.dragScrollOffsetXForTesting
        paneStripView.handleDividerDragDeltaForTesting(60)

        XCTAssertEqual(paneStripView.dragScrollOffsetXForTesting, initialScroll, accuracy: 0.001)
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_left_edge_drag_skips_scroll_compensation_when_resize_is_clamped() throws {
        let paneStripView = makePaneStripView(width: 900, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 900),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 900, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )

        let initialScroll = paneStripView.dragScrollOffsetXForTesting
        paneStripView.handleDividerDragDeltaForTesting(-100)

        // Middle column was already at the readable-width ceiling; applied
        // width delta is 0, so scroll must not move either.
        XCTAssertEqual(paneStripView.dragScrollOffsetXForTesting, initialScroll, accuracy: 0.001)
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_last_column_left_edge_drag_does_not_apply_scroll_compensation() throws {
        let paneStripView = makePaneStripView(width: 1200, height: 720)
        paneStripView.leadingVisibleInset = sidebarInset
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("right", paneIDs: ["right"], width: 420),
            ],
            focusedColumnID: PaneColumnID("right")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1200, height: 720),
                leadingVisibleInset: paneStripView.leadingVisibleInset,
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )

        let initialScroll = paneStripView.dragScrollOffsetXForTesting
        paneStripView.handleDividerDragDeltaForTesting(-60)
        paneStripView.render(stateProxy)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let expectedLeftVisibleMinX = sidebarInset + paneViews[0].insetBorderInset

        XCTAssertEqual(paneStripView.dragScrollOffsetXForTesting, initialScroll, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            paneViews[0].visibleInsetBorderFrameForTesting.minX,
            expectedLeftVisibleMinX - 0.001
        )
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_cancel_divider_drag_restores_initial_drag_scroll_offset() throws {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1400, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }
        paneStripView.onPaneStripStateRestoreRequested = { restored in
            stateProxy = restored
        }

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )

        let initialScroll = paneStripView.dragScrollOffsetXForTesting
        paneStripView.handleDividerDragDeltaForTesting(-40)
        XCTAssertNotEqual(paneStripView.dragScrollOffsetXForTesting, initialScroll, accuracy: 0.001)

        paneStripView.cancelDividerDragForTesting()

        XCTAssertEqual(paneStripView.dragScrollOffsetXForTesting, initialScroll, accuracy: 0.001)
    }

    @MainActor
    func test_left_edge_drag_keeps_logical_pane_width_and_live_border_position() throws {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let paneBorderContextByPaneID = [
            PaneID("middle"): PaneBorderContextDisplayModel(text: "~/src/zentty")
        ]
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )
        var stateProxy = state
        paneStripView.onDividerResizeRequested = { target, delta in
            stateProxy.resize(
                target,
                delta: delta,
                availableSize: CGSize(width: 1400, height: 720),
                minimumSizeByPaneID: [
                    PaneID("left"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("middle"): PaneMinimumSize(width: 320, height: 160),
                    PaneID("right"): PaneMinimumSize(width: 320, height: 160),
                ]
            )
        }

        paneStripView.render(state, paneBorderContextByPaneID: paneBorderContextByPaneID)
        paneStripView.layoutSubtreeIfNeeded()

        _ = try XCTUnwrap(
            paneStripView.beginDividerDragForTesting(
                .column(afterColumnID: PaneColumnID("left")),
                locationInDividerView: CGPoint(x: 4, y: 2)
            )
        )
        paneStripView.handleDividerDragDeltaForTesting(-60)
        paneStripView.render(stateProxy, paneBorderContextByPaneID: paneBorderContextByPaneID)
        paneStripView.layoutSubtreeIfNeeded()

        let middlePaneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleText == "middle" })
        )
        let labelFrame = try XCTUnwrap(middlePaneView.paneBorderContextFrameForTesting)
        let expectedWidth = try XCTUnwrap(
            stateProxy.columns.first(where: { $0.id == PaneColumnID("middle") })?.width
        )

        XCTAssertEqual(middlePaneView.frame.width, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(labelFrame.width, middlePaneView.borderLabelGapWidthForTesting, accuracy: 0.001)
        XCTAssertEqual(labelFrame.minX, 24, accuracy: 0.001)
        XCTAssertEqual(labelFrame.midY, middlePaneView.insetBorderFrame.maxY - 0.5, accuracy: 0.001)
        paneStripView.endDividerDragForTesting()
    }

    @MainActor
    func test_shift_target_offset_on_next_render_advances_offset_on_next_render() {
        // Viewport narrower than content so there's headroom to scroll.
        let paneStripView = makePaneStripView(width: 900, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 400),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
                makeColumn("right", paneIDs: ["right"], width: 520),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()
        let offsetBefore = paneStripView.currentOffsetForTesting

        // Simulate what happens when a keyboard "expand left edge" command
        // lands on an edge column: the column width grows by 40 and the
        // shift override fires so the strip scrolls in lockstep.
        var grownState = state
        grownState.columns[0].width = 440
        paneStripView.shiftTargetOffsetOnNextRender(by: 40)
        paneStripView.render(grownState)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            paneStripView.currentOffsetForTesting - offsetBefore,
            40,
            accuracy: 0.5,
            "Offset must advance by the requested shift (subject to snapping)"
        )
    }

    @MainActor
    func test_shift_target_offset_clamps_at_content_bounds() {
        let paneStripView = makePaneStripView(width: 1400, height: 720)
        let state = PaneStripState(
            columns: [
                makeColumn("left", paneIDs: ["left"], width: 320),
                makeColumn("middle", paneIDs: ["middle"], width: 420),
            ],
            focusedColumnID: PaneColumnID("middle")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        // Request a shift far larger than the content can scroll. The
        // motion controller clamp prevents runaway offsets.
        paneStripView.shiftTargetOffsetOnNextRender(by: 100_000)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(paneStripView.currentOffsetForTesting, 100_000)
    }

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
    }

    private func makeColumn(
        _ rawID: String,
        paneIDs: [String],
        width: CGFloat
    ) -> PaneColumnState {
        PaneColumnState(
            id: PaneColumnID(rawID),
            panes: paneIDs.map { PaneState(id: PaneID($0), title: $0) },
            width: width,
            focusedPaneID: paneIDs.first.map(PaneID.init),
            lastFocusedPaneID: paneIDs.first.map(PaneID.init)
        )
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

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private final class PaneStripTerminalViewSpy: NSView, TerminalViewportSyncControlling {
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []
    private(set) var viewportSyncSuspensionBounds: [CGSize] = []
    private(set) var displayIfNeededCallCount = 0

    override func displayIfNeeded() {
        displayIfNeededCallCount += 1
        super.displayIfNeeded()
    }

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

private extension PaneContainerView {
    var visibleInsetBorderFrameForTesting: CGRect {
        insetBorderFrame.offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

private func makeDragZoneMouseEvent(
    type: NSEvent.EventType,
    at point: CGPoint,
    in view: NSView,
    window: NSWindow
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: view.convert(point, to: nil),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
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
