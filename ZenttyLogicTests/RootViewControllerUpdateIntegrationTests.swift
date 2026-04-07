import AppKit
import XCTest
@testable import Zentty

@MainActor
final class RootViewControllerUpdateIntegrationTests: XCTestCase {
    private func makeController(
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
    ) -> RootViewController {
        RootViewController(
            configStore: AppConfigStore(
                fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.RootViewController.UpdateRow")
            ),
            appUpdateStateStore: appUpdateStateStore,
            runtimeRegistry: runtimeRegistry
        )
    }

    func test_root_controller_hides_update_row_when_no_update_is_available() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)

        XCTAssertTrue(sidebarView.isUpdateRowHiddenForTesting)
        XCTAssertEqual(sidebarView.updateAvailableRowHeightForTesting, 0, accuracy: 0.001)
    }

    func test_root_controller_shows_update_row_when_update_becomes_available() throws {
        let appUpdateStateStore = AppUpdateStateStore()
        let controller = makeController(appUpdateStateStore: appUpdateStateStore)
        controller.loadViewIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        appUpdateStateStore.setUpdateAvailable(true)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(sidebarView.isUpdateRowHiddenForTesting)
        XCTAssertEqual(sidebarView.updateAvailableRowHeightForTesting, 28, accuracy: 0.001)
    }

    func test_root_controller_routes_update_row_click_to_update_callback() throws {
        let appUpdateStateStore = AppUpdateStateStore()
        let controller = makeController(appUpdateStateStore: appUpdateStateStore)
        controller.loadViewIfNeeded()

        var callCount = 0
        controller.onCheckForUpdatesRequested = {
            callCount += 1
        }
        appUpdateStateStore.setUpdateAvailable(true)

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        sidebarView.performUpdateAvailableRowClickForTesting()

        XCTAssertEqual(callCount, 1)
    }

    func test_root_controller_ignores_update_row_click_when_no_update_is_available() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()

        var callCount = 0
        controller.onCheckForUpdatesRequested = {
            callCount += 1
        }

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        sidebarView.performUpdateAvailableRowClickForTesting()

        XCTAssertEqual(callCount, 0)
    }

    func test_root_controller_global_search_aggregates_results_across_worklanes() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let worklane1 = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-1"), title: "shell")],
                focusedPaneID: PaneID("pane-1")
            )
        )
        let worklane2 = WorklaneState(
            id: WorklaneID("worklane-2"),
            title: "WS 2",
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-2"), title: "shell")],
                focusedPaneID: PaneID("pane-2")
            )
        )

        controller.replaceWorklanes([worklane1, worklane2], activeWorklaneID: worklane1.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")

        XCTAssertTrue(controller.isGlobalSearchHUDVisibleForTesting)
        XCTAssertEqual(
            controller.globalSearchStateForTesting,
            GlobalSearchState(
                needle: "build",
                selected: -1,
                total: 2,
                hasRememberedSearch: true,
                isHUDVisible: true
            )
        )
    }

    func test_root_controller_find_ends_global_search_and_reopens_local_search_on_focused_pane() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-1")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")
        controller.handle(.find)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertEqual(
            controller.focusedPaneSearchStateForTesting,
            PaneSearchState(
                needle: "",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: true,
                hudCorner: .topTrailing
            )
        )
    }

    func test_root_controller_use_selection_for_find_ends_global_search_and_reopens_local_search_on_focused_pane() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-1")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")
        controller.handle(.useSelectionForFind)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertEqual(
            controller.focusedPaneSearchStateForTesting,
            PaneSearchState(
                needle: "",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: true,
                hudCorner: .topTrailing
            )
        )
    }

    func test_root_controller_invalidates_global_search_when_pane_structure_changes() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let worklaneID = WorklaneID("worklane-1")

        let initialWorklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID1, title: "shell")],
                focusedPaneID: paneID1
            )
        )
        let updatedWorklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID1, title: "shell"),
                    PaneState(id: paneID2, title: "shell 2"),
                ],
                focusedPaneID: paneID1
            )
        )

        controller.replaceWorklanes([initialWorklane], activeWorklaneID: worklaneID)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")

        XCTAssertTrue(controller.isGlobalSearchHUDVisibleForTesting)
        XCTAssertTrue(controller.globalSearchStateForTesting.hasRememberedSearch)

        controller.replaceWorklanes([updatedWorklane], activeWorklaneID: worklaneID)
        let invalidationSettled = expectation(description: "global search invalidation settled")
        DispatchQueue.main.async {
            invalidationSettled.fulfill()
        }
        wait(for: [invalidationSettled], timeout: 1.0)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertFalse(controller.isGlobalSearchHUDVisibleForTesting)
    }

}
