import XCTest
@testable import Zentty

final class PaneFocusHistoryTests: XCTestCase {

    private func ref(_ worklane: String, _ pane: String) -> WorklaneStore.PaneReference {
        WorklaneStore.PaneReference(worklaneID: WorklaneID(worklane), paneID: PaneID(pane))
    }

    // MARK: - Basic navigation

    func test_record_and_navigateBack_returns_previous_pane() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")

        history.record(refA)

        let alive: Set<WorklaneStore.PaneReference> = [refA, refB]
        let result = history.navigateBack(current: refB, allPaneIDs: alive)

        XCTAssertEqual(result, refA)
    }

    func test_navigateForward_after_back_returns_original() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")

        history.record(refA)

        let alive: Set<WorklaneStore.PaneReference> = [refA, refB]

        // Go back from B -> A
        let backResult = history.navigateBack(current: refB, allPaneIDs: alive)
        XCTAssertEqual(backResult, refA)

        // Go forward from A -> B
        let forwardResult = history.navigateForward(current: refA, allPaneIDs: alive)
        XCTAssertEqual(forwardResult, refB)
    }

    func test_record_after_back_clears_forward_stack() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")
        let refC = ref("w1", "c")

        history.record(refA)

        let alive: Set<WorklaneStore.PaneReference> = [refA, refB, refC]

        // Go back from B -> A
        _ = history.navigateBack(current: refB, allPaneIDs: alive)

        // Record C (should clear forward stack)
        history.record(refC)

        XCTAssertFalse(history.canGoForward)
    }

    // MARK: - Skipping closed panes

    func test_navigateBack_skips_closed_panes() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")
        let refC = ref("w1", "c")

        history.record(refA)
        history.record(refB)

        // B is closed (not in alive set)
        let alive: Set<WorklaneStore.PaneReference> = [refA, refC]
        let result = history.navigateBack(current: refC, allPaneIDs: alive)

        XCTAssertEqual(result, refA)
    }

    func test_navigateForward_skips_closed_panes() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")
        let refC = ref("w1", "c")

        history.record(refA)
        history.record(refB)

        let allAlive: Set<WorklaneStore.PaneReference> = [refA, refB, refC]

        // Go back twice from C -> B -> A
        _ = history.navigateBack(current: refC, allPaneIDs: allAlive)
        _ = history.navigateBack(current: refB, allPaneIDs: allAlive)

        // Now close B (the middle pane)
        let aliveWithoutB: Set<WorklaneStore.PaneReference> = [refA, refC]
        let result = history.navigateForward(current: refA, allPaneIDs: aliveWithoutB)

        // Should skip B and land on C
        XCTAssertEqual(result, refC)
    }

    // MARK: - Max depth

    func test_maxDepth_trims_oldest_entries() {
        var history = PaneFocusHistory(maxDepth: 3)

        let refs = (0..<5).map { ref("w1", "pane-\($0)") }
        for r in refs {
            history.record(r)
        }

        // Back stack should contain only the last 3 recorded entries
        XCTAssertEqual(history.backStack.count, 3)
        XCTAssertEqual(history.backStack, [refs[2], refs[3], refs[4]])
    }

    // MARK: - Empty stacks

    func test_empty_backStack_returns_nil() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let alive: Set<WorklaneStore.PaneReference> = [refA]

        let result = history.navigateBack(current: refA, allPaneIDs: alive)
        XCTAssertNil(result)
    }

    func test_empty_forwardStack_returns_nil() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let alive: Set<WorklaneStore.PaneReference> = [refA]

        let result = history.navigateForward(current: refA, allPaneIDs: alive)
        XCTAssertNil(result)
    }

    // MARK: - All closed

    func test_allClosedPanes_returns_nil() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")
        let refC = ref("w1", "c")

        history.record(refA)
        history.record(refB)

        // All recorded panes are closed
        let alive: Set<WorklaneStore.PaneReference> = [refC]
        let result = history.navigateBack(current: refC, allPaneIDs: alive)

        XCTAssertNil(result)
        XCTAssertTrue(history.backStack.isEmpty)
    }

    // MARK: - Boolean helpers

    func test_canGoBack_and_canGoForward() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")

        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.record(refA)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        let alive: Set<WorklaneStore.PaneReference> = [refA, refB]
        _ = history.navigateBack(current: refB, allPaneIDs: alive)

        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
    }

    // MARK: - Deduplication behavior

    func test_no_deduplication() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")

        history.record(refA)
        history.record(refB)
        history.record(refA)
        history.record(refB)

        XCTAssertEqual(history.backStack, [refA, refB, refA, refB])
    }

    // MARK: - Forward stack bookkeeping

    func test_navigateBack_pushes_current_to_forwardStack() {
        var history = PaneFocusHistory()

        let refA = ref("w1", "a")
        let refB = ref("w1", "b")

        history.record(refA)

        let alive: Set<WorklaneStore.PaneReference> = [refA, refB]
        _ = history.navigateBack(current: refB, allPaneIDs: alive)

        XCTAssertEqual(history.forwardStack, [refB])
    }
}
