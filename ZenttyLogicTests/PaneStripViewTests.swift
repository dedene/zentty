import AppKit
import XCTest
@testable import Zentty

final class PaneStripViewTests: AppKitTestCase {
    private let sidebarInset: CGFloat = 290

    @MainActor
    private func stubRegistry() -> PaneRuntimeRegistry {
        PaneRuntimeRegistry { paneID in PaneStripTerminalAdapterSpy(paneID: paneID) }
    }

    @MainActor
    private func makePaneStripView(width: CGFloat = 1200, height: CGFloat = 680) -> PaneStripView {
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            runtimeRegistry: stubRegistry()
        )
        addTeardownBlock {
            MainActor.assumeIsolated {
                paneStripView.prepareForTestingTearDown()
            }
        }
        return paneStripView
    }

    @MainActor
    @discardableResult
    private func hostInVisibleWindow(_ paneStripView: PaneStripView) -> NSWindow {
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)
        return window
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
        XCTAssertEqual(
            paneView.frame.maxY,
            paneStripView.bounds.height - PaneLayoutSizing.balanced.topInset,
            accuracy: 0.001
        )
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
    func test_drag_zone_click_does_not_activate_drag() throws {
        let paneID = PaneID("shell")
        let dragZone = PaneDragZoneView(paneID: paneID)
        dragZone.frame = CGRect(x: 0, y: 0, width: 320, height: PaneDragZoneView.height)

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

        let mouseDown = try XCTUnwrap(makeDragZoneMouseEvent(type: .leftMouseDown, at: CGPoint(x: 120, y: 8)))
        let mouseUp = try XCTUnwrap(makeDragZoneMouseEvent(type: .leftMouseUp, at: CGPoint(x: 120, y: 8)))

        dragZone.mouseDown(with: mouseDown)
        dragZone.mouseUp(with: mouseUp)

        XCTAssertNil(activatedPaneID)
        XCTAssertNil(activatedPoint)
        XCTAssertEqual(movedPoints, [])
        XCTAssertNil(endedPoint)
        XCTAssertEqual(dragZone.cursorDescriptionForTesting, "openHand")
    }

    @MainActor
    func test_drag_zone_activates_after_drag_threshold_and_mouse_up_ends_drag() throws {
        let paneID = PaneID("shell")
        let dragZone = PaneDragZoneView(paneID: paneID)
        dragZone.frame = CGRect(x: 0, y: 0, width: 320, height: PaneDragZoneView.height)

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

        let mouseDown = try XCTUnwrap(makeDragZoneMouseEvent(type: .leftMouseDown, at: CGPoint(x: 120, y: 8)))
        let belowThresholdDrag = try XCTUnwrap(
            makeDragZoneMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 122, y: 9))
        )
        let activatingDrag = try XCTUnwrap(
            makeDragZoneMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 132, y: 8))
        )
        let mouseUp = try XCTUnwrap(makeDragZoneMouseEvent(type: .leftMouseUp, at: CGPoint(x: 132, y: 8)))

        dragZone.mouseDown(with: mouseDown)
        dragZone.mouseDragged(with: belowThresholdDrag)

        XCTAssertNil(activatedPaneID)
        XCTAssertNil(activatedPoint)
        XCTAssertEqual(movedPoints, [])
        XCTAssertEqual(dragZone.cursorDescriptionForTesting, "openHand")

        dragZone.mouseDragged(with: activatingDrag)

        XCTAssertEqual(activatedPaneID, paneID)
        XCTAssertEqual(activatedPoint, mouseDown.locationInWindow)
        XCTAssertEqual(movedPoints, [activatingDrag.locationInWindow])
        XCTAssertEqual(dragZone.cursorDescriptionForTesting, "closedHand")

        dragZone.mouseUp(with: mouseUp)

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
    func test_pane_drag_preview_resolves_stable_opaque_background_when_backdrop_is_present() throws {
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

        // Drag activation now reuses the pane snapshot and only samples the strip
        // when that snapshot exposes partial transparency. Exact backdrop RGB is
        // therefore an implementation detail; the stable contract is that drag
        // preview activation resolves a concrete opaque background without
        // disturbing the original pane theming.
        let backgroundColor = try XCTUnwrap(paneStripView.dragPreviewBackgroundColorForTesting)
        XCTAssertEqual(backgroundColor.srgbClamped.alphaComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(paneView.backgroundColorTokenForTesting, theme.paneFillFocused.themeToken)
    }

    @MainActor
    func test_duplicate_drop_renders_updated_layout_before_drag_teardown() throws {
        let paneStripView = makePaneStripView(width: 980)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)
        paneStripView.dragOverlayView = paneStripView

        let sourceState = PaneStripState(
            panes: [
                PaneState(id: PaneID("source"), title: "source", width: 980),
            ],
            focusedPaneID: PaneID("source")
        )
        let duplicateState = PaneStripState(
            panes: [
                PaneState(id: PaneID("source"), title: "source", width: 480),
                PaneState(id: PaneID("duplicate"), title: "duplicate", width: 480),
            ],
            focusedPaneID: PaneID("duplicate")
        )

        paneStripView.onPaneReorderRequested = { paneID, _, isDuplicate in
            XCTAssertEqual(paneID, PaneID("source"))
            XCTAssertTrue(isDuplicate)
            paneStripView.render(duplicateState, animated: false)
            paneStripView.layoutSubtreeIfNeeded()
        }

        paneStripView.render(sourceState)
        paneStripView.layoutSubtreeIfNeeded()

        let sourcePaneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.paneID == PaneID("source") })
        )
        let dragPoint = CGPoint(
            x: sourcePaneView.frame.midX,
            y: sourcePaneView.frame.maxY - (PaneContainerView.dragZoneHeight / 2)
        )

        paneStripView.beginPaneDragForTesting(
            paneID: PaneID("source"),
            cursorInStrip: dragPoint
        )
        paneStripView.setDuplicateDragEnabledForTesting(true)
        paneStripView.endPaneDragForTesting(cursorInStrip: dragPoint)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertTrue(paneStripView.isDragActive)
        XCTAssertTrue(paneStripView.isDropSettling)

        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.map(\.paneID), [PaneID("source"), PaneID("duplicate")])
        XCTAssertLessThan(
            paneViews[0].frame.width,
            paneStripView.bounds.width - 1,
            "The duplicate split layout must be live before the drag teardown reveals it"
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
    func test_clicking_visible_pane_border_context_triggers_copy_callback() throws {
        let paneStripView = makePaneStripView(width: 980, height: 680)
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let paneID = PaneID("shell")
        var clickedPaneIDs: [PaneID] = []
        paneStripView.onPaneBorderContextClicked = { clickedPaneID in
            clickedPaneIDs.append(clickedPaneID)
        }

        paneStripView.render(
            PaneStripState(
                panes: [PaneState(id: paneID, title: "shell", width: 980)],
                focusedPaneID: paneID
            ),
            paneBorderContextByPaneID: [
                paneID: PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let labelFrame = try XCTUnwrap(paneView.paneBorderContextFrameForTesting)
        let clickPoint = paneView.convert(
            CGPoint(x: labelFrame.midX, y: min(labelFrame.midY, paneView.bounds.maxY - 1)),
            to: paneStripView
        )
        let roundTrippedPoint = paneView.convert(
            paneStripView.convert(clickPoint, to: nil),
            from: nil
        )
        XCTAssertTrue(labelFrame.contains(roundTrippedPoint))

        let hitView = paneStripView.hitTest(clickPoint)
        let clickTarget = try XCTUnwrap(hitView as? PaneBorderContextInsetView)

        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: paneStripView.convert(clickPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        clickTarget.mouseDown(with: mouseDown)

        XCTAssertEqual(clickedPaneIDs, [paneID])
    }

    @MainActor
    func test_clicking_bottom_mirror_of_pane_border_context_does_not_trigger_copy_callback() throws {
        let paneStripView = makePaneStripView(width: 980, height: 680)
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let paneID = PaneID("shell")
        var clickedPaneIDs: [PaneID] = []
        paneStripView.onPaneBorderContextClicked = { clickedPaneID in
            clickedPaneIDs.append(clickedPaneID)
        }

        paneStripView.render(
            PaneStripState(
                panes: [PaneState(id: paneID, title: "shell", width: 980)],
                focusedPaneID: paneID
            ),
            paneBorderContextByPaneID: [
                paneID: PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let labelFrame = try XCTUnwrap(paneView.paneBorderContextFrameForTesting)
        let mirroredBottomPoint = paneView.convert(
            CGPoint(x: labelFrame.midX, y: paneView.bounds.height - labelFrame.midY),
            to: paneStripView
        )

        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: paneStripView.convert(mirroredBottomPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        paneView.mouseDown(with: mouseDown)

        XCTAssertTrue(clickedPaneIDs.isEmpty)
    }

    @MainActor
    func test_clicking_upper_visible_pane_border_context_invokes_copy_callback() throws {
        let paneStripView = makePaneStripView(width: 980, height: 680)
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let paneID = PaneID("shell")
        var clickedPaneIDs: [PaneID] = []
        paneStripView.onPaneBorderContextClicked = { clickedPaneID in
            clickedPaneIDs.append(clickedPaneID)
        }

        paneStripView.render(
            PaneStripState(
                panes: [PaneState(id: paneID, title: "shell", width: 980)],
                focusedPaneID: paneID
            ),
            paneBorderContextByPaneID: [
                paneID: PaneBorderContextDisplayModel(text: "~/src/zentty")
            ]
        )
        paneStripView.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let labelFrame = try XCTUnwrap(paneView.paneBorderContextFrameForTesting)
        let upperVisiblePoint = paneView.convert(
            CGPoint(x: labelFrame.midX, y: labelFrame.maxY - 1),
            to: paneStripView
        )

        let hitView = paneStripView.hitTest(upperVisiblePoint)
        let clickTarget = try XCTUnwrap(hitView as? PaneBorderContextInsetView)

        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: paneStripView.convert(upperVisiblePoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        clickTarget.mouseDown(with: mouseDown)

        XCTAssertEqual(clickedPaneIDs, [paneID])
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
    func test_same_size_state_changes_after_programmatic_resize_skip_animation_without_visible_window() {
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

        XCTAssertFalse(paneStripView.lastRenderWasAnimated)
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
    func test_pending_programmatic_focus_ignores_stale_source_focus_reports() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 980, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let sourcePaneID = PaneID("shell")
        let duplicatedPaneID = PaneID("pane-1")
        let initialState = PaneStripState(
            panes: [
                PaneState(id: sourcePaneID, title: "shell"),
            ],
            focusedPaneID: sourcePaneID
        )
        let duplicatedState = PaneStripState(
            panes: [
                PaneState(id: sourcePaneID, title: "shell"),
                PaneState(id: duplicatedPaneID, title: "pane 1"),
            ],
            focusedPaneID: duplicatedPaneID
        )
        var selectedPaneIDs: [PaneID] = []
        paneStripView.onPaneSelected = { selectedPaneIDs.append($0) }

        paneStripView.render(initialState)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.render(duplicatedState)
        paneStripView.layoutSubtreeIfNeeded()

        let sourceAdapter = try XCTUnwrap(adapterFactory.adapter(for: sourcePaneID))
        sourceAdapter.terminalView.simulateFocusChange(true)

        XCTAssertEqual(selectedPaneIDs, [])
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
        hostInVisibleWindow(paneStripView)
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

        paneStripView.settlePresentationNow()

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
        hostInVisibleWindow(paneStripView)
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
        hostInVisibleWindow(paneStripView)
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
        hostInVisibleWindow(paneStripView)
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

        paneStripView.settlePresentationNow()

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
        hostInVisibleWindow(paneStripView)
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

        paneStripView.settlePresentationNow()

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
    func test_stale_source_focus_callback_is_ignored_while_new_target_focus_is_pending() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: adapterFactory.makeAdapter(for:))
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 980, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }

        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let sourcePane = PaneState(id: PaneID("source"), title: "source")
        let siblingPane = PaneState(id: PaneID("sibling"), title: "sibling")
        let duplicatePane = PaneState(id: PaneID("duplicate"), title: "duplicate")
        let initialState = PaneStripState(
            panes: [sourcePane, siblingPane],
            focusedPaneID: sourcePane.id
        )
        let duplicatedState = PaneStripState(
            panes: [sourcePane, duplicatePane, siblingPane],
            focusedPaneID: duplicatePane.id
        )

        paneStripView.render(initialState)
        paneStripView.layoutSubtreeIfNeeded()

        _ = runtimeRegistry.runtime(for: duplicatePane)
        let duplicateAdapter = try XCTUnwrap(adapterFactory.adapter(for: duplicatePane.id))
        duplicateAdapter.terminalView.usesDetachedFocusTarget = true

        var selectedPaneIDs: [PaneID] = []
        paneStripView.onPaneSelected = { selectedPaneIDs.append($0) }

        paneStripView.render(duplicatedState)
        paneStripView.layoutSubtreeIfNeeded()

        let sourceAdapter = try XCTUnwrap(adapterFactory.adapter(for: sourcePane.id))
        sourceAdapter.terminalView.simulateFocusChange(true)

        XCTAssertFalse(
            selectedPaneIDs.contains(sourcePane.id),
            "The source pane should not reclaim selection while PaneStripView is still steering focus to the duplicate"
        )
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

    @MainActor
    func test_stale_source_focus_callback_is_ignored_during_programmatic_focus_transfer() throws {
        let factory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry { paneID in
            factory.makeAdapter(for: paneID)
        }
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let sourceState = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let targetState = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        var selectedPaneIDs: [PaneID] = []
        paneStripView.onPaneSelected = { selectedPaneIDs.append($0) }

        paneStripView.render(sourceState)
        paneStripView.layoutSubtreeIfNeeded()
        selectedPaneIDs.removeAll()

        paneStripView.render(targetState)
        paneStripView.layoutSubtreeIfNeeded()

        let sourceAdapter = try XCTUnwrap(factory.adapter(for: PaneID("shell")))
        sourceAdapter.terminalView.simulateFocusChange(true)

        XCTAssertFalse(
            selectedPaneIDs.contains(PaneID("shell")),
            "A late source-pane focus callback should not overwrite the requested target pane"
        )
    }

    @MainActor
    func test_force_focus_current_pane_restores_first_responder_when_same_target_remains_focused() throws {
        let factory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry { paneID in
            factory.makeAdapter(for: paneID)
        }
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let state = PaneStripState(
            panes: [
                makePane("shell"),
                makePane("editor"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let shellAdapter = try XCTUnwrap(factory.adapter(for: PaneID("shell")))
        let editorAdapter = try XCTUnwrap(factory.adapter(for: PaneID("editor")))

        XCTAssertTrue(window.firstResponder === editorAdapter.terminalView)
        XCTAssertTrue(window.makeFirstResponder(shellAdapter.terminalView))
        XCTAssertTrue(window.firstResponder === shellAdapter.terminalView)

        paneStripView.focusCurrentPaneIfNeeded()

        XCTAssertTrue(
            window.firstResponder === editorAdapter.terminalView,
            "Forced focus sync should restore the focused pane even when the pane ID has not changed"
        )
    }

    @MainActor
    func test_end_drag_with_zoom_in_reanchors_to_newly_focused_pane() throws {
        let factory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry { paneID in
            factory.makeAdapter(for: paneID)
        }
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = paneStripView
        window.makeKeyAndOrderFront(nil)

        let sourceState = PaneStripState(
            panes: [
                makePane("source"),
                makePane("sibling"),
            ],
            focusedPaneID: PaneID("source")
        )
        let duplicateState = PaneStripState(
            panes: [
                makePane("source"),
                makePane("duplicate"),
                makePane("sibling"),
            ],
            focusedPaneID: PaneID("duplicate")
        )

        paneStripView.render(sourceState)
        paneStripView.layoutSubtreeIfNeeded()
        paneStripView.toggleZoom(animated: false)

        paneStripView.render(duplicateState)
        paneStripView.layoutSubtreeIfNeeded()

        let duplicatePaneView = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.paneID == PaneID("duplicate") })
        )

        paneStripView.endDragWithZoomIn()

        XCTAssertEqual(
            paneStripView.zoomAnchorForTesting.x,
            duplicatePaneView.frame.midX,
            accuracy: 0.001,
            "Zoom-in should target the newly focused duplicate pane rather than the original source pane"
        )
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
    func sendText(_ text: String) {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private final class PaneStripTerminalViewSpy: NSView, TerminalViewportSyncControlling, TerminalFocusReporting, TerminalFocusTargetProviding {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []
    private(set) var viewportSyncSuspensionBounds: [CGSize] = []
    private(set) var displayIfNeededCallCount = 0
    let detachedFocusTarget = NSView()
    var usesDetachedFocusTarget = false

    var terminalFocusTargetView: NSView {
        usesDetachedFocusTarget ? detachedFocusTarget : self
    }

    override func displayIfNeeded() {
        displayIfNeededCallCount += 1
        super.displayIfNeeded()
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        viewportSyncSuspensionUpdates.append(suspended)
        viewportSyncSuspensionBounds.append(bounds.size)
    }

    func simulateFocusChange(_ isFocused: Bool) {
        onFocusDidChange?(isFocused)
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
    at point: CGPoint
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
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
