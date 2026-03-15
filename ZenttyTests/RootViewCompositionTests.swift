import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: XCTestCase {
    func test_root_controller_places_sidebar_outside_inner_canvas() {
        let controller = RootViewController()
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        let rootSubviews = controller.view.subviews
        let sidebarView = rootSubviews.first { $0 is SidebarView } as? SidebarView
        let appCanvasView = rootSubviews.first { $0 is AppCanvasView }

        XCTAssertNotNil(sidebarView)
        XCTAssertNotNil(appCanvasView)
        XCTAssertFalse(appCanvasView?.containsDescendant(ofType: SidebarView.self) ?? true)
        XCTAssertEqual(sidebarView?.workspaceTitlesForTesting, ["MAIN"])
        XCTAssertEqual(sidebarView?.activeWorkspaceTitleForTesting, "MAIN")
    }

    func test_context_strip_prefers_terminal_metadata_and_compacts_home_directory() {
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

        XCTAssertEqual(contextStripView.workspaceTextForTesting, "WEB")
        XCTAssertEqual(contextStripView.focusedTextForTesting, "zsh")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "cwd ~/src/zentty")
        XCTAssertEqual(contextStripView.branchTextForTesting, "branch main")
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
        XCTAssertTrue(contextStripView.isBranchHiddenForTesting)

        contextStripView.render(
            workspaceName: "OPS",
            state: state,
            metadata: TerminalMetadata()
        )

        XCTAssertEqual(contextStripView.focusedTextForTesting, "pane 2")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "")
        XCTAssertTrue(contextStripView.isBranchHiddenForTesting)
    }

    func test_sidebar_view_emits_selected_workspace_id() throws {
        let sidebarView = SidebarView()
        let workspaces = [
            WorkspaceState(
                id: WorkspaceID("workspace-api"),
                title: "API",
                paneStripState: .pocDefault
            ),
            WorkspaceState(
                id: WorkspaceID("workspace-web"),
                title: "WEB",
                paneStripState: .pocDefault
            ),
        ]
        var selectedWorkspaceID: WorkspaceID?

        sidebarView.onSelectWorkspace = { selectedWorkspaceID = $0 }
        sidebarView.render(
            workspaces: workspaces,
            activeWorkspaceID: WorkspaceID("workspace-api"),
            theme: ZenttyTheme.fallback(for: nil)
        )

        let webButton = try XCTUnwrap(sidebarView.workspaceButtonsForTesting.last)
        webButton.performClick(nil)

        XCTAssertEqual(selectedWorkspaceID, WorkspaceID("workspace-web"))
    }
}

private extension NSView {
    func containsDescendant<T: NSView>(ofType type: T.Type) -> Bool {
        subviews.contains { subview in
            subview is T || subview.containsDescendant(ofType: type)
        }
    }
}
