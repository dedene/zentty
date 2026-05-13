import XCTest
@testable import Zentty

@MainActor
final class PaneNotificationCoordinatorTests: XCTestCase {
    func test_deliver_shows_system_notification_and_adds_inbox_item_by_default() throws {
        let recorder = PaneNotificationRecorder()
        let store = NotificationStore()
        let configStore = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.PaneNotification")
        )
        try configStore.update { config in
            config.notifications.soundName = "Glass"
        }
        let coordinator = PaneNotificationCoordinator(
            center: recorder,
            notificationStore: store,
            configStore: configStore
        )

        coordinator.deliver(
            PaneNotificationRequest(
                title: "Build done",
                subtitle: "Tests passed",
                includeInbox: true,
                isSilent: false,
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            )
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].title, "Build done")
        XCTAssertEqual(recorder.requests[0].subtitle, "Tests passed")
        XCTAssertEqual(recorder.requests[0].windowID, "window-main")
        XCTAssertEqual(recorder.requests[0].worklaneID, "worklane-main")
        XCTAssertEqual(recorder.requests[0].paneID, "pane-main")
        XCTAssertEqual(recorder.requests[0].soundName, "Glass")
        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications[0].tool, .zentty)
        XCTAssertEqual(store.notifications[0].statusText, "Build done")
        XCTAssertEqual(store.notifications[0].primaryText, "Tests passed")
        XCTAssertFalse(store.notifications[0].isResolved)
    }

    func test_deliver_respects_no_inbox_and_silent_options() {
        let recorder = PaneNotificationRecorder()
        let store = NotificationStore()
        let coordinator = PaneNotificationCoordinator(
            center: recorder,
            notificationStore: store,
            configStore: nil
        )

        coordinator.deliver(
            PaneNotificationRequest(
                title: "Deploy done",
                subtitle: nil,
                includeInbox: false,
                isSilent: true,
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            )
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests[0].subtitle)
        XCTAssertNil(recorder.requests[0].soundName)
        XCTAssertTrue(store.notifications.isEmpty)
    }

    func test_deliver_uses_generic_inbox_detail_when_subtitle_is_omitted() {
        let recorder = PaneNotificationRecorder()
        let store = NotificationStore()
        let coordinator = PaneNotificationCoordinator(
            center: recorder,
            notificationStore: store,
            configStore: nil
        )

        coordinator.deliver(
            PaneNotificationRequest(
                title: "Deploy done",
                subtitle: nil,
                includeInbox: true,
                isSilent: false,
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            )
        )

        XCTAssertEqual(store.notifications.first?.primaryText, "Notification from pane.")
    }

    func test_deliver_uses_body_as_inbox_detail_when_present() {
        let recorder = PaneNotificationRecorder()
        let store = NotificationStore()
        let coordinator = PaneNotificationCoordinator(
            center: recorder,
            notificationStore: store,
            configStore: nil
        )
        let body = """
        mise ERROR No version is set for shim: codex
        Set a global default version with mise use -g node@22.22.1
        """

        coordinator.deliver(
            PaneNotificationRequest(
                title: "Codex failed to start",
                subtitle: "mise ERROR No version is set for shim: codex",
                body: body,
                includeInbox: true,
                isSilent: false,
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            )
        )

        XCTAssertEqual(recorder.requests.first?.body, body)
        XCTAssertEqual(store.notifications.first?.statusText, "Codex failed to start")
        XCTAssertEqual(store.notifications.first?.primaryText, body)
    }

    func test_deliver_keeps_multiple_inbox_items_from_same_pane_unresolved() {
        let recorder = PaneNotificationRecorder()
        let store = NotificationStore()
        let coordinator = PaneNotificationCoordinator(
            center: recorder,
            notificationStore: store,
            configStore: nil
        )
        let windowID = WindowID("window-main")
        let worklaneID = WorklaneID("worklane-main")
        let paneID = PaneID("pane-main")

        coordinator.deliver(
            PaneNotificationRequest(
                title: "First task done",
                subtitle: nil,
                includeInbox: true,
                isSilent: false,
                windowID: windowID,
                worklaneID: worklaneID,
                paneID: paneID
            )
        )
        coordinator.deliver(
            PaneNotificationRequest(
                title: "Second task done",
                subtitle: nil,
                includeInbox: true,
                isSilent: false,
                windowID: windowID,
                worklaneID: worklaneID,
                paneID: paneID
            )
        )

        XCTAssertEqual(store.notifications.map(\.statusText), ["Second task done", "First task done"])
        XCTAssertFalse(store.notifications.contains { $0.isResolved })
    }
}

private final class PaneNotificationRecorder: WorklaneAttentionUserNotificationCenter {
    struct RequestRecord: Equatable {
        let identifier: String
        let title: String
        let subtitle: String?
        let body: String
        let windowID: String
        let worklaneID: String
        let paneID: String
        let soundName: String?
    }

    private(set) var requests: [RequestRecord] = []

    func requestAuthorizationIfNeeded() {}

    func add(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String?
    ) {
        requests.append(
            RequestRecord(
                identifier: identifier,
                title: title,
                subtitle: subtitle,
                body: body,
                windowID: windowID,
                worklaneID: worklaneID,
                paneID: paneID,
                soundName: soundName
            )
        )
    }
}
