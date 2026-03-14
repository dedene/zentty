import XCTest
@testable import Zentty

@MainActor
final class RootViewCompositionTests: XCTestCase {
    func test_root_controller_places_sidebar_outside_inner_canvas() {
        let controller = RootViewController()
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        let rootSubviews = controller.view.subviews
        let sidebarView = rootSubviews.first { $0 is SidebarView }
        let appCanvasView = rootSubviews.first { $0 is AppCanvasView }

        XCTAssertNotNil(sidebarView)
        XCTAssertNotNil(appCanvasView)
        XCTAssertFalse(appCanvasView?.containsDescendant(ofType: SidebarView.self) ?? true)
    }

    func test_context_strip_prefers_terminal_metadata_and_compacts_home_directory() {
        let contextStripView = ContextStripView()
        let state = PaneStripState(
            panes: [PaneState(id: PaneID("shell"), title: "shell")],
            focusedPaneID: PaneID("shell")
        )

        contextStripView.render(
            state,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory() + "/src/zentty",
                processName: "zsh",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(contextStripView.focusedTextForTesting, "zsh")
        XCTAssertEqual(contextStripView.cwdTextForTesting, "cwd ~/src/zentty")
        XCTAssertEqual(contextStripView.branchTextForTesting, "branch main")
        XCTAssertFalse(contextStripView.isBranchHiddenForTesting)
    }
}

private extension NSView {
    func containsDescendant<T: NSView>(ofType type: T.Type) -> Bool {
        subviews.contains { subview in
            subview is T || subview.containsDescendant(ofType: type)
        }
    }
}
