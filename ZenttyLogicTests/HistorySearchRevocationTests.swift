import Foundation
import XCTest
@testable import Zentty

/// A revoked reader pool (Agent History turned off, or its index deleted) serves nothing, even to
/// an engine handed out before: every read throws `.indexUnavailable("off")`, a read in flight
/// when it is revoked does not return its rows, and an async result computed before is not
/// delivered after. Reopening serves again. Temp index only.
final class HistorySearchRevocationTests: XCTestCase {
    private typealias Fixture = HistorySearchFixture

    private func makeIndexedFixture() throws -> (Fixture, session: Int64) {
        let fixture = try Fixture(testCase: self)
        let session = try fixture.addSession("revoked", title: "Cache work")
        try fixture.addMessage(session: session, role: .user, atMs: Fixture.ms(daysAgo: 2), text: "why is the cache stale")
        try fixture.addMessage(session: session, role: .agent, atMs: Fixture.ms(daysAgo: 2) + 60_000,
                               text: "the cache key ignores the locale")
        return (fixture, session)
    }

    private func assertOff<T>(_ expression: @autoclosure () throws -> T, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            XCTAssertEqual(error as? HistorySearchError, .indexUnavailable("off"), message, file: file, line: line)
        }
    }

    func test_revoked_pool_refuses_every_engine_read_until_reopened() throws {
        let (fixture, session) = try makeIndexedFixture()
        let engine = try fixture.engine()
        let query = Fixture.query("cache")
        XCTAssertEqual(try engine.searchContent(
            query, context: fixture.context(), excludingSessionIDs: [], cancellation: HistorySearchCancellation()
        ).results.map(\.session.nativeID), ["revoked"])

        fixture.index.storage.readers.revoke()
        XCTAssertTrue(fixture.index.storage.readers.isRevoked)
        XCTAssertEqual(fixture.index.storage.readers.openConnectionCountForTesting, 0, "idle readers closed")

        assertOff(try engine.searchContent(
            query, context: fixture.context(), excludingSessionIDs: [], cancellation: HistorySearchCancellation()),
            "content search")
        assertOff(try engine.preview(sessionID: session, query: query), "preview")
        assertOff(try engine.transcript(sessionID: session, query: query), "transcript")
        assertOff(try engine.lastTurns(sessionID: session, limit: 5), "last turns")
        assertOff(try engine.matchingTurns(sessionID: session, query: query), "matching turns")
        assertOff(try engine.sessions(nativeID: "revoked", agent: nil, scope: .all), "sessions")
        assertOff(try engine.visibleSessionCount(scope: .all), "session count")
        XCTAssertEqual(fixture.index.storage.readers.openConnectionCountForTesting, 0, "no reader reopened")

        fixture.index.storage.readers.reopen()
        XCTAssertFalse(fixture.index.storage.readers.isRevoked)
        XCTAssertEqual(try engine.preview(sessionID: session, query: query).session.nativeID, "revoked")
    }

    func test_read_in_flight_when_revoked_returns_no_rows() throws {
        let (fixture, _) = try makeIndexedFixture()
        let readers = fixture.index.storage.readers
        var tuning = HistorySearchEngine.Tuning()
        // Revoked while the search holds a reader; the statement may well finish regardless.
        tuning.willGradeRow = { readers.revoke() }
        let engine = try fixture.engine(tuning: tuning)

        assertOff(try engine.searchContent(
            Fixture.query("cache"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation()),
            "a search revoked mid-read must not return what it read")
        XCTAssertEqual(readers.openConnectionCountForTesting, 0, "the revoked reader is closed, not pooled")
    }

    func test_async_result_computed_before_revoke_is_not_delivered() throws {
        let (fixture, _) = try makeIndexedFixture()
        let engine = try fixture.engine()

        let done = expectation(description: "completion")
        engine.searchContentAsync(
            Fixture.query("cache"), context: fixture.context(), excludingSessionIDs: [],
            cancellation: HistorySearchCancellation()
        ) { result in
            switch result {
            case .success(let response):
                XCTFail("delivered \(response.results.map(\.session.nativeID)) after the revoke")
            case .failure(let error):
                XCTAssertEqual(error as? HistorySearchError, .indexUnavailable("off"))
            }
            done.fulfill()
        }
        // The search finishes on its queue and its delivery waits on main, behind the revoke.
        HistorySearchEngine.queue.sync {}
        fixture.index.storage.readers.revoke()
        wait(for: [done], timeout: 10)
    }
}
