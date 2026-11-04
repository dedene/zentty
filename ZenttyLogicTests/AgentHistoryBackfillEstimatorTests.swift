import XCTest
@testable import Zentty

final class AgentHistoryBackfillEstimatorTests: XCTestCase {
    func test_no_estimate_until_enough_work_was_seen() {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 5, at: 30)
        XCTAssertNil(estimator.secondsRemaining(sessionsLeft: 100, at: 30), "too few sessions")

        var quick = AgentHistoryBackfillEstimator()
        quick.record(indexed: 0, at: 0)
        quick.record(indexed: 50, at: 2)
        XCTAssertNil(quick.secondsRemaining(sessionsLeft: 100, at: 2), "too little time")
    }

    func test_estimate_follows_the_pace() throws {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 100, at: 20)

        XCTAssertEqual(try XCTUnwrap(estimator.secondsRemaining(sessionsLeft: 500, at: 20)), 100, accuracy: 0.001)
    }

    func test_old_pace_falls_out_of_the_window() throws {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 1_000, at: 10)
        // Then the big sessions start: 1 session a second from here on.
        for second in stride(from: 20, through: 200, by: 10) {
            estimator.record(indexed: 1_000 + (second - 10), at: TimeInterval(second))
        }

        XCTAssertEqual(try XCTUnwrap(estimator.secondsRemaining(sessionsLeft: 60, at: 200)), 60, accuracy: 1)
    }

    func test_a_stall_slows_the_estimate_down() throws {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 100, at: 20)

        XCTAssertEqual(try XCTUnwrap(estimator.secondsRemaining(sessionsLeft: 100, at: 40)), 40, accuracy: 0.001)
    }

    func test_reset_forgets_the_pace() {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 100, at: 20)

        estimator.reset()

        XCTAssertNil(estimator.secondsRemaining(sessionsLeft: 100, at: 3_600), "paused time doesn't count")
    }

    func test_removed_sessions_restart_the_measure() {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 100, at: 0)
        estimator.record(indexed: 200, at: 20)
        estimator.record(indexed: 50, at: 21)

        XCTAssertNil(estimator.secondsRemaining(sessionsLeft: 100, at: 40))
    }

    func test_nothing_left_has_no_estimate() {
        var estimator = AgentHistoryBackfillEstimator()
        estimator.record(indexed: 0, at: 0)
        estimator.record(indexed: 100, at: 20)

        XCTAssertNil(estimator.secondsRemaining(sessionsLeft: 0, at: 20))
    }

    func test_samples_stay_bounded_when_sessions_finish_quickly() throws {
        var estimator = AgentHistoryBackfillEstimator()
        for tick in 0...20_000 {
            estimator.record(indexed: tick, at: Double(tick) / 100)
        }

        XCTAssertEqual(try XCTUnwrap(estimator.secondsRemaining(sessionsLeft: 100, at: 200)), 1, accuracy: 0.05)
    }

    func test_remaining_text() {
        func text(_ seconds: TimeInterval?) -> String? {
            AgentHistoryBackfillProgress(
                indexedSessions: 1, totalSessions: 2, estimatedSecondsRemaining: seconds
            ).remainingText
        }

        XCTAssertNil(text(nil))
        XCTAssertEqual(text(20), "less than a minute left")
        XCTAssertEqual(text(100), "about 2 min left")
        XCTAssertEqual(text(9.4 * 60), "about 9 min left")
        XCTAssertEqual(text(12 * 60), "about 10 min left")
        XCTAssertEqual(text(38 * 60), "about 40 min left")
        XCTAssertEqual(text(59.6 * 60), "about 1 hour left")
        XCTAssertEqual(text(100 * 60), "about 2 hours left")
    }
}
