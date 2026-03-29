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

    // MARK: - Debounce behaviour

    func test_recordFocusChange_commits_after_debounce() async throws {
        let controller = makeController()
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)
        try await Task.sleep(for: .seconds(0.1))

        XCTAssertTrue(controller.history.canGoBack, "history should have an entry after debounce fires")
        XCTAssertEqual(controller.history.backStack.count, 1)
        XCTAssertEqual(controller.history.backStack.first, a)
    }

    func test_recordFocusChange_does_not_commit_before_debounce() {
        let controller = makeController()
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        XCTAssertFalse(controller.history.canGoBack, "history should be empty before debounce fires")
    }

    // MARK: - Navigation cancels pending entries

    func test_navigateBack_cancels_pending_entry() async throws {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Record a focus change but navigate back before debounce fires.
        controller.recordFocusChange(from: a)
        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)

        // Wait longer than debounce interval to confirm it was discarded.
        try await Task.sleep(for: .seconds(0.1))

        XCTAssertFalse(controller.history.canGoBack, "pending entry should have been cancelled by navigateBack")
    }

    func test_navigateForward_cancels_pending_entry() async throws {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Record a focus change but navigate forward before debounce fires.
        controller.recordFocusChange(from: a)
        _ = controller.navigateForward(current: b, allPaneIDs: allPanes)

        // Wait longer than debounce interval to confirm it was discarded.
        try await Task.sleep(for: .seconds(0.1))

        XCTAssertFalse(controller.history.canGoBack, "pending entry should have been cancelled by navigateForward")
    }

    // MARK: - Rapid focus changes

    func test_rapid_focus_changes_only_commit_last() async throws {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")

        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)
        controller.recordFocusChange(from: c)

        try await Task.sleep(for: .seconds(0.1))

        XCTAssertEqual(controller.history.backStack.count, 1, "only the last rapid change should commit")
        XCTAssertEqual(controller.history.backStack.first, c, "the committed entry should be the last 'from' ref")
    }

    // MARK: - Navigation is immediate

    func test_navigateBack_is_immediate() async throws {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b, c]

        // Build up history: a -> b -> c
        controller.recordFocusChange(from: a)
        try await Task.sleep(for: .seconds(0.1))
        controller.recordFocusChange(from: b)
        try await Task.sleep(for: .seconds(0.1))

        // Navigate back should return immediately with no debounce.
        let target = controller.navigateBack(current: c, allPaneIDs: allPanes)

        XCTAssertEqual(target, b, "navigateBack should return the previous pane immediately")
        XCTAssertTrue(controller.history.canGoForward, "forward stack should contain an entry after going back")
    }

    // MARK: - onChange callback

    func test_onChange_fires_on_commit() async {
        let controller = makeController()
        let a = ref("w1", "a")

        let changeFired = XCTestExpectation(description: "onChange fired on commit")
        controller.onChange = { changeFired.fulfill() }

        controller.recordFocusChange(from: a)

        await fulfillment(of: [changeFired], timeout: 5)
        XCTAssertEqual(controller.history.backStack.count, 1)
    }

    func test_onChange_fires_on_navigateBack() async throws {
        let controller = makeController()
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Build history first.
        controller.recordFocusChange(from: a)
        try await Task.sleep(for: .seconds(0.1))

        // Now set up the expectation for navigateBack.
        let changeFired = XCTestExpectation(description: "onChange fired on navigateBack")
        controller.onChange = { changeFired.fulfill() }

        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)

        await fulfillment(of: [changeFired], timeout: 5)
    }
}
