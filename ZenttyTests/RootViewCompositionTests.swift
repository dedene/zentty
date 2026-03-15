import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: XCTestCase {
    override func tearDown() {
        SidebarWidthPreference.resetForTesting()
        super.tearDown()
    }

    func test_root_controller_places_sidebar_outside_inner_canvas() {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        let rootSubviews = controller.view.subviews
        let sidebarView = rootSubviews.first { $0 is SidebarView } as? SidebarView
        let appCanvasView = rootSubviews.first { $0 is AppCanvasView }

        XCTAssertNotNil(sidebarView)
        XCTAssertNotNil(appCanvasView)
        XCTAssertFalse(appCanvasView?.containsDescendant(ofType: SidebarView.self) ?? true)
        XCTAssertEqual(sidebarView?.workspacePrimaryTextsForTesting, ["shell"])
        XCTAssertEqual(sidebarView?.workspaceDetailTextsForTesting, [""])
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
                summaryText: "shell",
                detailText: "1 pane",
                paneCountText: "1 pane",
                attentionState: nil,
                attentionText: nil,
                unreadCount: nil,
                isActive: true,
                showsGeneratedTitle: true,
                showsPaneCount: true
            ),
            WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-web"),
                title: "WEB",
                badgeText: "W",
                summaryText: "editor",
                detailText: "project • main",
                paneCountText: "2 panes",
                attentionState: nil,
                attentionText: nil,
                unreadCount: nil,
                isActive: false,
                showsGeneratedTitle: true,
                showsPaneCount: true
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
        let controller = RootViewController(sidebarWidthDefaults: defaults)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 312, accuracy: 0.001)
    }

    func test_root_controller_uses_new_default_sidebar_width() {
        let controller = RootViewController(sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting())

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.sidebarWidthForTesting, 280, accuracy: 0.001)
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
                    summaryText: "shell",
                    detailText: "project • main",
                    paneCountText: "",
                    attentionState: nil,
                    attentionText: nil,
                    unreadCount: nil,
                    isActive: true,
                    showsGeneratedTitle: false,
                    showsPaneCount: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebarView.addWorkspaceTitleForTesting, "New workspace")
        XCTAssertFalse(sidebarView.hasVisibleDividerForTesting)
        XCTAssertLessThan(sidebarView.firstWorkspaceTopInsetForTesting, 18)
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
                    summaryText: "shell",
                    detailText: "",
                    paneCountText: "",
                    attentionState: nil,
                    attentionText: nil,
                    unreadCount: nil,
                    isActive: true,
                    showsGeneratedTitle: false,
                    showsPaneCount: false
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertTrue(sidebarView.isHeaderHiddenForTesting)
        XCTAssertGreaterThan(sidebarView.firstWorkspaceWidthForTesting, 258)
    }

    func test_sidebar_resize_hit_area_is_centered_on_outer_edge_without_hover_fill() {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        sidebarView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(sidebarView.resizeHandleMinXForTesting, sidebarView.bounds.maxX)
        XCTAssertGreaterThan(sidebarView.resizeHandleMaxXForTesting, sidebarView.bounds.maxX)
        XCTAssertEqual(sidebarView.resizeHandleFillAlphaForTesting, 0, accuracy: 0.001)
    }
}

private extension NSView {
    func containsDescendant<T: NSView>(ofType type: T.Type) -> Bool {
        subviews.contains { subview in
            subview is T || subview.containsDescendant(ofType: type)
        }
    }
}
