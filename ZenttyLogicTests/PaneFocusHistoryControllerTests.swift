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

    func test_recordFocusChange_commits_after_debounce() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        scheduler.runLatest()

        XCTAssertEqual(controller.history.backStack, [a])
    }

    func test_recordFocusChange_does_not_commit_before_debounce() {
        let controller = makeController()

        controller.recordFocusChange(from: ref("w1", "a"))

        XCTAssertFalse(controller.history.canGoBack)
    }

    func test_recordFocusChange_withZeroDebounce_commitsImmediately() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")

        controller.recordFocusChange(from: a)

        XCTAssertEqual(controller.history.backStack, [a])
    }

    func test_navigateBack_cancels_pending_entry() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        controller.recordFocusChange(from: a)
        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)
        scheduler.runLatest()

        XCTAssertFalse(controller.history.canGoBack)
    }

    func test_navigateForward_cancels_pending_entry() {
        let scheduler = ManualDebounceScheduler()
        let controller = makeController(scheduler: scheduler)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]

        controller.recordFocusChange(from: a)
        _ = controller.navigateForward(current: b, allPaneIDs: allPanes)
        scheduler.runLatest()

        XCTAssertFalse(controller.history.canGoBack)
    }

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

        XCTAssertEqual(controller.history.backStack, [c])
    }

    func test_navigateBack_is_immediate() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")

        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)
        let target = controller.navigateBack(current: c, allPaneIDs: [a, b, c])

        XCTAssertEqual(target, b)
        XCTAssertTrue(controller.history.canGoForward)
    }

    func test_navigateForward_is_immediate() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let c = ref("w1", "c")

        controller.recordFocusChange(from: a)
        controller.recordFocusChange(from: b)
        _ = controller.navigateBack(current: c, allPaneIDs: [a, b, c])
        let target = controller.navigateForward(current: b, allPaneIDs: [a, b, c])

        XCTAssertEqual(target, c)
        XCTAssertFalse(controller.history.canGoForward)
    }

    func test_onChange_fires_on_commit() {
        let controller = makeController(debounceInterval: 0)
        var changeCount = 0

        controller.onChange = { changeCount += 1 }
        controller.recordFocusChange(from: ref("w1", "a"))

        XCTAssertEqual(changeCount, 1)
    }

    func test_onChange_fires_on_navigateBack() {
        let controller = makeController(debounceInterval: 0)
        let a = ref("w1", "a")
        let b = ref("w1", "b")
        let allPanes: Set<WorklaneStore.PaneReference> = [a, b]
        var changeCount = 0

        controller.recordFocusChange(from: a)
        controller.onChange = { changeCount += 1 }
        _ = controller.navigateBack(current: b, allPaneIDs: allPanes)

        XCTAssertEqual(changeCount, 1)
    }
}
