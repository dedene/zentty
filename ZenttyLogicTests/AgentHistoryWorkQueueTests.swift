import XCTest
@testable import Zentty

final class AgentHistoryWorkQueueTests: XCTestCase {
    private func ref(_ key: String, source: Int64 = 1) -> AgentHistoryUnitRef {
        AgentHistoryUnitRef(sourceID: source, unitKey: key)
    }

    private func drain(_ queue: inout AgentHistoryWorkQueue, allowBackfill: Bool = true) -> [String] {
        var keys: [String] = []
        while let next = queue.popNext(allowBackfill: allowBackfill) {
            keys.append(next.ref.unitKey)
        }
        return keys
    }

    func test_progress_total_stays_put_while_units_finish() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 3), (ref: ref("b"), mtimeNs: 2), (ref: ref("c"), mtimeNs: 1)])

        XCTAssertEqual(queue.backfillScheduled, 3)
        XCTAssertEqual(queue.backfillFinished, 0)

        _ = queue.popNext(allowBackfill: true)
        XCTAssertEqual(queue.backfillScheduled, 3)
        XCTAssertEqual(queue.backfillFinished, 1)

        _ = drain(&queue)
        XCTAssertEqual(queue.backfillScheduled, 3)
        XCTAssertEqual(queue.backfillFinished, 3)
    }

    func test_progress_counts_a_requeued_unit_once() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 1), (ref: ref("b"), mtimeNs: 2)])
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 9)])

        XCTAssertEqual(queue.backfillScheduled, 2, "a newer mtime is the same work")
    }

    func test_progress_counts_a_long_unit_as_unfinished_until_its_last_batch() throws {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("long"), mtimeNs: 2), (ref: ref("next"), mtimeNs: 1)])

        let next = try XCTUnwrap(queue.popNext(allowBackfill: true))
        queue.setContinuation(next.ref, tier: .backfill)

        XCTAssertEqual(queue.backfillScheduled, 2)
        XCTAssertEqual(queue.backfillFinished, 0)
    }

    func test_progress_drops_units_of_a_removed_source_from_the_total() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([
            (ref: ref("kept", source: 1), mtimeNs: 3),
            (ref: ref("gone-1", source: 2), mtimeNs: 2),
            (ref: ref("gone-2", source: 2), mtimeNs: 1),
        ])
        _ = queue.popNext(allowBackfill: true)

        queue.removeAll(sourceID: 2)

        XCTAssertEqual(queue.backfillScheduled, 1)
        XCTAssertEqual(queue.backfillFinished, 1, "turning a source off doesn't look like progress")
    }

    func test_backfill_pops_newest_mtime_first() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([
            (ref: ref("old"), mtimeNs: 100),
            (ref: ref("newest"), mtimeNs: 900),
            (ref: ref("middle"), mtimeNs: 500),
        ])
        queue.enqueueBackfill([(ref: ref("newer"), mtimeNs: 700)])

        XCTAssertEqual(queue.backfillCount, 4)
        XCTAssertEqual(drain(&queue), ["newest", "newer", "middle", "old"])
        XCTAssertTrue(queue.isEmpty)
    }

    func test_backfill_with_equal_mtime_keeps_enqueue_order() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 5), (ref: ref("b"), mtimeNs: 5)])
        queue.enqueueBackfill([(ref: ref("c"), mtimeNs: 5)])

        XCTAssertEqual(drain(&queue), ["a", "b", "c"])
    }

    func test_live_items_preempt_backfill() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("b1"), mtimeNs: 2), (ref: ref("b2"), mtimeNs: 1)])
        queue.enqueueLive(ref("l1"))

        let first = queue.popNext(allowBackfill: true)
        XCTAssertEqual(first?.ref, ref("l1"))
        XCTAssertEqual(first?.tier, .live)

        queue.enqueueLive(ref("l2"))
        queue.enqueueLive(ref("l3"))
        let rest = [queue.popNext(allowBackfill: true), queue.popNext(allowBackfill: true),
                    queue.popNext(allowBackfill: true), queue.popNext(allowBackfill: true)]
        XCTAssertEqual(rest.map { $0?.ref.unitKey }, ["l2", "l3", "b1", "b2"])
        XCTAssertEqual(rest.map { $0?.tier }, [.live, .live, .backfill, .backfill])
        XCTAssertNil(queue.popNext(allowBackfill: true))
    }

    func test_live_enqueue_promotes_queued_backfill_item() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("new"), mtimeNs: 9), (ref: ref("old"), mtimeNs: 1)])
        queue.enqueueLive(ref("old"))

        XCTAssertEqual(queue.liveCount, 1)
        XCTAssertEqual(queue.backfillCount, 1)
        let first = queue.popNext(allowBackfill: true)
        XCTAssertEqual(first?.ref, ref("old"))
        XCTAssertEqual(first?.tier, .live)
        XCTAssertEqual(drain(&queue), ["new"])
    }

    func test_duplicate_enqueue_is_ignored() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueLive(ref("a"))
        queue.enqueueLive(ref("b"))
        queue.enqueueLive(ref("a"))
        XCTAssertEqual(queue.liveCount, 2)

        queue.enqueueBackfill([(ref: ref("x"), mtimeNs: 3), (ref: ref("x"), mtimeNs: 3)])
        queue.enqueueBackfill([(ref: ref("x"), mtimeNs: 3)])
        // Already queued at a higher tier: backfill does not duplicate or demote it.
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 99)])
        XCTAssertEqual(queue.backfillCount, 1)

        // The same unit key under another source is a different unit.
        queue.enqueueLive(ref("a", source: 2))
        XCTAssertEqual(queue.liveCount, 3)

        XCTAssertEqual(drain(&queue), ["a", "b", "a", "x"])
        XCTAssertTrue(queue.isEmpty)
    }

    func test_backfill_reenqueue_updates_mtime() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 1), (ref: ref("b"), mtimeNs: 5)])
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 10)])

        XCTAssertEqual(queue.backfillCount, 2)
        XCTAssertEqual(drain(&queue), ["a", "b"])
    }

    func test_continuation_is_popped_before_other_backfill() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([
            (ref: ref("big"), mtimeNs: 900),
            (ref: ref("next"), mtimeNs: 800),
            (ref: ref("older"), mtimeNs: 100),
        ])
        XCTAssertEqual(queue.popNext(allowBackfill: true)?.ref, ref("big"))
        // A batch-limited unit continues before newer-but-unstarted backfill work.
        queue.enqueueBackfill([(ref: ref("newer"), mtimeNs: 1_000)])
        queue.setContinuation(ref("big"), tier: .backfill)
        XCTAssertEqual(queue.backfillCount, 4)

        let continued = queue.popNext(allowBackfill: true)
        XCTAssertEqual(continued?.ref, ref("big"))
        XCTAssertEqual(continued?.tier, .backfill)
        XCTAssertEqual(drain(&queue), ["newer", "next", "older"])
    }

    func test_pop_order_live_then_live_continuation_then_backfill_continuation_then_backfill() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("backfill"), mtimeNs: 1)])
        queue.setContinuation(ref("backfill-cont"), tier: .backfill)
        queue.setContinuation(ref("live-cont"), tier: .live)
        queue.enqueueLive(ref("live"))

        var popped: [(String, AgentHistoryWorkQueue.Tier)] = []
        while let next = queue.popNext(allowBackfill: true) {
            popped.append((next.ref.unitKey, next.tier))
        }
        XCTAssertEqual(popped.map(\.0), ["live", "live-cont", "backfill-cont", "backfill"])
        XCTAssertEqual(popped.map(\.1), [.live, .live, .backfill, .backfill])
    }

    func test_live_continuation_removes_unit_from_backfill_and_backfill_continuation_never_demotes_live() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("a"), mtimeNs: 1)])
        queue.setContinuation(ref("a"), tier: .live)
        XCTAssertEqual(queue.liveCount, 1)
        XCTAssertEqual(queue.backfillCount, 0)

        queue.enqueueLive(ref("b"))
        queue.setContinuation(ref("b"), tier: .backfill)
        queue.setContinuation(ref("a"), tier: .backfill)
        queue.enqueueLive(ref("a"))
        XCTAssertEqual(queue.liveCount, 2)
        XCTAssertEqual(queue.backfillCount, 0)
        XCTAssertEqual(drain(&queue, allowBackfill: false), ["b", "a"])
        XCTAssertTrue(queue.isEmpty)
    }

    func test_disallowing_backfill_returns_only_live() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueBackfill([(ref: ref("b"), mtimeNs: 1)])
        queue.setContinuation(ref("bc"), tier: .backfill)
        queue.setContinuation(ref("lc"), tier: .live)
        queue.enqueueLive(ref("l"))

        XCTAssertEqual(drain(&queue, allowBackfill: false), ["l", "lc"])
        XCTAssertNil(queue.popNext(allowBackfill: false))
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.liveCount, 0)
        XCTAssertEqual(queue.backfillCount, 2)

        XCTAssertEqual(drain(&queue), ["bc", "b"])
        XCTAssertTrue(queue.isEmpty)
    }

    func test_removeAll_drops_source_items() {
        var queue = AgentHistoryWorkQueue()
        queue.enqueueLive(ref("l1", source: 1))
        queue.enqueueLive(ref("l2", source: 2))
        queue.setContinuation(ref("lc", source: 1), tier: .live)
        queue.setContinuation(ref("bc", source: 1), tier: .backfill)
        queue.enqueueBackfill([
            (ref: ref("b1", source: 1), mtimeNs: 9),
            (ref: ref("b2", source: 2), mtimeNs: 8),
        ])

        queue.removeAll(sourceID: 1)

        XCTAssertEqual(queue.liveCount, 1)
        XCTAssertEqual(queue.backfillCount, 1)
        let remaining = drain(&queue)
        XCTAssertEqual(remaining, ["l2", "b2"])
        XCTAssertTrue(queue.isEmpty)

        // A removed unit can be queued again later.
        queue.enqueueBackfill([(ref: ref("b1", source: 1), mtimeNs: 9)])
        XCTAssertEqual(drain(&queue), ["b1"])
    }
}
