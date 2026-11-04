import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryMetadataSnapshotTests: XCTestCase {
    private func summary(
        id: Int64, updatedAtMs: Int64, turnCount: Int = 1, title: String = "t"
    ) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/root", agent: .claude, nativeID: "native-\(id)",
            title: title, titleKind: .firstPrompt,
            createdAtMs: 1, updatedAtMs: updatedAtMs, turnCount: turnCount
        )
    }

    func test_build_sorts_by_updated_desc_and_bumps_generation() {
        var builder = AgentHistoryMetadataSnapshotBuilder()
        builder.replaceAll([
            summary(id: 1, updatedAtMs: 100),
            summary(id: 2, updatedAtMs: 300),
            summary(id: 3, updatedAtMs: 200),
            summary(id: 4, updatedAtMs: 300),
        ])

        let first = builder.build(isComplete: false)
        XCTAssertEqual(first.sessions.map(\.id), [4, 2, 3, 1])
        XCTAssertFalse(first.isComplete)
        XCTAssertGreaterThan(first.generation, AgentHistoryMetadataSnapshot.empty.generation)

        let second = builder.build(isComplete: true)
        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.sessions.map(\.id), first.sessions.map(\.id))
    }

    func test_upsert_and_remove() {
        var builder = AgentHistoryMetadataSnapshotBuilder()
        builder.replaceAll([summary(id: 1, updatedAtMs: 100), summary(id: 2, updatedAtMs: 200)])

        builder.upsert([summary(id: 1, updatedAtMs: 500, title: "renamed"), summary(id: 3, updatedAtMs: 50)])
        var snapshot = builder.build(isComplete: true)
        XCTAssertEqual(snapshot.sessions.map(\.id), [1, 2, 3])
        XCTAssertEqual(snapshot.sessions.first?.title, "renamed")

        builder.remove(rowIDs: [2, 99])
        snapshot = builder.build(isComplete: true)
        XCTAssertEqual(snapshot.sessions.map(\.id), [1, 3])

        // A summary that lost its turns is no longer visible.
        builder.upsert([summary(id: 3, updatedAtMs: 50, turnCount: 0)])
        snapshot = builder.build(isComplete: true)
        XCTAssertEqual(snapshot.sessions.map(\.id), [1])
        XCTAssertFalse(builder.contains(rowID: 3))

        builder.replaceAll([summary(id: 7, updatedAtMs: 1)])
        snapshot = builder.build(isComplete: true)
        XCTAssertEqual(snapshot.sessions.map(\.id), [7])
        XCTAssertEqual(builder.count, 1)
    }

    func test_empty_snapshot_has_no_sessions() {
        XCTAssertTrue(AgentHistoryMetadataSnapshot.empty.sessions.isEmpty)
        XCTAssertFalse(AgentHistoryMetadataSnapshot.empty.isComplete)
        XCTAssertEqual(AgentHistoryStatus.off.state, .off)
        XCTAssertNil(AgentHistoryStatus.off.tokenizer)
        XCTAssertEqual(AgentHistoryStatus.off.revision, 0)
    }
}

final class AgentHistoryReconcileScheduleTests: XCTestCase {
    func test_defaults_match_the_plan() {
        let schedule = AgentHistoryReconcileSchedule()
        XCTAssertEqual(schedule.launchDelay, 5)
        XCTAssertEqual(schedule.interval, 15 * 60)
        XCTAssertEqual(schedule.wakeDelay, 10)
        XCTAssertEqual(schedule.dbPollMinInterval, 2)
        XCTAssertEqual(schedule.diskFullRetry, 60)
        XCTAssertEqual(schedule.publishInterval, 1)
        XCTAssertEqual(schedule.missingGrace, 30)
    }

    func test_periodic_reconcile_due_after_15_minutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = AgentHistoryReconcileSchedule()
        XCTAssertTrue(schedule.isPeriodicReconcileDue(now: start), "due before the first reconcile")

        schedule.recordReconcile(at: start)
        XCTAssertFalse(schedule.isPeriodicReconcileDue(now: start))
        XCTAssertFalse(schedule.isPeriodicReconcileDue(now: start.addingTimeInterval(14 * 60 + 59)))
        XCTAssertTrue(schedule.isPeriodicReconcileDue(now: start.addingTimeInterval(15 * 60)))
        XCTAssertTrue(schedule.isPeriodicReconcileDue(now: start.addingTimeInterval(40 * 60)))
    }

    func test_database_poll_throttle_leading_edge_then_2s() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let schedule = AgentHistoryReconcileSchedule()

        // Leading edge: the first event polls right away.
        XCTAssertEqual(schedule.nextDatabasePoll(lastPollAt: nil, now: now), now)
        // Inside the window: one trailing poll 2 s after the last one.
        let recent = now.addingTimeInterval(-0.5)
        XCTAssertEqual(schedule.nextDatabasePoll(lastPollAt: recent, now: now), recent.addingTimeInterval(2))
        // Exactly at and after the window: poll now.
        XCTAssertEqual(schedule.nextDatabasePoll(lastPollAt: now.addingTimeInterval(-2), now: now), now)
        XCTAssertEqual(schedule.nextDatabasePoll(lastPollAt: now.addingTimeInterval(-30), now: now), now)
    }

    func test_missing_grace_is_30_seconds() {
        let seen = Date(timeIntervalSince1970: 3_000_000)
        let schedule = AgentHistoryReconcileSchedule()
        XCTAssertFalse(schedule.isMissingGraceOver(firstSeenMissingAt: seen, now: seen.addingTimeInterval(29)))
        XCTAssertTrue(schedule.isMissingGraceOver(firstSeenMissingAt: seen, now: seen.addingTimeInterval(30)))
    }
}
