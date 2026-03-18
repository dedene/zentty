import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: XCTestCase {
    override func tearDown() {
        SidebarWidthPreference.resetForTesting()
        super.tearDown()
    }

    func test_root_controller_layers_full_width_canvas_beneath_sidebar_overlay() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(controller.view)
        let rootSubviews = controller.view.subviews
        let sidebarView = rootSubviews.first { $0 is SidebarView } as? SidebarView
        let appCanvasView = try XCTUnwrap(rootSubviews.first { $0 is AppCanvasView })

        XCTAssertNotNil(sidebarView)
        XCTAssertFalse(appCanvasView.containsDescendant(ofType: SidebarView.self))
        XCTAssertFalse(rootSubviews.contains { $0 is ContentShellView })
        XCTAssertEqual(sidebarView?.workspacePrimaryTextsForTesting, ["shell"])
        XCTAssertEqual(sidebarView?.workspaceContextTextsForTesting, [""])
        XCTAssertEqual(
            appCanvasView.frame.minX,
            ShellMetrics.outerInset,
            accuracy: 0.5
        )
    }

    func test_root_controller_keeps_window_chrome_as_sibling_overlay_above_canvas() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let rootSubviews = controller.view.subviews
        let appCanvasView = try XCTUnwrap(rootSubviews.first { $0 is AppCanvasView })
        let paneBorderOverlayView = try XCTUnwrap(rootSubviews.first { $0 is PaneBorderContextOverlayView })
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView })

        XCTAssertTrue(rootSubviews.contains { $0 is SidebarView })
        XCTAssertFalse(rootSubviews.contains { $0 is ContentShellView })
        XCTAssertFalse(appCanvasView.containsDescendant(ofType: WindowChromeView.self))
        XCTAssertFalse(appCanvasView.containsDescendant(ofType: PaneBorderContextOverlayView.self))
        XCTAssertEqual(paneBorderOverlayView.frame, controller.view.bounds)
        XCTAssertEqual(windowChromeView.frame.minY, appCanvasView.frame.maxY, accuracy: 0.5)
    }

    func test_handle_routes_split_from_current_first_responder_pane() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.activateWindowBindingsIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        controller.handle(.pane(.splitHorizontally))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.handle(.pane(.focusLeft))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let rightResponder = try XCTUnwrap(
            controller.view.descendantPaneViews()
                .first(where: { $0.titleTextForTesting == "pane 1" })?
                .firstDescendant(ofType: TerminalPaneHostView.self)?
                .terminalViewForTesting as? NSResponder
        )

        controller.handle(.pane(.splitVertically), syncingFocusWith: rightResponder)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()

        let framesByTitle = Dictionary(uniqueKeysWithValues: try controller.view.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleTextForTesting.isEmpty ? nil : $0.titleTextForTesting)
            return (title, $0.frame)
        })

        let shellFrame = try XCTUnwrap(framesByTitle["shell"])
        let paneOneFrame = try XCTUnwrap(framesByTitle["pane 1"])
        let paneTwoFrame = try XCTUnwrap(framesByTitle["pane 2"])

        XCTAssertEqual(paneOneFrame.minX, paneTwoFrame.minX, accuracy: 1)
        XCTAssertEqual(paneOneFrame.maxX, paneTwoFrame.maxX, accuracy: 1)
        XCTAssertLessThan(shellFrame.minX, paneOneFrame.minX)
    }

    func test_chrome_geometry_derives_nested_radii_from_edge_to_edge_insets() {
        XCTAssertEqual(ChromeGeometry.contentShellRadius, ChromeGeometry.innerRadius(
            outerRadius: ChromeGeometry.outerWindowRadius,
            inset: ChromeGeometry.shellInset
        ))
        XCTAssertEqual(ChromeGeometry.sidebarRadius, ChromeGeometry.contentShellRadius)
        XCTAssertEqual(ChromeGeometry.paneRadius, ChromeGeometry.sidebarRadius)
        XCTAssertEqual(ChromeGeometry.rowRadius, ChromeGeometry.innerRadius(
            outerRadius: ChromeGeometry.sidebarRadius,
            inset: ChromeGeometry.rowInset
        ))
        XCTAssertEqual(ChromeGeometry.pillRadius, ChromeGeometry.innerRadius(
            outerRadius: ChromeGeometry.rowRadius,
            inset: ChromeGeometry.pillInset
        ))
    }

    func test_chrome_geometry_derives_clip_safe_pane_border_inset_and_rounds_outward_on_retina() {
        let rawInset = ChromeGeometry.clipSafeInnerBorderInset(
            parentRadius: ChromeGeometry.contentShellRadius,
            childRadius: ChromeGeometry.paneRadius
        )
        let backingPixelInset = ChromeGeometry.backingPixelInset(backingScaleFactor: 2)
        let roundedInset = ChromeGeometry.paneBorderInset(backingScaleFactor: 2)

        XCTAssertEqual(rawInset, 0.5, accuracy: 0.000001)
        XCTAssertEqual(backingPixelInset, 0.5, accuracy: 0.001)
        XCTAssertEqual(roundedInset, 1.0, accuracy: 0.001)
    }

    func test_root_controller_applies_outer_shell_geometry_to_live_root_view() {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())

        controller.loadViewIfNeeded()

        let cornerRadius = controller.view.layer?.cornerRadius ?? 0
        let borderWidth = controller.view.layer?.borderWidth ?? 0

        XCTAssertEqual(cornerRadius, ChromeGeometry.outerWindowRadius, accuracy: 0.001)
        XCTAssertEqual(controller.view.layer?.cornerCurve, .continuous)
        XCTAssertEqual(borderWidth, 1, accuracy: 0.001)
        XCTAssertTrue(controller.view.layer?.masksToBounds == true)
    }

    func test_app_canvas_view_is_a_silent_clip_layer_instead_of_a_visible_inner_card() {
        let appCanvasView = AppCanvasView(runtimeRegistry: PaneRuntimeRegistry())

        appCanvasView.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)

        let cornerRadius = appCanvasView.layer?.cornerRadius ?? 0

        XCTAssertEqual(cornerRadius, ChromeGeometry.contentShellRadius, accuracy: 0.001)
        XCTAssertEqual(appCanvasView.layer?.cornerCurve, .continuous)
        XCTAssertTrue(appCanvasView.layer?.masksToBounds == true)
        XCTAssertEqual(appCanvasView.layer?.borderWidth ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(alphaComponent(of: appCanvasView.layer?.backgroundColor), 0, accuracy: 0.001)
        XCTAssertEqual(alphaComponent(of: appCanvasView.layer?.borderColor), 0, accuracy: 0.001)
    }

    func test_pane_border_context_overlay_renders_above_pane_border() throws {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let snapshot = PaneBorderChromeSnapshot(
            paneID: PaneID("shell"),
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(text: "~/src/zentty")
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        let overlayFrame = try XCTUnwrap(overlayView.paneContextFramesForTesting[PaneID("shell")])

        XCTAssertEqual(overlayView.paneContextTextsForTesting[PaneID("shell")], "~/src/zentty")
        XCTAssertGreaterThan(overlayFrame.maxY, snapshot.frame.maxY)
        XCTAssertEqual(
            overlayFrame.midY,
            snapshot.frame.maxY - ChromeGeometry.paneBorderInset(backingScaleFactor: 2) - 0.5,
            accuracy: 1
        )
    }

    func test_pane_border_context_overlay_uses_middle_truncation_and_restyles_focus() {
        let theme = ZenttyTheme.fallback(for: nil)
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let focusedSnapshot = PaneBorderChromeSnapshot(
            paneID: PaneID("shell"),
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(
                text: "peter@gilfoyle ~/Development/Personal/zentty/very/deep/subdirectory"
            )
        )
        let unfocusedSnapshot = PaneBorderChromeSnapshot(
            paneID: PaneID("shell"),
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: false,
            emphasis: 0.92,
            borderContext: PaneBorderContextDisplayModel(
                text: "peter@gilfoyle ~/Development/Personal/zentty/very/deep/subdirectory"
            )
        )

        overlayView.render(snapshots: [focusedSnapshot], theme: theme)
        overlayView.layoutSubtreeIfNeeded()
        let focusedToken = overlayView.paneContextTextColorTokensForTesting[PaneID("shell")]
        let focusedBackdropToken = overlayView.paneContextBackdropColorTokensForTesting[PaneID("shell")]
        let focusedWidth = overlayView.paneContextFramesForTesting[PaneID("shell")]?.width ?? 0
        let focusedTextFrame = overlayView.paneContextTextFramesForTesting[PaneID("shell")] ?? .zero
        let focusedNaturalTextWidth = overlayView.paneContextNaturalTextWidthsForTesting[PaneID("shell")] ?? 0
        let focusedLeftBorderFrame = overlayView.paneContextLeftBorderFramesForTesting[PaneID("shell")] ?? .zero
        let focusedRightBorderFrame = overlayView.paneContextRightBorderFramesForTesting[PaneID("shell")] ?? .zero

        overlayView.render(snapshots: [unfocusedSnapshot], theme: theme)
        overlayView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            overlayView.paneContextTextTruncationModesForTesting[PaneID("shell")],
            .middle
        )
        XCTAssertEqual(
            focusedWidth,
            focusedNaturalTextWidth + 14,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedBackdropToken,
            theme.startupSurface.themeToken
        )
        XCTAssertEqual(
            overlayView.paneContextBackdropColorTokensForTesting[PaneID("shell")],
            theme.startupSurface.themeToken
        )
        XCTAssertNotEqual(
            focusedToken,
            overlayView.paneContextTextColorTokensForTesting[PaneID("shell")]
        )
        XCTAssertGreaterThan(focusedTextFrame.minY, 0)
        XCTAssertEqual(focusedLeftBorderFrame.width, 0, accuracy: 0.001)
        XCTAssertEqual(focusedRightBorderFrame.width, 0, accuracy: 0.001)
    }

    func test_pane_border_context_overlay_uses_natural_width_for_short_text() {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let snapshot = PaneBorderChromeSnapshot(
            paneID: PaneID("shell"),
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(text: "~/nimbu")
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        let width = overlayView.paneContextFramesForTesting[PaneID("shell")]?.width ?? 0

        XCTAssertLessThan(width, 120)
    }

    func test_pane_border_context_overlay_clamps_only_at_real_pane_width_limit() {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let snapshot = PaneBorderChromeSnapshot(
            paneID: PaneID("shell"),
            frame: CGRect(x: 320, y: 120, width: 220, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(
                text: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nimbu"
            )
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        let width = overlayView.paneContextFramesForTesting[PaneID("shell")]?.width ?? 0

        XCTAssertEqual(width, 180, accuracy: 1)
        XCTAssertEqual(
            overlayView.paneContextTextTruncationModesForTesting[PaneID("shell")],
            .middle
        )
    }

    func test_pane_border_context_overlay_keeps_text_frame_inside_label_mask_with_vertical_headroom() throws {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let paneID = PaneID("shell")
        let snapshot = PaneBorderChromeSnapshot(
            paneID: paneID,
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(text: "~/Development/Zenjoy/Nimbu/Rails/nimbu")
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        let labelFrame = try XCTUnwrap(overlayView.paneContextFramesForTesting[paneID])
        let textFrame = try XCTUnwrap(overlayView.paneContextTextFramesForTesting[paneID])

        XCTAssertGreaterThan(textFrame.minY, 0)
        XCTAssertLessThan(textFrame.maxY, labelFrame.height)
        XCTAssertGreaterThanOrEqual(labelFrame.height - textFrame.height, 8)
    }

    func test_pane_border_context_overlay_uses_view_text_renderer_instead_of_catextlayer() {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let paneID = PaneID("shell")
        let snapshot = PaneBorderChromeSnapshot(
            paneID: paneID,
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(text: "~/Development/Zenjoy/Nimbu/Rails/nimbu")
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        XCTAssertFalse(overlayView.paneContextUsesCATextLayerForTesting[paneID] ?? true)
    }

    func test_pane_border_context_overlay_masks_border_line_under_label_background() throws {
        let overlayView = PaneBorderContextOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 840),
            backingScaleFactorProvider: { 2 }
        )
        let paneID = PaneID("shell")
        let snapshot = PaneBorderChromeSnapshot(
            paneID: paneID,
            frame: CGRect(x: 320, y: 120, width: 420, height: 520),
            isFocused: true,
            emphasis: 1,
            borderContext: PaneBorderContextDisplayModel(text: "~/Development/Zenjoy/Nimbu/Rails/nimbu")
        )

        overlayView.render(snapshots: [snapshot], theme: ZenttyTheme.fallback(for: nil))
        overlayView.layoutSubtreeIfNeeded()

        let leftBorderFrame = try XCTUnwrap(overlayView.paneContextLeftBorderFramesForTesting[paneID])
        let rightBorderFrame = try XCTUnwrap(overlayView.paneContextRightBorderFramesForTesting[paneID])

        XCTAssertEqual(leftBorderFrame.width, 0, accuracy: 0.001)
        XCTAssertEqual(rightBorderFrame.width, 0, accuracy: 0.001)
    }

    func test_window_chrome_keeps_only_trailing_context_strip_without_title_label() {
        let windowChromeView = WindowChromeView()

        XCTAssertEqual(windowChromeView.titleTextForTesting, "")
    }

    func test_context_strip_prefers_terminal_metadata_and_keeps_exact_cwd() {
        let contextStripView = ContextStripView()
        let state = PaneStripState(
            panes: [PaneState(id: PaneID("shell"), title: "shell")],
            focusedPaneID: PaneID("shell")
        )

        contextStripView.render(
            workspaceName: "WEB",
            state: state,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory() + "/src/zentty",
                processName: "zsh",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(contextStripView.focusedTextForTesting, "")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "cwd ~/src/zentty")
        XCTAssertEqual(contextStripView.branchTextForTesting, "branch main")
        XCTAssertTrue(contextStripView.isFocusedHiddenForTesting)
        XCTAssertFalse(contextStripView.isHidden)
        XCTAssertFalse(contextStripView.isBranchHiddenForTesting)
    }

    func test_context_strip_falls_back_to_process_then_pane_title_and_hides_missing_branch() {
        let contextStripView = ContextStripView()
        let state = PaneStripState(
            panes: [PaneState(id: PaneID("pane-2"), title: "pane 2")],
            focusedPaneID: PaneID("pane-2")
        )

        contextStripView.render(
            workspaceName: "OPS",
            state: state,
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: nil,
                processName: "fish",
                gitBranch: nil
            )
        )

        XCTAssertEqual(contextStripView.focusedTextForTesting, "fish")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "")
        XCTAssertFalse(contextStripView.isFocusedHiddenForTesting)
        XCTAssertTrue(contextStripView.isBranchHiddenForTesting)

        contextStripView.render(
            workspaceName: "OPS",
            state: state,
            metadata: TerminalMetadata()
        )

        XCTAssertEqual(contextStripView.focusedTextForTesting, "pane 2")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "")
        XCTAssertFalse(contextStripView.isFocusedHiddenForTesting)
        XCTAssertTrue(contextStripView.isBranchHiddenForTesting)
    }

    func test_sidebar_view_emits_selected_workspace_id() throws {
        let sidebarView = SidebarView()
        let nodes = [
            makeTestNode(
                workspaceID: WorkspaceID("workspace-api"),
                primaryText: "shell",
                gitContext: "1 pane",
                isActive: true
            ),
            makeTestNode(
                workspaceID: WorkspaceID("workspace-web"),
                primaryText: "editor",
                gitContext: "project • main",
                isActive: false
            ),
        ]
        var selectedWorkspaceID: WorkspaceID?

        sidebarView.onSelectWorkspace = { selectedWorkspaceID = $0 }
        sidebarView.render(
            nodes: nodes,
            theme: ZenttyTheme.fallback(for: nil)
        )

        let webButton = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.last)
        webButton.performClick(nil)

        XCTAssertEqual(selectedWorkspaceID, WorkspaceID("workspace-web"))
    }

    func test_root_controller_restores_persisted_sidebar_width() {
        let defaults = SidebarWidthPreference.userDefaultsForTesting()
        defaults.set(312, forKey: SidebarWidthPreference.persistenceKey)
        let controller = RootViewController(sidebarWidthDefaults: defaults)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 312, accuracy: 0.001)
    }

    func test_root_controller_uses_new_default_sidebar_width() {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 280, accuracy: 0.001)
    }

    func test_root_controller_keeps_single_pane_full_width_through_initial_layout_and_resize() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let initialPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let initialExpectedWidth = PaneLayoutSizing.balanced.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.sidebarWidthForTesting + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(initialPaneView.frame.width, initialExpectedWidth, accuracy: 0.001)

        controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let resizedPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let resizedExpectedWidth = PaneLayoutSizing.balanced.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.sidebarWidthForTesting + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(resizedPaneView.frame.width, resizedExpectedWidth, accuracy: 0.001)
    }

    func test_root_controller_single_pane_uses_full_width_and_balanced_bottom_gutter() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let borderFrame = paneView.insetBorderFrameForTesting

        XCTAssertEqual(paneView.frame.maxX, appCanvasView.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.minY, PaneLayoutSizing.balanced.bottomInset, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.maxY, appCanvasView.bounds.maxY, accuracy: 0.001)
        XCTAssertLessThan(borderFrame.maxX, paneView.bounds.maxX)
        XCTAssertLessThan(borderFrame.maxY, paneView.bounds.maxY)
    }

    func test_root_controller_multi_pane_visible_gap_matches_bottom_margin() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(paneViews.count, 2)

        let leftPane = paneViews[0]
        let rightPane = paneViews[1]
        let leftBorderFrame = leftPane.insetBorderFrameForTesting
        let rightBorderFrame = rightPane.insetBorderFrameForTesting
        let visibleInterPaneGap = (rightPane.frame.minX + rightBorderFrame.minX)
            - (leftPane.frame.minX + leftBorderFrame.maxX)
        let visibleBottomGap = appCanvasView.frame.minY + leftPane.frame.minY + leftBorderFrame.minY

        XCTAssertEqual(visibleInterPaneGap, visibleBottomGap, accuracy: 1.5)
    }

    func test_root_controller_scales_multi_pane_widths_when_window_resizes() throws {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let initialCanvasWidth = appCanvasView.bounds.width
        let initialPaneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let initialWidths = initialPaneViews.map { $0.frame.width }

        controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let resizedPaneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let resizedWidths = resizedPaneViews.map { $0.frame.width }
        let expectedScaleFactor = appCanvasView.bounds.width / initialCanvasWidth

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        XCTAssertEqual(resizedWidths[0], initialWidths[0] * expectedScaleFactor, accuracy: 0.5)
        XCTAssertEqual(resizedWidths[1], initialWidths[1] * expectedScaleFactor, accuracy: 0.5)
    }

    func test_sidebar_width_clamps_to_supported_range() {
        XCTAssertEqual(SidebarWidthPreference.clamped(120), SidebarWidthPreference.minimumWidth, accuracy: 0.001)
        XCTAssertEqual(SidebarWidthPreference.clamped(500), SidebarWidthPreference.maximumWidth, accuracy: 0.001)
    }

    func test_sidebar_places_add_workspace_button_below_last_row_without_visible_divider() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    primaryText: "shell",
                    gitContext: "project • main"
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebarView.addWorkspaceTitleForTesting, "New workspace")
        XCTAssertFalse(sidebarView.hasVisibleDividerForTesting)
        XCTAssertGreaterThan(sidebarView.firstWorkspaceMinYForTesting, 40)
        XCTAssertGreaterThanOrEqual(sidebarView.addWorkspaceMinYForTesting, ShellMetrics.sidebarBottomInset)
        XCTAssertLessThan(sidebarView.addWorkspaceMaxYForTesting, sidebarView.firstWorkspaceMinYForTesting)
    }

    func test_sidebar_uses_full_width_tabs_and_no_header_label() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(primaryText: "shell")
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertTrue(sidebarView.isHeaderHiddenForTesting)
        XCTAssertGreaterThan(sidebarView.firstWorkspaceWidthForTesting, 258)
    }

    func test_sidebar_workspace_text_uses_slightly_larger_horizontal_inset() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(primaryText: "shell")
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            sidebarView.firstWorkspacePrimaryMinXForTesting,
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarRowHorizontalInset,
            accuracy: 2.5
        )
    }

    func test_sidebar_footer_centers_on_sidebar_and_dims_plus_icon() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(primaryText: "shell")
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            sidebarView.addWorkspaceContentMidXForTesting,
            sidebarView.bounds.midX,
            accuracy: 1
        )
        XCTAssertLessThan(sidebarView.addWorkspaceIconAlphaForTesting, sidebarView.addWorkspaceTitleAlphaForTesting)
    }

    func test_sidebar_resize_hit_area_is_centered_on_outer_edge_without_hover_fill() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(sidebarView.resizeHandleMinXForTesting, sidebarView.bounds.maxX)
        XCTAssertGreaterThan(sidebarView.resizeHandleMaxXForTesting, sidebarView.bounds.maxX)
        XCTAssertEqual(sidebarView.resizeHandleFillAlphaForTesting, 0, accuracy: 0.001)
    }

    func test_sidebar_glass_forces_dark_appearance_for_dark_themes() {
        let glassView = GlassSurfaceView(style: .sidebar)
        glassView.appearance = NSAppearance(named: .aqua)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false
        )

        glassView.apply(theme: theme, animated: false)

        XCTAssertEqual(glassView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    func test_sidebar_glass_forces_light_appearance_for_light_themes() {
        let glassView = GlassSurfaceView(style: .sidebar)
        glassView.appearance = NSAppearance(named: .darkAqua)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#F7FBFF")!,
                foreground: NSColor(hexString: "#102030")!,
                cursorColor: NSColor(hexString: "#2F74D0")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.94,
                backgroundBlurRadius: 18
            ),
            reduceTransparency: false
        )

        glassView.apply(theme: theme, animated: false)

        XCTAssertEqual(glassView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }

    func test_sidebar_row_exposes_single_trailing_artifact_pill() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    primaryText: "Claude Code",
                    attentionState: .needsInput,
                    statusText: "Needs input",
                    gitContext: "project • main",
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #42",
                        url: URL(string: "https://example.com/pr/42")!,
                        isExplicit: true
                    )
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(sidebarView.workspaceArtifactTextsForTesting, ["PR #42"])
    }

    func test_sidebar_needs_input_row_shows_bell_attention_symbol() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    primaryText: "Claude Code",
                    attentionState: .needsInput,
                    statusText: "Needs input",
                    gitContext: "project • main"
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(sidebarView.workspaceAttentionSymbolsForTesting, ["bell.badge.fill"])
    }

    func test_sidebar_compacts_true_single_line_rows_only() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-compact"),
                    primaryText: "shell",
                    isActive: true
                ),
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-expanded"),
                    primaryText: "Claude Code",
                    attentionState: .needsInput,
                    statusText: "Needs input",
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let buttons = sidebarView.workspaceButtonsForTesting
        let compactFrame = try XCTUnwrap(buttons.first?.frame)
        let expandedFrame = try XCTUnwrap(buttons.last?.frame)

        let metrics = WorkspaceRowLayoutMetrics.sidebar
        XCTAssertEqual(compactFrame.height, metrics.height(for: [.primary]), accuracy: 0.5)
        XCTAssertEqual(expandedFrame.height, metrics.height(for: [.primary, .status]), accuracy: 0.5)
        XCTAssertLessThan(compactFrame.height, expandedFrame.height)
    }

    func test_sidebar_keeps_context_rows_expanded() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-context"),
                    primaryText: "shell",
                    gitContext: "main • ~/src/zentty"
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame)
        let metrics = WorkspaceRowLayoutMetrics.sidebar
        XCTAssertEqual(frame.height, metrics.height(for: [.primary, .context]), accuracy: 0.5)
    }

    func test_sidebar_keeps_artifact_rows_expanded() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-artifact"),
                    primaryText: "Claude Code",
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #42",
                        url: URL(string: "https://example.com/pr/42")!,
                        isExplicit: true
                    )
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame)
        let metrics = WorkspaceRowLayoutMetrics.sidebar
        XCTAssertEqual(frame.height, metrics.height(for: [.primary]), accuracy: 0.5)
    }

    func test_sidebar_mixes_compact_and_expanded_rows_without_colliding_with_footer() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            nodes: [
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-compact"),
                    primaryText: "shell",
                    isActive: true
                ),
                makeTestNode(
                    workspaceID: WorkspaceID("workspace-expanded"),
                    primaryText: "Claude Code",
                    attentionState: .needsInput,
                    statusText: "Needs input",
                    gitContext: "main • ~/src/zentty",
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let buttons = sidebarView.workspaceButtonsForTesting
        let firstButton = try XCTUnwrap(buttons.first)
        let secondButton = try XCTUnwrap(buttons.last)
        let firstFrame = sidebarView.convert(firstButton.bounds, from: firstButton)
        let secondFrame = sidebarView.convert(secondButton.bounds, from: secondButton)
        let footerFrame = CGRect(
            x: 0,
            y: sidebarView.addWorkspaceMinYForTesting,
            width: sidebarView.bounds.width,
            height: sidebarView.addWorkspaceMaxYForTesting - sidebarView.addWorkspaceMinYForTesting
        )

        XCTAssertFalse(firstFrame.intersects(secondFrame))
        XCTAssertFalse(firstFrame.union(secondFrame).intersects(footerFrame))
    }

    func test_window_chrome_shows_attention_chip_only_for_attention_states() {
        let windowChromeView = WindowChromeView()
        let state = PaneStripState(
            panes: [PaneState(id: PaneID("shell"), title: "shell")],
            focusedPaneID: PaneID("shell")
        )
        let attention = WorkspaceAttentionSummary(
            paneID: PaneID("shell"),
            tool: .claudeCode,
            state: .needsInput,
            primaryText: "Claude Code",
            statusText: "Needs input",
            contextText: "project • main",
            artifactLink: WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #42",
                url: URL(string: "https://example.com/pr/42")!,
                isExplicit: true
            ),
            updatedAt: Date(timeIntervalSince1970: 42)
        )

        windowChromeView.render(
            workspaceName: "MAIN",
            state: state,
            metadata: TerminalMetadata(title: "Claude Code"),
            attention: attention
        )

        XCTAssertFalse(windowChromeView.isAttentionHiddenForTesting)
        XCTAssertEqual(windowChromeView.attentionTextForTesting, "Needs input")
        XCTAssertEqual(windowChromeView.attentionArtifactTextForTesting, "PR #42")

        windowChromeView.render(
            workspaceName: "MAIN",
            state: state,
            metadata: TerminalMetadata(title: "Claude Code"),
            attention: WorkspaceAttentionSummary(
                paneID: PaneID("shell"),
                tool: .claudeCode,
                state: .running,
                primaryText: "Claude Code",
                statusText: "Running",
                contextText: "project • main",
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 43)
            )
        )

        XCTAssertTrue(windowChromeView.isAttentionHiddenForTesting)

        windowChromeView.render(
            workspaceName: "MAIN",
            state: state,
            metadata: TerminalMetadata(title: "Claude Code"),
            attention: WorkspaceAttentionSummary(
                paneID: PaneID("shell"),
                tool: .claudeCode,
                state: .unresolvedStop,
                primaryText: "Claude Code",
                statusText: "Stopped early",
                contextText: "project • main",
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 44)
            )
        )

        XCTAssertTrue(windowChromeView.isAttentionHiddenForTesting)
    }

    func test_sidebar_emits_focus_pane_on_sub_row_click() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let nodes = [
            WorkspaceSidebarNode(
                header: WorkspaceHeaderSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    primaryText: "shell",
                    paneCount: 2,
                    attentionState: nil,
                    statusText: nil,
                    gitContext: "main",
                    artifactLink: nil,
                    isActive: true
                ),
                panes: [
                    PaneSidebarSummary(
                        paneID: PaneID("pane-1"),
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "shell",
                        attentionState: nil,
                        gitContext: "",
                        isFocused: true
                    ),
                    PaneSidebarSummary(
                        paneID: PaneID("pane-2"),
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "editor",
                        attentionState: nil,
                        gitContext: "",
                        isFocused: false
                    ),
                ]
            )
        ]
        var focusedPair: (WorkspaceID, PaneID)?
        sidebarView.onFocusPane = { wid, pid in focusedPair = (wid, pid) }
        sidebarView.render(nodes: nodes, theme: ZenttyTheme.fallback(for: nil))
        sidebarView.layoutSubtreeIfNeeded()

        // The pane sub-rows should be visible since the active multi-pane workspace auto-expands
        let paneLabels = sidebarView.workspaceButtonsForTesting
            .compactMap { ($0.superview as? WorkspaceGroupView)?.paneLabelsForTesting }
            .first
        XCTAssertEqual(paneLabels, ["shell", "editor"])
        XCTAssertNotNil(focusedPair == nil)
    }

    func test_sidebar_auto_expands_active_multi_pane_workspace() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let nodes = [
            WorkspaceSidebarNode(
                header: WorkspaceHeaderSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    primaryText: "shell",
                    paneCount: 3,
                    attentionState: nil,
                    statusText: nil,
                    gitContext: "main",
                    artifactLink: nil,
                    isActive: true
                ),
                panes: [
                    PaneSidebarSummary(
                        paneID: PaneID("pane-1"),
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "shell",
                        attentionState: nil,
                        gitContext: "",
                        isFocused: true
                    ),
                    PaneSidebarSummary(
                        paneID: PaneID("pane-2"),
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "editor",
                        attentionState: nil,
                        gitContext: "",
                        isFocused: false
                    ),
                    PaneSidebarSummary(
                        paneID: PaneID("pane-3"),
                        workspaceID: WorkspaceID("workspace-main"),
                        primaryText: "tests",
                        attentionState: nil,
                        gitContext: "",
                        isFocused: false
                    ),
                ]
            ),
            makeTestNode(
                workspaceID: WorkspaceID("workspace-2"),
                primaryText: "other",
                paneCount: 1,
                isActive: false
            ),
        ]

        sidebarView.render(nodes: nodes, theme: ZenttyTheme.fallback(for: nil))
        sidebarView.layoutSubtreeIfNeeded()

        // Active multi-pane workspace should auto-expand
        let groupViews = sidebarView.workspaceButtonsForTesting
            .compactMap { $0.superview as? WorkspaceGroupView }

        XCTAssertEqual(groupViews.count, 2)
        XCTAssertTrue(groupViews[0].isExpandedForTesting)
        XCTAssertEqual(groupViews[0].paneLabelsForTesting, ["shell", "editor", "tests"])
        XCTAssertFalse(groupViews[1].isExpandedForTesting)
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

    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func containsDescendant<T: NSView>(ofType type: T.Type) -> Bool {
        subviews.contains { subview in
            subview is T || subview.containsDescendant(ofType: type)
        }
    }

    func containsDescendant(named className: String) -> Bool {
        subviews.contains { subview in
            String(describing: type(of: subview)) == className || subview.containsDescendant(named: className)
        }
    }
}

private func alphaComponent(of cgColor: CGColor?) -> CGFloat {
    guard let cgColor, let color = NSColor(cgColor: cgColor) else {
        return 0
    }

    return color.srgbClamped.alphaComponent
}

private func makeTestNode(
    workspaceID: WorkspaceID = WorkspaceID("workspace-main"),
    primaryText: String = "shell",
    paneCount: Int = 1,
    attentionState: WorkspaceAttentionState? = nil,
    statusText: String? = nil,
    gitContext: String = "",
    artifactLink: WorkspaceArtifactLink? = nil,
    isActive: Bool = true
) -> WorkspaceSidebarNode {
    WorkspaceSidebarNode(
        header: WorkspaceHeaderSummary(
            workspaceID: workspaceID,
            primaryText: primaryText,
            paneCount: paneCount,
            attentionState: attentionState,
            statusText: statusText,
            gitContext: gitContext,
            artifactLink: artifactLink,
            isActive: isActive
        ),
        panes: []
    )
}
