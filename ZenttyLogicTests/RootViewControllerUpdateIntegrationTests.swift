import AppKit
import XCTest
@testable import Zentty

@MainActor
final class RootViewControllerUpdateIntegrationTests: XCTestCase {
    private func makeController(
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore()
    ) -> RootViewController {
        RootViewController(
            configStore: AppConfigStore(
                fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.RootViewController.UpdateRow")
            ),
            appUpdateStateStore: appUpdateStateStore,
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
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
}
