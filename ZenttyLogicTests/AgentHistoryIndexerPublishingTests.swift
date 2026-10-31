import Foundation
import XCTest
@testable import Zentty

/// Status and snapshot reach main at most once per `publishInterval` during a backfill,
/// immediately on a state change and at 50 sessions, and a throttled change still arrives
/// through the trailing publish.
final class AgentHistoryIndexerPublishingTests: XCTestCase {
    func test_backfill_publishes_are_throttled_and_the_trailing_publish_delivers_the_last_change() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let total = 200
        harness.source.setUnits((0..<total).map { .single("s\($0)", mtimeNs: Int64($0 + 1)) })
        let indexer = harness.makeIndexer()
        XCTAssertEqual(indexer.schedule.publishInterval, 1)
        let complete = harness.recorder.expectSnapshot(self, "complete snapshot") {
            $0.sessions.count == total && $0.isComplete
        }

        indexer.start()
        wait(for: [complete], timeout: 20)

        let snapshots = harness.recorder.snapshots
        let statuses = harness.recorder.statuses
        // Forced: starting, backfilling, the 50-session threshold, watching; plus about one
        // per second of backfill. Unthrottled, every one of the 200 batches would publish.
        XCTAssertLessThan(snapshots.count, 15, "snapshots published: \(snapshots.count)")
        XCTAssertLessThan(statuses.count, 15, "statuses published: \(statuses.count)")
        XCTAssertTrue(snapshots.contains { $0.sessions.count == AgentHistoryIndexer.snapshotPublishThreshold },
                      "the snapshot goes out as soon as 50 sessions are in")
        XCTAssertEqual(snapshots.map(\.generation), snapshots.map(\.generation).sorted())

        // Two changes inside one interval: the second is throttled and must still arrive.
        let rowID = try XCTUnwrap(try harness.sessionRowID("s0"))
        let openedTwice = harness.recorder.expectSnapshot(self, "trailing publish") { snapshot in
            snapshot.sessions.first { $0.id == rowID }?.opens == 2
        }
        indexer.recordOpen(sessionRowID: rowID, atMs: 1_793_000_100_000)
        indexer.recordOpen(sessionRowID: rowID, atMs: 1_793_000_100_001)
        wait(for: [openedTwice], timeout: 5)
    }
}
