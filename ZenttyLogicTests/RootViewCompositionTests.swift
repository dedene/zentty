import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: AppKitTestCase {
    override func tearDown() {
        SidebarWidthPreference.reset()
        SidebarVisibilityPreference.reset()
        PaneLayoutPreferenceStore.reset()
        super.tearDown()
    }

    private func makeController(
        sidebarWidthDefaults: UserDefaults = SidebarWidthPreference.userDefaults(),
        sidebarVisibilityDefaults: UserDefaults = SidebarVisibilityPreference.userDefaults(),
        paneLayoutDefaults: UserDefaults = PaneLayoutPreferenceStore.userDefaults(),
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        initialLayoutContext: PaneLayoutContext = .fallback
    ) -> RootViewController {
        let controller = RootViewController(
            appUpdateStateStore: appUpdateStateStore,
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults,
            initialLayoutContext: initialLayoutContext
        )
        addTeardownBlock {
            MainActor.assumeIsolated {
                controller.prepareForTestingTearDown()
            }
        }
        return controller
    }

    @MainActor
    @discardableResult
    private func hostInVisibleWindow(
        _ controller: RootViewController,
        frame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 840)
    ) -> NSWindow {
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        addTeardownBlock {
            window.orderOut(nil)
            window.close()
        }
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func makeSidebarSummary(
        worklaneID: WorklaneID,
        title: String,
        badgeText: String,
        primaryText: String,
        statusText: String? = nil,
        contextText: String = "",
        attentionState: WorklaneAttentionState? = nil,
        isWorking: Bool = false,
        isActive: Bool,
        showsGeneratedTitle: Bool
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: worklaneID,
            badgeText: badgeText,
            topLabel: showsGeneratedTitle ? title : nil,
            primaryText: primaryText,
            statusText: statusText,
            detailLines: WorklaneContextFormatter.trimmed(contextText).map {
                [WorklaneSidebarDetailLine(text: $0, emphasis: .secondary)]
            } ?? [],
            attentionState: attentionState,
            isWorking: isWorking,
            isActive: isActive
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
        XCTAssertEqual(sidebarView?.worklanePrimaryTexts, ["~"])
        XCTAssertEqual(sidebarView?.worklaneContextTexts, [""])
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
        XCTAssertFalse(appCanvasView.containsDescendant(ofType: WindowChromeView.self))
        XCTAssertEqual(
            windowChromeView.frame.minY - appCanvasView.frame.maxY,
            ShellMetrics.headerOuterPadding,
            accuracy: 0.5
        )
    }

    func test_copy_path_toast_mounts_inside_canvas_view() throws {
        let controller = makeController()
        let paneID = PaneID("pane-editor")
        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "editor")],
                    focusedPaneID: paneID
                ),
                auxiliaryStateByPaneID: [
                    paneID: PaneAuxiliaryState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/Users/peter/src/zentty",
                            home: "/Users/peter",
                            user: "peter",
                            host: "zenbook"
                        )
                    )
                ]
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()

        controller.triggerCopyFocusedPanePathForTesting()

        let toast = try XCTUnwrap(controller.pathCopiedToastViewForTesting)
        let canvasView = controller.appCanvasViewForTesting

        XCTAssertTrue(toast.isDescendant(of: canvasView))
        XCTAssertEqual(toast.frame.midX, canvasView.bounds.midX, accuracy: 0.5)
    }

    func test_global_search_hud_is_positioned_inside_top_right_of_canvas_area() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.globalFind)
        controller.view.layoutSubtreeIfNeeded()

        let rootSubviews = controller.view.subviews
        let appCanvasView = try XCTUnwrap(rootSubviews.first { $0 is AppCanvasView })
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView })
        let globalSearchHUDView = try XCTUnwrap(rootSubviews.first { $0 is WindowSearchHUDView })

        XCTAssertLessThanOrEqual(globalSearchHUDView.frame.maxY, appCanvasView.frame.maxY - 13.5)
        XCTAssertGreaterThanOrEqual(globalSearchHUDView.frame.maxX, appCanvasView.frame.maxX - 14.5)
        XCTAssertLessThan(globalSearchHUDView.frame.maxY, windowChromeView.frame.minY)
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
        let leadingControlsIndex = try XCTUnwrap(
            rootSubviews.firstIndex { $0 is LeadingChromeControlsBar }
        )

        XCTAssertGreaterThan(chromeIndex, appCanvasIndex)
        XCTAssertGreaterThan(sidebarIndex, chromeIndex)
        XCTAssertGreaterThan(leadingControlsIndex, sidebarIndex)
    }

    func test_root_controller_binds_sidebar_update_row_visibility_to_app_update_state() throws {
        let appUpdateStateStore = AppUpdateStateStore()
        let controller = makeController(appUpdateStateStore: appUpdateStateStore)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        XCTAssertTrue(sidebarView.isUpdateRowHiddenForTesting)

        appUpdateStateStore.setUpdateAvailable(true)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(sidebarView.isUpdateRowHiddenForTesting)
        XCTAssertEqual(sidebarView.updateAvailableRowHeightForTesting, 28, accuracy: 0.001)
    }

    func test_root_controller_places_arrange_button_between_sidebar_toggle_and_navigation_buttons() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let sidebarToggleButton = try XCTUnwrap(
            controller.view.firstDescendant(ofType: SidebarToggleButton.self)
        )
        let paneLayoutMenuButton = try XCTUnwrap(
            controller.view.firstDescendant(ofType: PaneLayoutMenuButton.self)
        )
        let paneNavigationButtons = try XCTUnwrap(
            controller.view.firstDescendant(ofType: PaneNavigationButtons.self)
        )

        XCTAssertEqual(paneLayoutMenuButton.frame.minX, sidebarToggleButton.frame.maxX + 4, accuracy: 0.5)
        XCTAssertEqual(paneNavigationButtons.frame.minX, paneLayoutMenuButton.frame.maxX + 4, accuracy: 0.5)
        XCTAssertEqual(paneLayoutMenuButton.frame.midY, sidebarToggleButton.frame.midY, accuracy: 0.5)
    }

    func test_root_controller_exposes_arrange_menu_commands_with_split_and_arrange_sections() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(
            controller.paneLayoutMenuCommandTitlesForTesting(),
            [
                "Split Horizontally",
                "Split Vertically",
                "Width Presets",
                "Height Presets",
            ]
        )

        XCTAssertEqual(
            controller.paneLayoutSubmenuCommandTitlesForTesting("Width Presets"),
            [
                "Arrange Width: Full Width",
                "Arrange Width: Half Width",
                "Arrange Width: Thirds",
                "Arrange Width: Quarters",
                "Arrange Width: Golden — Focus Wide",
                "Arrange Width: Golden — Focus Narrow",
            ]
        )

        XCTAssertEqual(
            controller.paneLayoutSubmenuCommandTitlesForTesting("Height Presets"),
            [
                "Arrange Height: Full Height",
                "Arrange Height: 2 Per Column",
                "Arrange Height: 3 Per Column",
                "Arrange Height: 4 Per Column",
                "Arrange Height: Golden — Focus Tall",
                "Arrange Height: Golden — Focus Short",
            ]
        )
    }

    func test_root_controller_handle_arrange_width_command_updates_active_pane_strip_state() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    columns: [
                        PaneColumnState(
                            id: PaneColumnID("left"),
                            panes: [PaneState(id: PaneID("a"), title: "a")],
                            width: 320,
                            focusedPaneID: PaneID("a"),
                            lastFocusedPaneID: PaneID("a")
                        ),
                        PaneColumnState(
                            id: PaneColumnID("right"),
                            panes: [PaneState(id: PaneID("b"), title: "b")],
                            width: 520,
                            focusedPaneID: PaneID("b"),
                            lastFocusedPaneID: PaneID("b")
                        ),
                    ],
                    focusedColumnID: PaneColumnID("left")
                )
            ),
        ])

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let expectedWidth = controller.paneStripStateForTesting.arrangedColumnWidth(
            for: 2,
            availableWidth: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset
        )

        controller.handle(.pane(.arrangeHorizontally(.halfWidth)))

        XCTAssertEqual(controller.paneStripStateForTesting.columns[0].width, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(controller.paneStripStateForTesting.columns[1].width, expectedWidth, accuracy: 0.001)
    }

    func test_root_controller_keeps_window_chrome_content_to_right_of_sidebar_visible_lane() throws {
        let controller = makeControllerWithCrowdedHeader(width: 1280)
        let rootSubviews = controller.view.subviews
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView } as? WindowChromeView)
        let rowFrame = frameInRoot(windowChromeView.rowFrame, within: windowChromeView)
        let visibleLaneFrame = frameInRoot(windowChromeView.visibleLaneFrame, within: windowChromeView)

        XCTAssertGreaterThanOrEqual(rowFrame.minX, visibleLaneFrame.minX - 0.5)
    }

    func test_root_controller_expands_window_chrome_content_across_visible_lane_on_wide_windows() throws {
        let controller = makeControllerWithCrowdedHeader(width: 1440)
        let rootSubviews = controller.view.subviews
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView } as? WindowChromeView)
        let rowFrame = frameInRoot(windowChromeView.rowFrame, within: windowChromeView)
        let visibleLaneFrame = frameInRoot(windowChromeView.visibleLaneFrame, within: windowChromeView)

        XCTAssertEqual(rowFrame.minX, visibleLaneFrame.minX, accuracy: 1.0)
        XCTAssertEqual(rowFrame.width, visibleLaneFrame.width, accuracy: 1.0)
    }

    func test_root_controller_updates_window_chrome_visible_lane_when_sidebar_width_changes() throws {
        let controller = makeControllerWithCrowdedHeader(width: 1280)
        let rootSubviews = controller.view.subviews
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView } as? WindowChromeView)

        controller.setSidebarWidth(340)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            windowChromeView.leadingVisibleInset,
            340 + ShellMetrics.shellGap,
            accuracy: 0.5
        )

        let rowFrame = frameInRoot(windowChromeView.rowFrame, within: windowChromeView)
        let visibleLaneFrame = frameInRoot(windowChromeView.visibleLaneFrame, within: windowChromeView)
        XCTAssertGreaterThanOrEqual(rowFrame.minX, visibleLaneFrame.minX - 0.5)
    }

    func test_root_controller_ignores_redundant_max_sidebar_width_updates() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        controller.setSidebarWidth(10_000)
        controller.view.layoutSubtreeIfNeeded()

        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let clampedWidth = SidebarWidthPreference.maximumWidth(for: controller.view.bounds.width)
        let initialRenderCount = appCanvasView.paneStripRenderCountForTesting
        let initialLeadingInset = appCanvasView.leadingVisibleInset
        let initialBorderFrame = paneView.visibleInsetBorderFrameForTesting

        controller.setSidebarWidth(10_000)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.currentSidebarWidth, clampedWidth, accuracy: 0.001)
        XCTAssertEqual(appCanvasView.paneStripRenderCountForTesting, initialRenderCount)
        XCTAssertEqual(appCanvasView.leadingVisibleInset, initialLeadingInset, accuracy: 0.001)
        XCTAssertEqual(paneView.visibleInsetBorderFrameForTesting, initialBorderFrame)
    }

    func test_root_controller_visible_lane_starts_at_actual_trailing_edge_of_left_controls() throws {
        let controller = makeControllerWithCrowdedHeader(width: 1280)
        let rootSubviews = controller.view.subviews
        let windowChromeView = try XCTUnwrap(rootSubviews.first { $0 is WindowChromeView } as? WindowChromeView)
        let leadingControlsBar = try XCTUnwrap(
            rootSubviews.first { $0 is LeadingChromeControlsBar } as? LeadingChromeControlsBar
        )

        let barMaxXInChrome = leadingControlsBar.frame.maxX - windowChromeView.frame.minX

        XCTAssertEqual(
            windowChromeView.visibleLaneFrame.minX,
            barMaxXInChrome,
            accuracy: 0.5
        )
    }

    func test_root_controller_animates_width_preset_with_split_curve() throws {
        let controller = makeController()
        hostInVisibleWindow(controller)

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        XCTAssertTrue(appCanvasView.lastPaneStripRenderWasAnimatedForTesting)

        controller.handle(.pane(.arrangeHorizontally(.halfWidth)))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(appCanvasView.lastPaneStripRenderWasAnimatedForTesting)
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
        XCTAssertEqual(borderWidth, 0, accuracy: 0.001)
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

    func test_sidebar_toggle_button_reflects_active_state() {
        let button = SidebarToggleButton()
        let theme = ZenttyTheme.fallback(for: nil)

        button.configure(theme: theme, isActive: true, animated: false)
        XCTAssertTrue(button.isActive)

        button.configure(theme: theme, isActive: false, animated: false)
        XCTAssertFalse(button.isActive)
    }
    func test_sidebar_view_emits_selected_worklane_id() throws {
        let sidebarView = SidebarView()
        let summaries = [
            makeSidebarSummary(
                worklaneID: WorklaneID("worklane-api"),
                title: "API",
                badgeText: "A",
                primaryText: "shell",
                contextText: "1 pane",
                isActive: true,
                showsGeneratedTitle: true
            ),
            makeSidebarSummary(
                worklaneID: WorklaneID("worklane-web"),
                title: "WEB",
                badgeText: "W",
                primaryText: "editor",
                contextText: "project • main",
                isActive: false,
                showsGeneratedTitle: true
            ),
        ]
        var selectedID: WorklaneID?
        sidebarView.onWorklaneSelected = { selectedID = $0 }
        sidebarView.render(
            summaries: summaries,
            theme: ZenttyTheme.fallback(for: nil)
        )

        let webButton = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.last)
        webButton.performClick(nil)

        XCTAssertEqual(selectedID, WorklaneID("worklane-web"))
    }

    func test_root_controller_restores_persisted_sidebar_width() {
        let defaults = SidebarWidthPreference.userDefaults()
        defaults.set(312, forKey: SidebarWidthPreference.persistenceKey)
        let controller = makeController(sidebarWidthDefaults: defaults)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.currentSidebarWidth, 312, accuracy: 0.001)
    }

    func test_root_controller_uses_new_default_sidebar_width() {
        let controller = makeController()

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.currentSidebarWidth, 280, accuracy: 0.001)
    }

    func test_root_controller_keeps_single_pane_full_width_through_initial_layout_and_resize() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let initialPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let initialExpectedWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.currentSidebarWidth + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(initialPaneView.frame.width, initialExpectedWidth, accuracy: 0.001)

        controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let resizedPaneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let resizedExpectedWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: controller.currentSidebarWidth + ShellMetrics.canvasSidebarGap
        )

        XCTAssertEqual(resizedPaneView.frame.width, resizedExpectedWidth, accuracy: 0.001)
    }

    func test_root_controller_single_pane_preserves_readable_trailing_inset_and_bottom_spacing() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView })
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first)
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrame, to: controller.view)
        let leftGapToSidebar = borderFrameInRoot.minX - sidebarView.frame.maxX
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(
            paneView.frame.maxY,
            appCanvasView.bounds.maxY - PaneLayoutSizing.edgeAligned.topInset,
            accuracy: 0.001
        )
        XCTAssertEqual(leftGapToSidebar, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, leftGapToSidebar, accuracy: 0.001)
        XCTAssertLessThan(borderFrameInRoot.maxX, controller.view.bounds.maxX)
        XCTAssertLessThan(borderFrameInRoot.maxY, controller.view.bounds.maxY)
    }

    func test_root_controller_sidebar_toggle_relays_layout_change_as_single_canvas_transition() throws {
        let controller = makeController()
        hostInVisibleWindow(controller)

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let initialRenderCount = appCanvasView.paneStripRenderCountForTesting

        controller.handleSidebarVisibilityEvent(.togglePressed)
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

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let initialReadableWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset
        )
        let initialPaneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let initialWidths = initialPaneViews.map { $0.frame.width }

        controller.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let resizedPaneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let resizedWidths = resizedPaneViews.map { $0.frame.width }
        let expectedScaleFactor = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset
        ) / initialReadableWidth

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        XCTAssertEqual(resizedWidths[0], initialWidths[0] * expectedScaleFactor, accuracy: 1.0)
        XCTAssertEqual(resizedWidths[1], initialWidths[1] * expectedScaleFactor, accuracy: 1.0)
    }

    func test_sidebar_width_clamps_to_supported_range() {
        XCTAssertEqual(SidebarWidthPreference.clamped(120), SidebarWidthPreference.minimumWidth, accuracy: 0.001)
        XCTAssertEqual(SidebarWidthPreference.clamped(500), SidebarWidthPreference.maximumWidth, accuracy: 0.001)
        XCTAssertEqual(
            SidebarWidthPreference.clamped(500, availableWidth: 900),
            SidebarWidthPreference.maximumWidth(for: 900),
            accuracy: 0.001
        )
    }

    func test_sidebar_maximum_width_respects_minimum_content_area() {
        // 33% of 500 = 165 < minimumWidth (180), so minimumWidth wins
        XCTAssertEqual(
            SidebarWidthPreference.maximumWidth(for: 500),
            SidebarWidthPreference.minimumWidth,
            accuracy: 0.001
        )

        // 33% of 700 = 231; content guard = 500; fraction is binding
        XCTAssertEqual(
            SidebarWidthPreference.maximumWidth(for: 700),
            231,
            accuracy: 0.001
        )

        // Small window: fraction = floor(380*0.33) = 125, content guard = 180.
        // min(125, 180) = 125. max(180, 125) = 180 (minimumWidth wins)
        XCTAssertEqual(
            SidebarWidthPreference.clamped(9999, availableWidth: 380),
            SidebarWidthPreference.minimumWidth,
            accuracy: 0.001
        )

        // Large window: fraction-based max governs as before
        XCTAssertEqual(
            SidebarWidthPreference.maximumWidth(for: 1440),
            floor(1440 * 0.33),
            accuracy: 0.001
        )
    }

    func test_sidebar_places_add_worklane_button_in_header_above_first_row_without_visible_divider() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.updateHeaderLayout(visibilityMode: .pinnedOpen, pinnedContentMinX: 72)
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "project • main",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebarView.addWorklaneTitle, "New worklane")
        XCTAssertFalse(sidebarView.hasVisibleDivider)
        XCTAssertFalse(sidebarView.isHeaderHidden)
        XCTAssertGreaterThan(sidebarView.firstWorklaneMinY, ShellMetrics.sidebarBottomInset)
        XCTAssertGreaterThan(sidebarView.addWorklaneMinY, sidebarView.firstWorklaneMaxY)
    }

    func test_sidebar_uses_full_width_tabs_and_keeps_header_button_visible() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertFalse(sidebarView.isHeaderHidden)
        XCTAssertGreaterThan(sidebarView.firstWorklaneWidth, 258)
    }

    func test_sidebar_worklane_text_uses_slightly_larger_horizontal_inset() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            sidebarView.firstWorklanePrimaryMinX,
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarWorklaneTextHorizontalInset,
            accuracy: 0.5
        )
    }

    func test_sidebar_keeps_primary_text_alignment_for_home_and_project_rows() throws {
        let homeSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        homeSidebar.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-home"),
                    badgeText: "H",
                    primaryText: "~",
                    isActive: true
                ),
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-project"),
                    badgeText: "P",
                    primaryText: "feature/sidebar",
                    detailLines: [
                        WorklaneSidebarDetailLine(text: "fix-pane-border • sidebar", emphasis: .primary),
                    ],
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        homeSidebar.layoutSubtreeIfNeeded()

        let projectSidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        projectSidebar.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-project-a"),
                    badgeText: "A",
                    primaryText: "feature/sidebar",
                    isActive: true
                ),
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-project-b"),
                    badgeText: "B",
                    primaryText: "marketing-site",
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        projectSidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            homeSidebar.firstWorklanePrimaryMinX,
            homeSidebar.secondWorklanePrimaryMinX,
            accuracy: 0.5
        )
        XCTAssertEqual(
            projectSidebar.firstWorklanePrimaryMinX,
            homeSidebar.firstWorklanePrimaryMinX,
            accuracy: 0.5
        )
        XCTAssertEqual(
            projectSidebar.firstWorklanePrimaryMinX,
            projectSidebar.secondWorklanePrimaryMinX,
            accuracy: 0.5
        )
    }

    func test_sidebar_renders_all_detail_lines_in_order_for_multi_pane_rows() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "M",
                    topLabel: "Docs",
                    primaryText: "feature/sidebar",
                    statusText: nil,
                    detailLines: [
                        WorklaneSidebarDetailLine(text: "main • git", emphasis: .primary),
                        WorklaneSidebarDetailLine(text: "notes • copy", emphasis: .secondary),
                        WorklaneSidebarDetailLine(text: "tests • specs", emphasis: .secondary),
                    ],
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(
            sidebarView.worklaneDetailTexts.first,
            [
                "main • git",
                "notes • copy",
                "tests • specs",
            ]
        )
        XCTAssertEqual(sidebarView.worklaneOverflowTexts, [""])
    }

    func test_sidebar_keeps_last_detail_line_inside_button_bounds_for_tall_rows() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        let lastDetailText = "peter@m1-pro-peter:~/Rails/nimbu"

        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "M",
                    primaryText: "peter@m1-pro-peter:~/Development/Personal/worktrees/feature/sidebar",
                    detailLines: [
                        WorklaneSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .primary),
                        WorklaneSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorklaneSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorklaneSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorklaneSidebarDetailLine(text: "peter@m1-pro-peter:~", emphasis: .secondary),
                        WorklaneSidebarDetailLine(text: lastDetailText, emphasis: .secondary),
                    ],
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.first)
        let lastDetailLabel = try XCTUnwrap(
            button.descendantLabel(withText: lastDetailText)
        )
        let lastDetailFrame = button.convert(lastDetailLabel.bounds, from: lastDetailLabel)

        XCTAssertGreaterThanOrEqual(lastDetailFrame.minY, -0.5)
        XCTAssertLessThanOrEqual(lastDetailFrame.maxY, button.bounds.maxY + 0.5)
    }

    func test_sidebar_home_row_keeps_detail_lines_empty() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-home"),
                    badgeText: "H",
                    primaryText: "~",
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(sidebarView.worklaneDetailTexts.first, [])
    }

    func test_sidebar_header_button_respects_pinned_safe_inset_and_keeps_label_visible() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.updateHeaderLayout(visibilityMode: .pinnedOpen, pinnedContentMinX: 76)
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(sidebarView.addWorklaneContentMinX, 76)
        XCTAssertGreaterThan(sidebarView.addWorklaneButtonWidth, 120)
        let buttonMaxX = sidebarView.addWorklaneButtonMinX + sidebarView.addWorklaneButtonWidth
        let expectedTrailing = sidebarView.bounds.width - ShellMetrics.sidebarContentInset
        let expectedMaxWidth = expectedTrailing - sidebarView.addWorklaneButtonMinX
        XCTAssertEqual(sidebarView.addWorklaneWidthConstraintConstant, expectedMaxWidth, accuracy: 1.0)
        XCTAssertLessThanOrEqual(buttonMaxX, expectedTrailing + 1.0)
        XCTAssertLessThan(sidebarView.addWorklaneIconAlpha, sidebarView.addWorklaneTitleAlpha)
    }

    func test_sidebar_header_button_uses_full_width_in_hover_peek() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.updateHeaderLayout(visibilityMode: .pinnedOpen, pinnedContentMinX: 76)
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.updateHeaderLayout(visibilityMode: .hoverPeek, pinnedContentMinX: 76)
        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebarView.addWorklaneButtonMinX, ShellMetrics.sidebarContentInset, accuracy: 0.001)
        XCTAssertEqual(
            sidebarView.addWorklaneContentMinX,
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarCreateWorklaneHorizontalInset,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(sidebarView.addWorklaneButtonWidth, 120)
        XCTAssertLessThanOrEqual(
            sidebarView.addWorklaneButtonWidth,
            sidebarView.bounds.width - (ShellMetrics.sidebarContentInset * 2) + 1.0
        )
    }

    func test_sidebar_header_button_hover_adds_subtle_pill_state_and_pointer_affordance() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.updateHeaderLayout(visibilityMode: .pinnedOpen, pinnedContentMinX: 76)
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        let restingTitleAlpha = sidebarView.addWorklaneTitleAlpha
        let restingIconAlpha = sidebarView.addWorklaneIconAlpha

        sidebarView.setAddWorklaneHoveredForTesting(true)

        XCTAssertTrue(sidebarView.addWorklaneUsesPointingHandCursor)
        XCTAssertGreaterThan(sidebarView.addWorklaneBackgroundAlpha, 0.01)
        XCTAssertEqual(sidebarView.addWorklaneBorderAlpha, 0, accuracy: 0.001)
        XCTAssertGreaterThan(sidebarView.addWorklaneTitleAlpha, restingTitleAlpha)
        XCTAssertGreaterThan(sidebarView.addWorklaneIconAlpha, restingIconAlpha)
    }

    func test_sidebar_resize_hit_area_is_centered_on_outer_edge_without_visible_indicator() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebarView.resizeHandleWidthForTesting, 4, accuracy: 0.001)
        XCTAssertEqual(
            sidebarView.resizeHandleMinX,
            sidebarView.bounds.maxX - sidebarView.resizeHandleWidthForTesting,
            accuracy: 0.001
        )
        XCTAssertEqual(sidebarView.resizeHandleMaxX, sidebarView.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(sidebarView.resizeHandleFillAlpha, 0, accuracy: 0.001)
        XCTAssertFalse(sidebarView.isResizeHandleHidden)
        XCTAssertTrue(sidebarView.trailingEdgeHitTargetsResizeHandle)
        XCTAssertFalse(sidebarView.hitTargetsResizeHandle(atX: sidebarView.bounds.maxX - 5))
    }

    func test_sidebar_hides_resize_handle_when_resize_is_disabled() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        sidebarView.setResizeEnabled(false)

        XCTAssertTrue(sidebarView.isResizeHandleHidden)
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

    func test_open_with_popover_glass_uses_menu_material_and_theme_palette() {
        let glassView = GlassSurfaceView(style: .openWithPopover)
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

        XCTAssertEqual(glassView.material, .menu)
        XCTAssertEqual(
            glassView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken,
            theme.openWithPopoverBackground.themeToken
        )
        XCTAssertEqual(
            glassView.layer?.borderColor.flatMap(NSColor.init(cgColor:))?.themeToken,
            theme.openWithPopoverBorder.themeToken
        )
    }

    func test_notification_panel_embeds_shared_glass_surface() {
        let panel = NotificationPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))

        panel.update(notifications: [
            AppNotification(
                id: UUID(),
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                state: .needsInput,
                tool: .claudeCode,
                interactionKind: .question,
                interactionSymbolName: "list.bullet",
                statusText: "Needs decision",
                primaryText: "Review the plan",
                createdAt: Date(timeIntervalSince1970: 42)
            )
        ], theme: ZenttyTheme.fallback(for: nil))

        XCTAssertTrue(panel.containsDescendant(ofType: GlassSurfaceView.self))
    }

    func test_notification_panel_glass_does_not_reuse_open_with_surface_recipe() throws {
        let panel = NotificationPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
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

        panel.update(notifications: [
            AppNotification(
                id: UUID(),
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                state: .needsInput,
                tool: .claudeCode,
                interactionKind: .question,
                interactionSymbolName: "list.bullet",
                statusText: "Needs decision",
                primaryText: "Review the plan",
                createdAt: Date(timeIntervalSince1970: 42)
            )
        ], theme: theme)

        let glassView = try XCTUnwrap(panel.firstDescendant(ofType: GlassSurfaceView.self))
        let backgroundToken = glassView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken

        XCTAssertNotEqual(glassView.material, .menu)
        XCTAssertNotEqual(backgroundToken, theme.openWithPopoverBackground.themeToken)
    }

    func test_notification_panel_clips_content_to_rounded_glass_shape() throws {
        let panel = NotificationPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))

        panel.update(notifications: [
            AppNotification(
                id: UUID(),
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                state: .needsInput,
                tool: .claudeCode,
                interactionKind: .question,
                interactionSymbolName: "list.bullet",
                statusText: "Needs decision",
                primaryText: "Review the plan",
                createdAt: Date(timeIntervalSince1970: 42)
            )
        ], theme: ZenttyTheme.fallback(for: nil))

        let clipView = try XCTUnwrap(panel.firstDescendant { view in
            guard let layer = view.layer else {
                return false
            }

            return layer.masksToBounds && layer.cornerRadius == GlassSurfaceStyle.notificationPanel.cornerRadius
        })
        let clipLayer = try XCTUnwrap(clipView.layer)

        XCTAssertTrue(clipLayer.masksToBounds)
        XCTAssertEqual(clipLayer.cornerRadius, GlassSurfaceStyle.notificationPanel.cornerRadius)
    }

    func test_notification_panel_selected_row_does_not_reuse_open_with_selected_fill() throws {
        let panel = NotificationPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
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

        panel.update(notifications: [
            AppNotification(
                id: UUID(),
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                state: .needsInput,
                tool: .claudeCode,
                interactionKind: .question,
                interactionSymbolName: "list.bullet",
                statusText: "Needs decision",
                primaryText: "Review the plan",
                createdAt: Date(timeIntervalSince1970: 42)
            )
        ], theme: theme)

        let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: downArrow,
                charactersIgnoringModifiers: downArrow,
                isARepeat: false,
                keyCode: 125
            )
        )
        panel.keyDown(with: event)

        let row = try XCTUnwrap(panel.firstDescendant(named: "NotificationItemView"))
        let backgroundToken = row.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken

        XCTAssertNotEqual(backgroundToken, theme.openWithPopoverRowSelectedBackground.themeToken)
    }

    func test_notification_panel_renders_location_metadata_for_needs_input_rows() throws {
        let panel = NotificationPanelView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))

        panel.update(notifications: [
            AppNotification(
                id: UUID(),
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                state: .needsInput,
                tool: .codex,
                interactionKind: .decision,
                interactionSymbolName: "list.bullet",
                statusText: "requires a decision",
                primaryText: "Use the new two-line row?",
                locationText: "zentty • Zentty/UI/Chrome",
                createdAt: Date(timeIntervalSince1970: 42)
            )
        ], theme: ZenttyTheme.fallback(for: nil))

        XCTAssertNotNil(panel.descendantLabel(withText: "Codex"))
        XCTAssertNotNil(panel.descendantLabel(withText: "requires a decision"))
        XCTAssertNotNil(panel.descendantLabel(withText: "zentty • Zentty/UI/Chrome"))
        XCTAssertNotNil(panel.descendantLabel(withText: "Use the new two-line row?"))
    }

    func test_sidebar_content_tree_forces_dark_appearance_for_dark_themes() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        sidebarView.appearance = NSAppearance(named: .aqua)
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

        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "1",
                    topLabel: "peter@m1-pro-peter:~",
                    primaryText: "~",
                    isWorking: false,
                    isActive: false
                )
            ],
            theme: theme
        )

        XCTAssertEqual(sidebarView.appearanceMatchForTesting, .darkAqua)
        let firstRow = try! XCTUnwrap(sidebarView.worklaneButtonsForTesting.first as? SidebarWorklaneRowButton)
        XCTAssertEqual(firstRow.appearanceMatchForTesting, .darkAqua)
    }

    func test_sidebar_compacts_true_single_line_rows_only() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-compact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                ),
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-expanded"),
                    title: "Claude Code",
                    badgeText: "C",
                    primaryText: "Claude Code",
                    statusText: "Needs input",
                    contextText: "",
                    attentionState: .needsInput,
                    isActive: false,
                    showsGeneratedTitle: true
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let buttons = sidebarView.worklaneButtonsForTesting
        let compactFrame = try XCTUnwrap(buttons.first?.frame)
        let expandedFrame = try XCTUnwrap(buttons.last?.frame)

        XCTAssertEqual(compactFrame.height, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.5)
        XCTAssertEqual(
            expandedFrame.height,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: true,
                includesStatus: true,
                detailLineCount: 0,
                includesOverflow: false
            ),
            accuracy: 0.5
        )
        XCTAssertLessThan(compactFrame.height, expandedFrame.height)
    }

    func test_sidebar_keeps_context_rows_expanded() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-context"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "main • ~/src/zentty",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.first?.frame)
        XCTAssertEqual(
            frame.height,
            ShellMetrics.sidebarRowHeight(
                includesTopLabel: false,
                includesStatus: false,
                detailLineCount: 1,
                includesOverflow: false
            ),
            accuracy: 0.5
        )
    }

    func test_sidebar_keeps_primary_only_rows_compact() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-artifact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "Claude Code",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(sidebarView.worklaneButtonsForTesting.first?.frame)
        XCTAssertEqual(frame.height, ShellMetrics.sidebarCompactRowHeight, accuracy: 0.5)
    }

    func test_sidebar_mixes_compact_and_expanded_rows_without_colliding_with_footer() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-compact"),
                    title: "MAIN",
                    badgeText: "M",
                    primaryText: "shell",
                    contextText: "",
                    isActive: true,
                    showsGeneratedTitle: false
                ),
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-expanded"),
                    title: "Claude Code",
                    badgeText: "C",
                    primaryText: "Claude Code",
                    statusText: "Needs input",
                    contextText: "main • ~/src/zentty",
                    attentionState: .needsInput,
                    isActive: false,
                    showsGeneratedTitle: true
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let buttons = sidebarView.worklaneButtonsForTesting
        let firstButton = try XCTUnwrap(buttons.first)
        let secondButton = try XCTUnwrap(buttons.last)
        let firstFrame = sidebarView.convert(firstButton.bounds, from: firstButton)
        let secondFrame = sidebarView.convert(secondButton.bounds, from: secondButton)
        let headerButtonFrame = CGRect(
            x: sidebarView.addWorklaneButtonMinX,
            y: sidebarView.addWorklaneMinY,
            width: sidebarView.addWorklaneButtonWidth,
            height: sidebarView.addWorklaneMaxY - sidebarView.addWorklaneMinY
        )

        XCTAssertFalse(firstFrame.intersects(secondFrame))
        XCTAssertFalse(firstFrame.union(secondFrame).intersects(headerButtonFrame))
    }

    func test_window_chrome_shows_attention_chip_only_for_attention_states() {
        let windowChromeView = WindowChromeView()
        let attention = WorklaneAttentionSummary(
            paneID: PaneID("shell"),
            tool: .claudeCode,
            state: .needsInput,
            primaryText: "Claude Code",
            statusText: "Needs input",
            contextText: "project • main",
            artifactLink: WorklaneArtifactLink(
                kind: .pullRequest,
                label: "PR #42",
                url: URL(string: "https://example.com/pr/42")!,
                isExplicit: true
            ),
            updatedAt: Date(timeIntervalSince1970: 42)
        )

        windowChromeView.render(summary: WorklaneChromeSummary(
            attention: attention,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertFalse(windowChromeView.isAttentionHidden)
        XCTAssertEqual(windowChromeView.attentionText, "Needs input")
        XCTAssertEqual(windowChromeView.attentionArtifactText, "PR #42")

        windowChromeView.render(summary: WorklaneChromeSummary(
            attention: WorklaneAttentionSummary(
                paneID: PaneID("shell"),
                tool: .claudeCode,
                state: .running,
                primaryText: "Claude Code",
                statusText: "Running",
                contextText: "project • main",
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 43)
            ),
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertTrue(windowChromeView.isAttentionHidden)
    }

    func test_root_controller_restores_hidden_sidebar_and_reclaims_leading_inset() throws {
        let sidebarDefaults = SidebarWidthPreference.userDefaults()
        let visibilityDefaults = SidebarVisibilityPreference.userDefaults()
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
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrame, to: controller.view)
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(controller.sidebarVisibilityMode, .hidden)
        XCTAssertEqual(appCanvasView.leadingVisibleInset, 0, accuracy: 0.001)
        XCTAssertEqual(paneView.frame.width, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(borderFrameInRoot.minX, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertFalse(controller.isSidebarFloating)
    }

    func test_root_controller_hover_peek_keeps_overlay_sidebar_out_of_layout() throws {
        let visibilityDefaults = SidebarVisibilityPreference.userDefaults()
        SidebarVisibilityPreference.persist(.hidden, in: visibilityDefaults)
        let controller = makeController(
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: visibilityDefaults
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handleSidebarVisibilityEvent(.hoverRailEntered)
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneView = try XCTUnwrap(appCanvasView.descendantPaneViews().first as PaneContainerView?)
        let borderFrameInRoot = paneView.convert(paneView.insetBorderFrame, to: controller.view)
        let rightGap = controller.view.bounds.maxX - borderFrameInRoot.maxX

        XCTAssertEqual(controller.sidebarVisibilityMode, .hoverPeek)
        XCTAssertEqual(appCanvasView.leadingVisibleInset, 0, accuracy: 0.001)
        XCTAssertEqual(borderFrameInRoot.minX, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertEqual(rightGap, borderFrameInRoot.minY, accuracy: 0.001)
        XCTAssertTrue(controller.isSidebarFloating)
        XCTAssertFalse(appCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_root_controller_hover_peek_keeps_sidebar_toggle_at_closed_anchor() throws {
        let visibilityDefaults = SidebarVisibilityPreference.userDefaults()
        SidebarVisibilityPreference.persist(.hidden, in: visibilityDefaults)
        let controller = makeController(
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: visibilityDefaults
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let hiddenToggleMinX = controller.sidebarToggleMinX

        controller.handleSidebarVisibilityEvent(.hoverRailEntered)
        controller.settleSidebarTransitionForTesting()

        XCTAssertEqual(controller.sidebarVisibilityMode, .hoverPeek)
        XCTAssertEqual(controller.sidebarToggleMinX, hiddenToggleMinX, accuracy: 0.001)
    }

    func test_root_controller_places_sidebar_header_button_after_traffic_lights_when_pinned() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        let expectedContentMinX =
            ChromeGeometry.trafficLightLeadingInset
            + 48
            - ShellMetrics.outerInset
            + SidebarToggleButton.spacingFromTrafficLights
            + ShellMetrics.sidebarCreateWorklanePinnedLeadingPad

        XCTAssertEqual(sidebarView.addWorklaneContentMinX, expectedContentMinX, accuracy: 1.0)
        XCTAssertGreaterThan(sidebarView.addWorklaneButtonWidth, 120)
        XCTAssertLessThan(sidebarView.addWorklaneButtonWidth, 220)
    }

    func test_root_controller_hover_peek_allows_sidebar_header_button_to_use_full_width() throws {
        let visibilityDefaults = SidebarVisibilityPreference.userDefaults()
        SidebarVisibilityPreference.persist(.hidden, in: visibilityDefaults)
        let controller = makeController(
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: visibilityDefaults
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handleSidebarVisibilityEvent(.hoverRailEntered)
        controller.settleSidebarTransitionForTesting()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)

        XCTAssertEqual(sidebarView.addWorklaneButtonMinX, ShellMetrics.sidebarContentInset, accuracy: 1.0)
        XCTAssertEqual(
            sidebarView.addWorklaneContentMinX,
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarCreateWorklaneHorizontalInset,
            accuracy: 1.0
        )
    }

    func test_root_controller_keeps_sidebar_header_button_on_stable_chrome_row_when_traffic_light_anchor_updates() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        let anchor = NSPoint(
            x: ChromeGeometry.trafficLightLeadingInset + 48,
            y: controller.view.bounds.maxY - ChromeGeometry.trafficLightTopInset - 7
        )
        controller.updateTrafficLightAnchor(anchor)
        controller.view.layoutSubtreeIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)

        let headerTop = sidebarView.bounds.height - ShellMetrics.sidebarHeaderHeight
        XCTAssertGreaterThan(sidebarView.addWorklaneButtonMidY, headerTop, "button should be within header region")
        XCTAssertLessThanOrEqual(sidebarView.addWorklaneButtonMidY, sidebarView.bounds.height, "button should not exceed sidebar bounds")
    }

    func test_toggle_sidebar_then_horizontal_keyboard_resize_preserves_single_split_spacing() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.toggleSidebar)
        controller.settleSidebarTransitionForTesting()

        controller.handle(.toggleSidebar)
        controller.settleSidebarTransitionForTesting()

        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        var paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let readableWidth = PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset
        )

        XCTAssertEqual(paneViews.count, 2)
        XCTAssertEqual(
            paneViews[1].frame.minX - paneViews[0].frame.maxX,
            PaneLayoutSizing.edgeAligned.interPaneSpacing,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(paneViews[0].frame.width, readableWidth + 0.001)

        controller.handle(.pane(.resizeLeft))
        controller.view.layoutSubtreeIfNeeded()

        paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.count, 2)
        XCTAssertEqual(
            paneViews[1].frame.minX - paneViews[0].frame.maxX,
            PaneLayoutSizing.edgeAligned.interPaneSpacing,
            accuracy: 0.001
        )
        let expectedLaneMinX = appCanvasView.leadingVisibleInset
            + paneViews[0].insetBorderInset
        XCTAssertGreaterThanOrEqual(
            paneViews[0].visibleInsetBorderFrameForTesting.minX,
            expectedLaneMinX - 0.001
        )
    }

    func test_immediate_horizontal_keyboard_resize_after_sidebar_reopen_preserves_single_split_spacing() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.toggleSidebar)
        controller.settleSidebarTransitionForTesting()

        controller.handle(.toggleSidebar)
        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.resizeLeft))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(paneViews.count, 2)
        XCTAssertEqual(
            paneViews[1].frame.minX - paneViews[0].frame.maxX,
            PaneLayoutSizing.edgeAligned.interPaneSpacing,
            accuracy: 0.001
        )
        let expectedLaneMinX = appCanvasView.leadingVisibleInset
            + paneViews[0].insetBorderInset
        XCTAssertGreaterThanOrEqual(
            paneViews[0].visibleInsetBorderFrameForTesting.minX,
            expectedLaneMinX - 0.001
        )
    }

    func test_focus_shift_to_second_pane_keeps_strip_flush_with_visible_lane() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(paneViews.count, 2)
        let expectedLeadingEdge = appCanvasView.leadingVisibleInset
            + paneViews[0].insetBorderInset
        let expectedTrailingEdge = appCanvasView.bounds.width
            - paneViews[1].insetBorderInset
        XCTAssertLessThanOrEqual(
            paneViews[0].visibleInsetBorderFrameForTesting.minX,
            expectedLeadingEdge + 0.001
        )
        XCTAssertEqual(
            paneViews[1].visibleInsetBorderFrameForTesting.maxX,
            expectedTrailingEdge,
            accuracy: 0.001
        )
    }

    func test_focus_shift_after_max_sidebar_width_keeps_strip_flush_with_visible_lane() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()

        controller.setSidebarWidth(10_000)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        var paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.count, 2)

        let expectedTrailingEdge = appCanvasView.bounds.width
            - paneViews[1].insetBorderInset
        XCTAssertEqual(
            paneViews[1].visibleInsetBorderFrameForTesting.maxX,
            expectedTrailingEdge,
            accuracy: 0.001
        )

        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()

        paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.count, 2)
        XCTAssertEqual(
            paneViews[1].visibleInsetBorderFrameForTesting.maxX,
            expectedTrailingEdge,
            accuracy: 0.001
        )
    }

    func test_focus_shift_pans_only_enough_to_fully_reveal_newly_focused_pane() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let beforeFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
        let beforeVisibleFrames = beforeFrames.map(\.visibleInsetBorderFrameForTesting)
        let expectedTrailingEdge = appCanvasView.bounds.width
            - beforeFrames[1].insetBorderInset
        let expectedShift = max(0, beforeVisibleFrames[1].maxX - expectedTrailingEdge)

        XCTAssertGreaterThan(expectedShift, 0.001)

        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()

        let afterFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
        let afterVisibleFrames = afterFrames.map(\.visibleInsetBorderFrameForTesting)

        XCTAssertEqual(beforeFrames.count, 2)
        XCTAssertEqual(afterFrames.count, 2)
        XCTAssertEqual(afterVisibleFrames[0].minX, beforeVisibleFrames[0].minX - expectedShift, accuracy: 0.001)
        XCTAssertEqual(afterVisibleFrames[0].maxX, beforeVisibleFrames[0].maxX - expectedShift, accuracy: 0.001)
        XCTAssertEqual(afterVisibleFrames[1].minX, beforeVisibleFrames[1].minX - expectedShift, accuracy: 0.001)
        XCTAssertEqual(afterVisibleFrames[1].maxX, beforeVisibleFrames[1].maxX - expectedShift, accuracy: 0.001)
        XCTAssertEqual(afterVisibleFrames[1].maxX, expectedTrailingEdge, accuracy: 0.001)
    }

    func test_focus_shift_does_not_scroll_fully_visible_two_pane_strip_after_both_panes_hit_minimum_width() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.focusLastColumn))
        for _ in 0..<80 {
            controller.handle(.pane(.resizeRight))
        }
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.focusFirstColumn))
        for _ in 0..<80 {
            controller.handle(.pane(.resizeLeft))
        }
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let beforeFocusShiftFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.visibleInsetBorderFrameForTesting)

        controller.handle(.pane(.resizeLeft))
        controller.view.layoutSubtreeIfNeeded()
        let afterExtraLeftResizeFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.visibleInsetBorderFrameForTesting)

        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.resizeRight))
        controller.view.layoutSubtreeIfNeeded()

        let afterFocusLastFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.visibleInsetBorderFrameForTesting)

        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()

        let afterFocusFirstFrames = appCanvasView.descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.visibleInsetBorderFrameForTesting)

        XCTAssertEqual(beforeFocusShiftFrames.count, 2)
        XCTAssertEqual(afterExtraLeftResizeFrames.count, 2)
        XCTAssertEqual(afterFocusLastFrames.count, 2)
        XCTAssertEqual(afterFocusFirstFrames.count, 2)

        for index in beforeFocusShiftFrames.indices {
            XCTAssertEqual(afterExtraLeftResizeFrames[index].minX, beforeFocusShiftFrames[index].minX, accuracy: 0.001)
            XCTAssertEqual(afterExtraLeftResizeFrames[index].maxX, beforeFocusShiftFrames[index].maxX, accuracy: 0.001)
            XCTAssertEqual(afterFocusLastFrames[index].minX, beforeFocusShiftFrames[index].minX, accuracy: 0.001)
            XCTAssertEqual(afterFocusLastFrames[index].maxX, beforeFocusShiftFrames[index].maxX, accuracy: 0.001)
            XCTAssertEqual(afterFocusFirstFrames[index].minX, beforeFocusShiftFrames[index].minX, accuracy: 0.001)
            XCTAssertEqual(afterFocusFirstFrames[index].maxX, beforeFocusShiftFrames[index].maxX, accuracy: 0.001)
        }
    }

    func test_navigate_back_to_first_pane_clears_sidebar_with_three_panes() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusFirstColumn))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView })
        let paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let sidebarInset = controller.currentSidebarWidth + ShellMetrics.canvasSidebarGap

        XCTAssertEqual(paneViews.count, 3)
        let expectedLaneMinX = sidebarInset
            + paneViews[0].insetBorderInset
        XCTAssertGreaterThanOrEqual(
            paneViews[0].visibleInsetBorderFrameForTesting.minX,
            expectedLaneMinX - 0.001
        )
    }

    func test_middle_pane_horizontal_keyboard_resize_recenters_it_in_visible_lane() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.splitAfterFocusedPane))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusLastColumn))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusLeft))
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.resizeLeft))
        controller.view.layoutSubtreeIfNeeded()

        let appCanvasView = try XCTUnwrap(controller.view.subviews.first { $0 is AppCanvasView } as? AppCanvasView)
        let paneViews = appCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews.count, 3)

        let middleVisibleFrame = paneViews[1].visibleInsetBorderFrameForTesting
        let visibleLaneMidX = (
            controller.currentSidebarWidth
            + ShellMetrics.canvasSidebarGap
            + paneViews[1].insetBorderInset
            + (appCanvasView.bounds.width - paneViews[1].insetBorderInset)
        ) / 2

        XCTAssertEqual(middleVisibleFrame.midX, visibleLaneMidX, accuracy: 0.001)
    }

    func test_vertical_keyboard_resize_up_shrinks_top_pane_when_top_pane_is_focused() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitVertically))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusUp))
        controller.view.layoutSubtreeIfNeeded()

        let beforeHeights = try resolvedFocusedColumnHeights(controller)

        controller.handle(.pane(.resizeUp))
        controller.view.layoutSubtreeIfNeeded()

        let afterHeights = try resolvedFocusedColumnHeights(controller)

        XCTAssertLessThan(afterHeights[0], beforeHeights[0])
        XCTAssertGreaterThan(afterHeights[1], beforeHeights[1])
    }

    func test_vertical_keyboard_resize_down_grows_top_pane_when_top_pane_is_focused() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitVertically))
        controller.view.layoutSubtreeIfNeeded()
        controller.handle(.pane(.focusUp))
        controller.view.layoutSubtreeIfNeeded()

        let beforeHeights = try resolvedFocusedColumnHeights(controller)

        controller.handle(.pane(.resizeDown))
        controller.view.layoutSubtreeIfNeeded()

        let afterHeights = try resolvedFocusedColumnHeights(controller)

        XCTAssertGreaterThan(afterHeights[0], beforeHeights[0])
        XCTAssertLessThan(afterHeights[1], beforeHeights[1])
    }

    func test_vertical_keyboard_resize_up_keeps_bottom_focused_behavior_intact() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()

        controller.handle(.pane(.splitVertically))
        controller.view.layoutSubtreeIfNeeded()

        let beforeHeights = try resolvedFocusedColumnHeights(controller)

        controller.handle(.pane(.resizeUp))
        controller.view.layoutSubtreeIfNeeded()

        let afterHeights = try resolvedFocusedColumnHeights(controller)

        XCTAssertLessThan(afterHeights[0], beforeHeights[0])
        XCTAssertGreaterThan(afterHeights[1], beforeHeights[1])
    }

    private func resolvedFocusedColumnHeights(_ controller: RootViewController) throws -> [CGFloat] {
        let paneStripState = controller.paneStripStateForTesting
        let focusedColumn = try XCTUnwrap(paneStripState.focusedColumn)
        return focusedColumn.resolvedPaneHeights(
            totalHeight: paneStripState.layoutSizing.paneHeight(for: controller.view.bounds.height),
            spacing: paneStripState.layoutSizing.interPaneSpacing
        )
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

private extension RootViewCompositionTests {
    func makeControllerWithCrowdedHeader(width: CGFloat) -> RootViewController {
        let controller = RootViewController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: SidebarVisibilityPreference.userDefaults()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 840)

        let paneID = PaneID("pane-claude")
        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "claude")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "Claude Code",
                        currentWorkingDirectory: "/tmp/project",
                        processName: "claude",
                        gitBranch: "feature/review-band"
                    ),
                ],
                agentStatusByPaneID: [
                    paneID: PaneAgentStatus(
                        tool: .claudeCode,
                        state: .needsInput,
                        text: nil,
                        artifactLink: nil,
                        updatedAt: Date(timeIntervalSince1970: 10),
                        source: .explicit
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorklaneReviewState(
                        branch: "feature/review-band",
                        pullRequest: WorklanePullRequestSummary(
                            number: 128,
                            url: URL(string: "https://example.com/pr/128"),
                            state: .draft
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "Draft", style: .info),
                            WorklaneReviewChip(text: "2 failing", style: .danger),
                        ]
                    ),
                ]
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    func frameInRoot(_ localFrame: NSRect, within chromeView: NSView) -> NSRect {
        localFrame.offsetBy(dx: chromeView.frame.minX, dy: chromeView.frame.minY)
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

    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }

    func containsDescendant(named className: String) -> Bool {
        subviews.contains { subview in
            String(describing: type(of: subview)) == className || subview.containsDescendant(named: className)
        }
    }

    func firstDescendant(named className: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == className {
                return subview
            }
            if let match = subview.firstDescendant(named: className) {
                return match
            }
        }
        return nil
    }

    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        for subview in subviews {
            if predicate(subview) {
                return subview
            }
            if let match = subview.firstDescendant(where: predicate) {
                return match
            }
        }
        return nil
    }
}

private extension PaneContainerView {
    var visibleInsetBorderFrameForTesting: CGRect {
        insetBorderFrame.offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

@MainActor

private func alphaComponent(of cgColor: CGColor?) -> CGFloat {
    guard let cgColor, let color = NSColor(cgColor: cgColor) else {
        return 0
    }

    return color.srgbClamped.alphaComponent
}
