import Foundation
import XCTest
@testable import Zentty

/// Shared driver for the opencode adapter tests: a movable clock and ingest loops that continue
/// from the returned cursor the way the indexer does.
class OpenCodeHistorySourceTestCase: XCTestCase {
    static let t0: Int64 = 1_790_000_000_000
    static let minute: Int64 = 60_000
    static let day: Int64 = 86_400_000

    /// The clock the source sees; tests move it.
    final class Clock: @unchecked Sendable {
        var nowMs: Int64
        init(_ nowMs: Int64) { self.nowMs = nowMs }
    }

    func makeSource(
        _ fixture: OpenCodeHistoryFixture,
        sessionsPerBatch: Int = 20,
        clock: Clock = Clock(OpenCodeHistorySourceTestCase.t0),
        loadSession: OpenCodeHistorySource.SessionLoader? = nil
    ) -> OpenCodeHistorySource {
        guard let loadSession else {
            return OpenCodeHistorySource(root: fixture.root, sessionsPerBatch: sessionsPerBatch, now: { clock.nowMs })
        }
        return OpenCodeHistorySource(root: fixture.root, sessionsPerBatch: sessionsPerBatch, now: { clock.nowMs },
                                     loadSession: loadSession)
    }

    func unit(_ source: OpenCodeHistorySource) throws -> AgentHistoryUnit {
        let units = try source.discoverUnits()
        XCTAssertEqual(units.count, 1)
        return try XCTUnwrap(units.first)
    }

    /// One ingest call, continuing from `cursor` the way the indexer does.
    func ingest(
        _ source: OpenCodeHistorySource,
        cursor: AgentHistoryCursor?,
        context: AgentHistoryIngestContext = AgentHistoryFixtures.context()
    ) throws -> AgentHistoryIngestBatch {
        let unit = try unit(source)
        let mode: AgentHistoryIngestMode
        switch source.classifyChange(unit: unit, cursor: cursor) {
        case let .append(offset, nextSeq):
            mode = .fromOffset(offset, nextSeq: nextSeq)
        default:
            mode = .fromStart
        }
        return try source.ingest(unit: unit, cursor: cursor, mode: mode, context: context)
    }

    /// Ingest calls until `hasMore` is false.
    func drain(
        _ source: OpenCodeHistorySource,
        cursor: AgentHistoryCursor? = nil,
        context: AgentHistoryIngestContext = AgentHistoryFixtures.context(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (batches: [AgentHistoryIngestBatch], cursor: AgentHistoryCursor) {
        var batches: [AgentHistoryIngestBatch] = []
        var cursor = cursor
        repeat {
            let batch = try ingest(source, cursor: cursor, context: context)
            batches.append(batch)
            cursor = batch.cursor
        } while batches.last?.hasMore == true && batches.count < 50
        XCTAssertEqual(batches.last?.hasMore, false, file: file, line: line)
        return (batches, try XCTUnwrap(cursor, file: file, line: line))
    }

    func texts(_ batches: [AgentHistoryIngestBatch], _ nativeID: String) -> [String] {
        batches.flatMap(\.messages).filter { $0.sessionNativeID == nativeID }.sorted { $0.seq < $1.seq }.map(\.text)
    }

    func session(_ batches: [AgentHistoryIngestBatch], _ nativeID: String) -> AgentHistorySessionDraft? {
        batches.flatMap(\.sessions).last { $0.nativeID == nativeID }
    }

    func state(_ cursor: AgentHistoryCursor) -> OpenCodeHistoryAdapterState {
        OpenCodeHistoryAdapterState.decode(cursor.adapterState)
    }
}
