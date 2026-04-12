import XCTest
@testable import Zentty

@MainActor
final class PaneFocusHistoryControllerTests: XCTestCase {

    @MainActor
    private final class ManualDebounceHandle: PaneFocusHistoryDebounceHandle {
        private(set) var isCancelled = false
        private let operation: @MainActor () -> Void

        init(operation: @escaping @MainActor () -> Void) {
            self.operation = operation
        }

        func cancel() {
            isCancelled = true
        }

        func run() {
            guard !isCancelled else { return }
            isCancelled = true
            operation()
        }
    }

    @MainActor
    private final class ManualDebounceScheduler {
        private var handles: [ManualDebounceHandle] = []

        func schedule(
            interval _: TimeInterval,
            operation: @escaping @MainActor () -> Void
        ) -> any PaneFocusHistoryDebounceHandle {
            let handle = ManualDebounceHandle(operation: operation)
            handles.append(handle)
            return handle
        }

        func runLatest(file: StaticString = #filePath, line: UInt = #line) {
            guard let handle = handles.popLast() else {
                XCTFail("Expected a pending debounce callback", file: file, line: line)
                return
            }
            handle.run()
        }
    }

    // MARK: - Helpers

    private func ref(_ worklane: String, _ pane: String) -> WorklaneStore.PaneReference {
        WorklaneStore.PaneReference(worklaneID: WorklaneID(worklane), paneID: PaneID(pane))
    }

    private func makeController(
        debounceInterval: TimeInterval = 0.05,
        scheduler: ManualDebounceScheduler? = nil
    ) -> PaneFocusHistoryController {
        if let scheduler {
            return PaneFocusHistoryController(
                debounceInterval: debounceInterval,
                scheduleDebounce: { interval, operation in
                    scheduler.schedule(interval: interval, operation: operation)
                }
            )
        }

        return PaneFocusHistoryController(debounceInterval: debounceInterval)
    }

    // MARK: - Debounce behaviour

    func test_recordFocusChange_commits_after_debounce() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        scheduler.runLatest()

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

    func test_recordFocusChange_withZeroDebounce_commitsImmediately() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        XCTAssertTrue(controller.history.canGoBack, "zero debounce should commit immediately")
        XCTAssertEqual(controller.history.backStack, [a])
    }

    // MARK: - Navigation cancels pending entries

    func test_navigateBack_cancels_pending_entry() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Record a focus change but navigate back before debounce fires.
        controller.recordFocusChange(from: a)
        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)

        scheduler.runLatest()

        XCTAssertFalse(controller.history.canGoBack, "pending entry should have been cancelled by navigateBack")
    }

    func test_navigateForward_cancels_pending_entry() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Record a focus change but navigate forward before debounce fires.
        controller.recordFocusChange(from: a)
        _ = controller.navigateForward(current: b, allPaneIDs: allPanes)

        scheduler.runLatest()

        XCTAssertFalse(controller.history.canGoBack, "pending entry should have been cancelled by navigateForward")
    }

    // MARK: - Rapid focus changes

    func test_rapid_focus_changes_only_commit_last() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")

        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)
        controller.recordFocusChange(from: c)

        scheduler.runLatest()

        XCTAssertEqual(controller.history.backStack.count, 1, "only the last rapid change should commit")
        XCTAssertEqual(controller.history.backStack.first, c, "the committed entry should be the last 'from' ref")
    }

    // MARK: - Navigation is immediate

    func test_navigateBack_is_immediate() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b, c]

        // Build up history: a -> b -> c
        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)

        // Navigate back should return immediately with no debounce.
        let target = controller.navigateBack(current: c, allPaneIDs: allPanes)

        XCTAssertEqual(target, b, "navigateBack should return the previous pane immediately")
        XCTAssertTrue(controller.history.canGoForward, "forward stack should contain an entry after going back")
    }

    // MARK: - onChange callback

    func test_onChange_fires_on_commit() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")

        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        controller.recordFocusChange(from: a)

        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(controller.history.backStack.count, 1)
    }

    func test_onChange_fires_on_navigateBack() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        // Build history first.
        controller.recordFocusChange(from: a)

        // Now set up the expectation for navigateBack.
        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)

        XCTAssertEqual(changeCount, 1)
    }
}
