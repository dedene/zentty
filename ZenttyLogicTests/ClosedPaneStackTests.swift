import XCTest
@testable import Zentty

final class ClosedPaneStackTests: XCTestCase {
    func test_push_then_pop_returns_most_recent_entry() {
        var stack = ClosedPaneStack()
        let now = Date(timeIntervalSince1970: 10_000)
        let first = makeEntry(idSeed: 1, closedAt: now)
        let second = makeEntry(idSeed: 2, closedAt: now.addingTimeInterval(1))

        stack.push(first, now: now)
        stack.push(second, now: now.addingTimeInterval(1))

        XCTAssertEqual(stack.popLatest(now: now.addingTimeInterval(2))?.id, second.id)
        XCTAssertEqual(stack.popLatest(now: now.addingTimeInterval(2))?.id, first.id)
        XCTAssertNil(stack.popLatest(now: now.addingTimeInterval(2)))
    }

    func test_size_cap_evicts_oldest_entry() {
        var stack = ClosedPaneStack(capacity: 3)
        let now = Date(timeIntervalSince1970: 10_000)
        for index in 0 ..< 4 {
            stack.push(makeEntry(idSeed: index, closedAt: now.addingTimeInterval(TimeInterval(index))), now: now)
        }

        XCTAssertEqual(stack.count, 3)
        let popped = (0 ..< 3).compactMap { _ in stack.popLatest(now: now.addingTimeInterval(10)) }
        XCTAssertEqual(popped.map(\.title), ["title-3", "title-2", "title-1"])
    }

    func test_expired_entries_are_dropped_on_pop() {
        var stack = ClosedPaneStack(capacity: 5, expiry: 60 * 60)
        let base = Date(timeIntervalSince1970: 0)
        let stale = makeEntry(idSeed: 1, closedAt: base)
        let fresh = makeEntry(idSeed: 2, closedAt: base.addingTimeInterval(60 * 30))
        stack.push(stale, now: base)
        stack.push(fresh, now: base.addingTimeInterval(60 * 30))

        let pollTime = base.addingTimeInterval(60 * 70)

        let popped = stack.popLatest(now: pollTime)
        XCTAssertEqual(popped?.id, fresh.id)
        XCTAssertNil(stack.popLatest(now: pollTime))
    }

    func test_prune_drops_only_stale_entries_keeping_fresh_ones() {
        var stack = ClosedPaneStack(capacity: 5, expiry: 100)
        let base = Date(timeIntervalSince1970: 0)
        stack.push(makeEntry(idSeed: 1, closedAt: base), now: base)
        stack.push(makeEntry(idSeed: 2, closedAt: base.addingTimeInterval(50)), now: base.addingTimeInterval(50))

        stack.prune(now: base.addingTimeInterval(110))

        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.peek(now: base.addingTimeInterval(110))?.title, "title-2")
    }

    private func makeEntry(idSeed: Int, closedAt: Date) -> ClosedPaneEntry {
        ClosedPaneEntry(
            id: UUID(),
            closedAt: closedAt,
            originalPaneID: PaneID("pn_\(idSeed)"),
            originalWorklaneID: WorklaneID("wl_\(idSeed)"),
            originalColumnID: PaneColumnID("col_\(idSeed)"),
            originalColumnIndex: 0,
            originalPaneIndex: 0,
            originalColumnWidth: 600,
            originalHeightInColumn: nil,
            title: "title-\(idSeed)",
            workingDirectory: "/tmp/\(idSeed)",
            originalNativeCommand: nil,
            originalCommand: nil,
            agentSnapshot: nil,
            scrollbackText: nil
        )
    }
}
