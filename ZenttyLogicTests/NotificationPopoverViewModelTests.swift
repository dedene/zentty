import XCTest
@testable import Zentty

@MainActor
final class NotificationPopoverViewModelTests: XCTestCase {
    func test_hosting_controller_preserves_native_popover_safe_area_regions() {
        let viewModel = NotificationPopoverViewModel(notifications: [])
        let controller = NotificationPopoverHostingController(viewModel: viewModel)

        XCTAssertNotEqual(controller.safeAreaRegions, [])
    }

    func test_metrics_match_bookmarks_popover_rhythm() {
        XCTAssertEqual(NotificationPopoverMetrics.contentWidth, BookmarksPopoverMetrics.contentWidth)
        XCTAssertEqual(NotificationPopoverMetrics.preferredHeight(forEmpty: true), 220)
        XCTAssertEqual(NotificationPopoverMetrics.preferredHeight(forEmpty: false), 320)
        XCTAssertEqual(NotificationPopoverMetrics.populatedMaxHeight, 460)
    }

    func test_live_popover_height_does_not_shrink_when_cleared_while_open() {
        let populatedHeight = NotificationPopoverMetrics.preferredHeight(forEmpty: false)

        XCTAssertEqual(
            NotificationPopoverMetrics.liveHeight(
                forEmpty: true,
                currentHeight: populatedHeight
            ),
            populatedHeight
        )
    }

    func test_notification_view_fitting_height_matches_preferred_empty_panel_height() {
        let viewModel = NotificationPopoverViewModel(notifications: [])
        let controller = NotificationPopoverHostingController(viewModel: viewModel)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            controller.view.fittingSize.height,
            NotificationPopoverMetrics.preferredHeight(forEmpty: true),
            accuracy: 1
        )
    }

    func test_update_preserves_selected_notification_when_still_present() {
        let first = makeNotification(id: UUID(), primaryText: "First")
        let second = makeNotification(id: UUID(), primaryText: "Second")
        let viewModel = NotificationPopoverViewModel(notifications: [first, second])

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedNotificationID, first.id)

        viewModel.update(notifications: [second, first])

        XCTAssertEqual(viewModel.selectedNotificationID, first.id)
    }

    func test_update_clears_selected_notification_when_removed() {
        let first = makeNotification(id: UUID(), primaryText: "First")
        let second = makeNotification(id: UUID(), primaryText: "Second")
        let viewModel = NotificationPopoverViewModel(notifications: [first, second])

        viewModel.moveSelection(delta: 1)
        viewModel.update(notifications: [second])

        XCTAssertNil(viewModel.selectedNotificationID)
    }

    func test_keyboard_actions_route_to_selected_notification() {
        let first = makeNotification(id: UUID(), primaryText: "First")
        let second = makeNotification(id: UUID(), primaryText: "Second")
        var activatedIDs: [UUID] = []
        var dismissedIDs: [UUID] = []
        let viewModel = NotificationPopoverViewModel(
            notifications: [first, second],
            onActivate: { activatedIDs.append($0.id) },
            onDismiss: { dismissedIDs.append($0) }
        )

        viewModel.moveSelection(delta: 1)
        viewModel.activateSelected()
        viewModel.dismissSelected()

        XCTAssertEqual(activatedIDs, [first.id])
        XCTAssertEqual(dismissedIDs, [first.id])
    }

    func test_jump_latest_clear_all_and_close_route_to_callbacks() {
        var didJumpLatest = false
        var didClearAll = false
        var didClose = false
        let viewModel = NotificationPopoverViewModel(
            notifications: [makeNotification()],
            onJumpToLatest: { didJumpLatest = true },
            onClearAll: { didClearAll = true },
            onClose: { didClose = true }
        )

        viewModel.jumpToLatest()
        viewModel.clearAll()
        viewModel.close()

        XCTAssertTrue(didJumpLatest)
        XCTAssertTrue(didClearAll)
        XCTAssertTrue(didClose)
    }

    private func makeNotification(
        id: UUID = UUID(),
        primaryText: String = "Review the plan",
        createdAt: Date = Date(timeIntervalSince1970: 42)
    ) -> AppNotification {
        AppNotification(
            id: id,
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main"),
            state: .needsInput,
            tool: .codex,
            interactionKind: .question,
            interactionSymbolName: "list.bullet",
            statusText: "Needs decision",
            primaryText: primaryText,
            locationText: "zentty",
            createdAt: createdAt
        )
    }
}
