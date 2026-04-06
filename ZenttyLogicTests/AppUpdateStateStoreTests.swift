import XCTest
@testable import Zentty

@MainActor
final class AppUpdateStateStoreTests: XCTestCase {
    func test_store_notifies_observers_when_update_availability_changes() {
        let store = AppUpdateStateStore()
        var observedStates: [AppUpdateState] = []

        let observerID = store.addObserver { observedStates.append($0) }
        store.setUpdateAvailable(true)
        store.setUpdateAvailable(false)
        store.removeObserver(observerID)

        XCTAssertEqual(
            observedStates,
            [
                AppUpdateState(isUpdateAvailable: true),
                AppUpdateState(isUpdateAvailable: false),
            ]
        )
    }

    func test_store_does_not_notify_observers_when_update_availability_is_unchanged() {
        let store = AppUpdateStateStore()
        var notificationCount = 0

        let observerID = store.addObserver { _ in
            notificationCount += 1
        }
        store.setUpdateAvailable(false)
        store.setUpdateAvailable(true)
        store.setUpdateAvailable(true)
        store.removeObserver(observerID)

        XCTAssertEqual(notificationCount, 1)
    }
}
