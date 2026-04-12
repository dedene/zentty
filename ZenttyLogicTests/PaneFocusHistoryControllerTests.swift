import XCTest
@testable import Zentty

@MainActor
final class PaneFocusHistoryControllerTests: XCTestCase {

    // MARK: - Helpers

    private func ref(_ worklane: String, _ pane: String) -> WorklaneStore.PaneReference {
        WorklaneStore.PaneReference(worklaneID: WorklaneID(worklane), paneID: PaneID(pane))
    }

    private func makeController() -> PaneFocusHistoryController {
        PaneFocusHistoryController(debounceInterval: 0.05)
    }

    private func seededBackHistory() -> PaneFocusHistory {
        var history = PaneFocusHistory()
        history.record(ref("w1", "a"))
        history.record(ref("w1", "b"))
        return history
    }

    private func seededForwardHistory() -> PaneFocusHistory {
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        var history = PaneFocusHistory()
        history.record(a)
        _ = history.navigateBack(current: b, allPaneIDs: [a, b])
        return history
    }

    // MARK: - Pending entry staging

    func test_recordFocusChange_stages_pending_entry_without_committing_history() {
        let controller = makeController()
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        XCTAssertEqual(controller.pendingEntryForTesting, a)
        XCTAssertFalse(controller.history.canGoBack)
    }

    func test_commitPending_records_staged_entry_and_clears_pending_state() {
        let controller = makeController()
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)
        controller.commitPendingForTesting()

        XCTAssertNil(controller.pendingEntryForTesting)
        XCTAssertEqual(controller.history.backStack, [a])
    }

    func test_recordFocusChange_replaces_prior_pending_entry() {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")

        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)

        XCTAssertEqual(controller.pendingEntryForTesting, b)
        XCTAssertTrue(controller.history.backStack.isEmpty)
    }

    // MARK: - Navigation cancels pending entries

    func test_navigateBack_cancels_pending_entry() {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        controller.recordFocusChange(from: a)

        _ = controller.navigateBack(current: b, allPaneIDs: [a, b])

        XCTAssertNil(controller.pendingEntryForTesting)
        XCTAssertTrue(controller.history.backStack.isEmpty)
    }

    func test_navigateForward_cancels_pending_entry() {
        let controller = makeController()
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)
        _ = controller.navigateForward(current: a, allPaneIDs: [a])

        XCTAssertNil(controller.pendingEntryForTesting)
        XCTAssertTrue(controller.history.backStack.isEmpty)
    }

    // MARK: - Navigation is immediate

    func test_navigateBack_is_immediate_when_history_exists() {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")
        controller.replaceHistoryForTesting(seededBackHistory())

        let target = controller.navigateBack(current: c, allPaneIDs: [a, b, c])

        XCTAssertEqual(target, b)
        XCTAssertEqual(controller.history.backStack, [a])
        XCTAssertEqual(controller.history.forwardStack, [c])
    }

    func test_navigateForward_is_immediate_when_forward_history_exists() {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        controller.replaceHistoryForTesting(seededForwardHistory())

        let target = controller.navigateForward(current: a, allPaneIDs: [a, b])

        XCTAssertEqual(target, b)
        XCTAssertEqual(controller.history.backStack, [a])
        XCTAssertTrue(controller.history.forwardStack.isEmpty)
    }

    // MARK: - onChange callback

    func test_onChange_fires_on_commitPending() {
        let controller = makeController()
        let a = ref("w1", "a")
        let changeFired = expectation(description: "onChange fired on commit")
        controller.onChange = { changeFired.fulfill() }

        controller.recordFocusChange(from: a)
        controller.commitPendingForTesting()

        wait(for: [changeFired], timeout: 0.1)
    }

    func test_onChange_fires_on_navigateBack() {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let changeFired = expectation(description: "onChange fired on navigateBack")
        controller.replaceHistoryForTesting(seededBackHistory())
        controller.onChange = { changeFired.fulfill() }

        _ = controller.navigateBack(current: b, allPaneIDs: [a, b])

        wait(for: [changeFired], timeout: 0.1)
    }
}
