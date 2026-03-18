import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: XCTestCase {
    override func tearDown() {
        SidebarWidthPreference.resetForTesting()
        SidebarVisibilityPreference.resetForTesting()
        PaneLayoutPreferenceStore.resetForTesting()
        super.tearDown()
    }

    private func makeController(
        sidebarWidthDefaults: UserDefaults = SidebarWidthPreference.userDefaultsForTesting(),
        sidebarVisibilityDefaults: UserDefaults = SidebarVisibilityPreference.userDefaultsForTesting(),
        paneLayoutDefaults: UserDefaults = PaneLayoutPreferenceStore.userDefaultsForTesting(),
        initialLayoutContext: PaneLayoutContext = .fallback
    ) -> RootViewController {
        RootViewController(
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults,
            initialLayoutContext: initialLayoutContext
        )
    }

    func test_root_controller_layers_full_width_canvas_beneath_sidebar_overlay() throws {
        let controller = makeController()
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
        XCTAssertEqual(sidebarView?.workspacePrimaryTextsForTesting, ["~"])
        XCTAssertEqual(sidebarView?.workspaceContextTextsForTesting, [""])
        XCTAssertEqual(
            appCanvasView.frame.minX,
            ShellMetrics.outerInset,
            accuracy: 0.5
        )
    }

    func test_root_controller_keeps_window_chrome_as_sibling_overlay_above_canvas() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let rootSubviews = controller.view.subviews
        let appCanvasView = try XCTUnwrap(rootSubviews.first { $0 is AppCanvasView })
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView })

        XCTAssertTrue(rootSubviews.contains { $0 is SidebarView })
        XCTAssertFalse(rootSubviews.contains { $0 is ContentShellView })
        XCTAssertFalse(appCanvasView.containsDescendant(ofType: WindowChromeView.self))
        XCTAssertEqual(windowChromeView.frame.minY, appCanvasView.frame.maxY, accuracy: 0.5)
    }

    func test_root_controller_layers_sidebar_above_chrome_and_toggle_above_sidebar() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let rootSubviews = controller.view.subviews
        let appCanvasIndex = try XCTUnwrap(rootSubviews.firstIndex { $0 is AppCanvasView })
        let chromeIndex = try XCTUnwrap(rootSubviews.firstIndex { $0 is WindowChromeView })
        let sidebarIndex = try XCTUnwrap(rootSubviews.firstIndex { $0 is SidebarView })
        let toggleIndex = try XCTUnwrap(rootSubviews.firstIndex { $0 is SidebarToggleOverlayView })

        XCTAssertGreaterThan(chromeIndex, appCanvasIndex)
        XCTAssertGreaterThan(sidebarIndex, chromeIndex)
        XCTAssertGreaterThan(toggleIndex, sidebarIndex)
    }

    func test_chrome_geometry_derives_nested_radii_from_edge_to_edge_insets() {
        XCTAssertEqual(ChromeGeometry.contentShellRadius, ChromeGeometry.innerRadius(
            outerRadius: ChromeGeometry.outerWindowRadius,
            inset: ChromeGeometry.shellInset
        ))
        XCTAssertEqual(ChromeGeometry.sidebarRadius, ChromeGeometry.contentShellRadius)
        XCTAssertEqual(ChromeGeometry.paneRadius, ChromeGeometry.innerRadius(
            outerRadius: ChromeGeometry.contentShellRadius,
            inset: ChromeGeometry.paneInset
        ))
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

        XCTAssertGreaterThan(rawInset, 0.5)
        XCTAssertEqual(rawInset, 0.9500712252157548, accuracy: 0.000001)
        XCTAssertEqual(backingPixelInset, 0.5, accuracy: 0.001)
        XCTAssertEqual(roundedInset, 1.5, accuracy: 0.001)
    }

    func test_root_controller_applies_outer_shell_geometry_to_live_root_view() {
        let controller = makeController()

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

    func test_window_chrome_keeps_only_trailing_context_strip_without_title_label() {
        let windowChromeView = WindowChromeView()

        XCTAssertEqual(windowChromeView.titleTextForTesting, "")
    }

    func test_sidebar_toggle_overlay_reflects_sidebar_visibility_state_and_anchor() {
        let overlayView = SidebarToggleOverlayView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))

        overlayView.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)
        overlayView.setSidebarVisibility(.pinnedOpen, animated: false)
        overlayView.setTrafficLightAnchor(trailingX: 72)
        overlayView.layoutSubtreeIfNeeded()

        XCTAssertTrue(overlayView.isToggleActiveForTesting)
        XCTAssertEqual(overlayView.toggleMinXForTesting, 84, accuracy: 0.5)

        overlayView.setSidebarVisibility(.hidden, animated: false)

        XCTAssertFalse(overlayView.isToggleActiveForTesting)
    }

    func test_sidebar_toggle_overlay_aligns_to_live_traffic_light_midpoint() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        let overlayView = SidebarToggleOverlayView(frame: NSRect(x: 0, y: 180, width: 360, height: 60))
        hostView.addSubview(overlayView)

        overlayView.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)
        overlayView.setTrafficLightAnchor(trailingX: 72, midYInSuperview: 210)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlayView.toggleFrameInSuperviewForTesting.midY, 210, accuracy: 0.5)
    }

    func test_sidebar_toggle_overlay_updates_frame_immediately_when_anchor_changes() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        let overlayView = SidebarToggleOverlayView(frame: NSRect(x: 0, y: 180, width: 360, height: 60))
        hostView.addSubview(overlayView)
        hostView.layoutSubtreeIfNeeded()

        let initialFrame = overlayView.toggleFrameInSuperviewForTesting

        overlayView.setTrafficLightAnchor(trailingX: 72, midYInSuperview: 210)

        XCTAssertNotEqual(overlayView.toggleFrameInSuperviewForTesting, initialFrame)
        XCTAssertEqual(overlayView.toggleFrameInSuperviewForTesting.minX, 84, accuracy: 0.5)
        XCTAssertEqual(overlayView.toggleFrameInSuperviewForTesting.midY, 210, accuracy: 0.5)
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
        let summaries = [
            WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-api"),
                title: "API",
                badgeText: "A",
                primaryText: "shell",
                statusText: nil,
                contextText: "1 pane",
                attentionState: nil,
                artifactLink: nil,
                isActive: true,
                showsGeneratedTitle: true
            ),
            WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-web"),
                title: "WEB",
                badgeText: "W",
                primaryText: "editor",
                statusText: nil,
                contextText: "project • main",
                attentionState: nil,
                artifactLink: nil,
                isActive: false,
                showsGeneratedTitle: true
            ),
        ]
        var selectedWorkspaceID: WorkspaceID?

        sidebarView.onSelectWorkspace = { selectedWorkspaceID = $0 }
        sidebarView.render(
            summaries: summaries,
            theme: ZenttyTheme.fallback(for: nil)
        )

        let webButton = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.last)
        webButton.performClick(nil)

        XCTAssertEqual(selectedWorkspaceID, WorkspaceID("workspace-web"))
    }

    func test_root_controller_restores_persisted_sidebar_width() {
        let defaults = SidebarWidthPreference.userDefaultsForTesting()
        defaults.set(312, forKey: SidebarWidthPreference.persistenceKey)
        let controller = makeController(sidebarWidthDefaults: defaults)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 312, accuracy: 0.001)
    }

    func test_root_controller_uses_new_default_sidebar_width() {
        let controller = makeController()

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 280, accuracy: 0.001)
    }

    func test_root_controller_keeps_single_pane_full_width_through_initial_layout_and_resize() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let initialPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let initialExpectedWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.sidebarWidthForTesting + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(initialPaneView.frame.width, initialExpectedWidth, accuracy: 0.001)

        controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let resizedPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let resizedExpectedWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.sidebarWidthForTesting + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(resizedPaneView.frame.width, resizedExpectedWidth, accuracy: 0.001)
    }

    func test_root_controller_single_pane_preserves_readable_trailing_inset_and_bottom_spacing() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView })
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrameForTesting, to: controller.view)
        let leftGapToSidebar = borderFrameInRoot.minX - sidebarView.frame.maxX
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(paneView.frame.maxY, appCanvasView.bounds.maxY, accuracy: 0.001)
        XCTAssertEqual(leftGapToSidebar, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, leftGapToSidebar, accuracy: 0.001)
        XCTAssertLessThan(borderFrameInRoot.maxX, controller.view.bounds.maxX)
        XCTAssertLessThan(borderFrameInRoot.maxY, controller.view.bounds.maxY)
    }

    func test_root_controller_sidebar_toggle_relays_layout_change_as_single_canvas_transition() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let initialRenderCount = appCanvasView.paneStripRenderCountForTesting

        controller.handleSidebarVisibilityEventForTesting(.togglePressed)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(appCanvasView.paneStripRenderCountForTesting - initialRenderCount, 1)
        XCTAssertEqual(appCanvasView.lastLeadingVisibleInsetForTesting, 0, accuracy: 0.001)
        XCTAssertTrue(appCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_root_controller_scales_multi_pane_widths_when_window_resizes() throws {
        let controller = makeController()
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
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "project • main",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
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
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                )
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
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            sidebarView.firstWorkspacePrimaryMinXForTesting,
            ShellMetrics.sidebarContentInset + 10,
            accuracy: 0.5
        )
    }

    func test_sidebar_uses_conditional_icon_gutter_only_when_any_row_has_accessory() throws {
        let withAccessorySidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        withAccessorySidebar.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-home"),
                    badgeText: "H",
                    topLabel: nil,
                    primaryText: "~",
                    statusText: nil,
                    detailLines: [],
                    overflowText: nil,
                    leadingAccessory: .home,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true
                ),
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-project"),
                    badgeText: "P",
                    topLabel: nil,
                    primaryText: "feature/sidebar",
                    statusText: nil,
                    detailLines: [
                        WorkspaceSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                    ],
                    overflowText: nil,
                    leadingAccessory: nil,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        withAccessorySidebar.layoutSubtreeIfNeeded()

        let withoutAccessorySidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        withoutAccessorySidebar.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-project-a"),
                    badgeText: "A",
                    topLabel: nil,
                    primaryText: "feature/sidebar",
                    statusText: nil,
                    detailLines: [],
                    overflowText: nil,
                    leadingAccessory: nil,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true
                ),
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-project-b"),
                    badgeText: "B",
                    topLabel: nil,
                    primaryText: "marketing-site",
                    statusText: nil,
                    detailLines: [],
                    overflowText: nil,
                    leadingAccessory: nil,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        withoutAccessorySidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            withAccessorySidebar.firstWorkspacePrimaryMinXForTesting,
            withAccessorySidebar.secondWorkspacePrimaryMinXForTesting,
            accuracy: 0.5
        )
        XCTAssertLessThan(
            withoutAccessorySidebar.firstWorkspacePrimaryMinXForTesting,
            withAccessorySidebar.firstWorkspacePrimaryMinXForTesting
        )
        XCTAssertEqual(
            withoutAccessorySidebar.firstWorkspacePrimaryMinXForTesting,
            withoutAccessorySidebar.secondWorkspacePrimaryMinXForTesting,
            accuracy: 0.5
        )
    }

    func test_sidebar_renders_all_detail_lines_in_order_for_multi_pane_rows() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    badgeText: "M",
                    topLabel: "Docs",
                    primaryText: "feature/sidebar",
                    statusText: nil,
                    detailLines: [
                        WorkspaceSidebarDetailLine(text: "main • git", emphasis: .primary),
                        WorkspaceSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
                        WorkspaceSidebarDetailLine(text: "tests • specs", emphasis: .secondary),
                    ],
                    overflowText: nil,
                    leadingAccessory: nil,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(
            sidebarView.workspaceDetailTextsForTesting.first,
            [
                "main • git",
                "notes • copy",
                "tests • specs",
            ]
        )
        XCTAssertEqual(sidebarView.workspaceOverflowTextsForTesting, [""])
    }

    func test_sidebar_keeps_last_detail_line_inside_button_bounds_for_tall_rows() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let lastDetailText = "peter@m1-pro-peter:~/Rails/nimbu"

        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    badgeText: "M",
                    topLabel: nil,
                    primaryText: "peter@m1-pro-peter:~/Development/Personal/worktrees/feature/sidebar",
                    statusText: nil,
                    detailLines: [
                        WorkspaceSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .primary),
                        WorkspaceSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorkspaceSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorkspaceSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorkspaceSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorkspaceSidebarDetailLine(text: lastDetailText, emphasis: .secondary),
                    ],
                    overflowText: nil,
                    leadingAccessory: nil,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first)
        let lastDetailLabel = try XCTUnwrap(
            button.descendantLabel(withText: lastDetailText)
        )
        let lastDetailFrame = button.convert(lastDetailLabel.bounds, from: lastDetailLabel)

        XCTAssertGreaterThanOrEqual(lastDetailFrame.minY, -0.5)
        XCTAssertLessThanOrEqual(lastDetailFrame.maxY, button.bounds.maxY + 0.5)
    }

    func test_sidebar_renders_home_accessory_with_sf_symbol() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-home"),
                    badgeText: "H",
                    topLabel: nil,
                    primaryText: "~",
                    statusText: nil,
                    detailLines: [],
                    overflowText: nil,
                    leadingAccessory: .home,
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(sidebarView.workspaceLeadingAccessorySymbolsForTesting, ["house"])
        XCTAssertEqual(sidebarView.workspaceDetailTextsForTesting.first, [])
    }

    func test_sidebar_footer_centers_on_sidebar_and_dims_plus_icon() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                )
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

    func test_sidebar_hides_resize_handle_when_resize_is_disabled() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        sidebarView.setResizeEnabled(false)

        XCTAssertTrue(sidebarView.isResizeHandleHiddenForTesting)
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
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "Claude Code",
                    statusText: "Needs input",
                    contextText: "project • main",
                    attentionState: .needsInput,
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #42",
                        url: URL(string: "https://example.com/pr/42")!,
                        isExplicit: true
                    ),
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(sidebarView.workspaceArtifactTextsForTesting, ["PR #42"])
    }

    func test_sidebar_compacts_true_single_line_rows_only() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-compact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                ),
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-expanded"),
                    title: "Claude Code",
                    badgeText: "C",
                    primaryText: "Claude Code",
                    statusText: "Needs input",
                    contextText: "",
                    attentionState: .needsInput,
                    artifactLink: nil,
                    isActive: false,
                    showsGeneratedTitle: true
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let buttons = sidebarView.workspaceButtonsForTesting
        let compactFrame = try XCTUnwrap(buttons.first?.frame)
        let expandedFrame = try XCTUnwrap(buttons.last?.frame)

        XCTAssertEqual(compactFrame.height, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.5)
        XCTAssertEqual(
            expandedFrame.height,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: true,
                includesStatus: true,
                detailLineCount: 0,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.5
        )
        XCTAssertLessThan(compactFrame.height, expandedFrame.height)
    }

    func test_sidebar_keeps_context_rows_expanded() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-context"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "main • ~/src/zentty",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame)
        XCTAssertEqual(
            frame.height,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 1,
                includesOverflow: false,
                includesArtifact: false
            ),
            accuracy: 0.5
        )
    }

    func test_sidebar_keeps_artifact_rows_expanded() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-artifact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "Claude Code",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: WorkspaceArtifactLink(
                        kind: .pullRequest,
                        label: "PR #42",
                        url: URL(string: "https://example.com/pr/42")!,
                        isExplicit: true
                    ),
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.first?.frame)
        XCTAssertEqual(frame.height, ShellMetrics.sidebarExpandedRowHeight, accuracy: 0.5)
    }

    func test_sidebar_mixes_compact_and_expanded_rows_without_colliding_with_footer() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-compact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    statusText: nil,
                    contextText: "",
                    attentionState: nil,
                    artifactLink: nil,
                    isActive: true,
                    showsGeneratedTitle: false
                ),
                WorkspaceSidebarSummary(
                    workspaceID: WorkspaceID("workspace-expanded"),
                    title: "Claude Code",
                    badgeText: "C",
                    primaryText: "Claude Code",
                    statusText: "Needs input",
                    contextText: "main • ~/src/zentty",
                    attentionState: .needsInput,
                    artifactLink: nil,
                    isActive: false,
                    showsGeneratedTitle: true
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
    }

    func test_root_controller_restores_hidden_sidebar_and_reclaims_leading_inset() throws {
        let sidebarDefaults = SidebarWidthPreference.userDefaultsForTesting()
        let visibilityDefaults = SidebarVisibilityPreference.userDefaultsForTesting()
        SidebarVisibilityPreference.persist(.hidden, in: visibilityDefaults)
        let controller = makeController(
            sidebarWidthDefaults: sidebarDefaults,
            sidebarVisibilityDefaults: visibilityDefaults
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first as PaneContainerView?)
        let expectedWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: 0
        )
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrameForTesting, to: controller.view)
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(controller.sidebarVisibilityModeForTesting, .hidden)
        XCTAssertEqual(appCanvasView.leadingVisibleInset, 0, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.width, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(borderFrameInRoot.minX, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertFalse(controller.isSidebarFloatingForTesting)
    }

    func test_root_controller_hover_peek_keeps_overlay_sidebar_out_of_layout() throws {
        let visibilityDefaults = SidebarVisibilityPreference.userDefaultsForTesting()
        SidebarVisibilityPreference.persist(.hidden, in: visibilityDefaults)
        let controller = makeController(
            sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting(),
            sidebarVisibilityDefaults: visibilityDefaults
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handleSidebarVisibilityEventForTesting(.hoverRailEntered)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first as PaneContainerView?)
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrameForTesting, to: controller.view)
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(controller.sidebarVisibilityModeForTesting, .hoverPeek)
        XCTAssertEqual(appCanvasView.leadingVisibleInset, 0, accuracy: 0.001)
        XCTAssertEqual(borderFrameInRoot.minX, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertTrue(controller.isSidebarFloatingForTesting)
        XCTAssertFalse(appCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }
}

private extension NSView {
    func descendantLabel(withText text: String) -> NSTextField? {
        if let label = self as? NSTextField, label.stringValue == text {
            return label
        }

        for subview in subviews {
            if let match = subview.descendantLabel(withText: text) {
                return match
            }
        }

        return nil
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
