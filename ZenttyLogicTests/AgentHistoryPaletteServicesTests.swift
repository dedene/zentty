import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryPaletteServicesTests: XCTestCase {
    func test_cancellable_block_runs_once() {
        var count = 0
        let block = AgentHistoryCancellableBlock { count += 1 }
        block.cancel()
        block.cancel()
        XCTAssertEqual(count, 1)
    }

    func test_main_queue_scheduler_runs_work_and_skips_cancelled_work() {
        let scheduler = AgentHistoryMainQueueScheduler()
        let ran = expectation(description: "scheduled work ran")
        var cancelledRan = false
        let cancelled = scheduler.schedule(after: 0.01) { cancelledRan = true }
        cancelled.cancel()
        _ = scheduler.schedule(after: 0.02) { ran.fulfill() }
        wait(for: [ran], timeout: 2)
        XCTAssertFalse(cancelledRan)
    }

    func test_manual_scheduler_fires_due_work_in_order_on_advance() {
        let scheduler = ManualAgentHistoryScheduler()
        var fired: [String] = []
        _ = scheduler.schedule(after: 0.12) { fired.append("content") }
        _ = scheduler.schedule(after: 0.06) { fired.append("preview") }
        let dropped = scheduler.schedule(after: 0.05) { fired.append("dropped") }
        dropped.cancel()

        scheduler.advance(by: 0.1)
        XCTAssertEqual(fired, ["preview"])
        scheduler.advance(by: 0.02)
        XCTAssertEqual(fired, ["preview", "content"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func test_open_context_compares_entry_point_and_scope() {
        let worklane = WorklaneID("worklane-1")
        let context = AgentHistoryOpenContext(
            entryPoint: .worklaneContextMenu(worklane),
            currentProject: nil,
            initialScope: .all,
            hostWindowID: WindowID("window-1")
        )
        var other = context
        XCTAssertEqual(context, other)
        other.entryPoint = .toolbar
        XCTAssertNotEqual(context, other)
    }
}
