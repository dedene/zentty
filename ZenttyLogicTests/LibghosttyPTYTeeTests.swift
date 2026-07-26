import XCTest

@testable import Zentty

/// Unit tests for the raw-PTY tee staging layer. A real C callback cannot be
/// fired from a unit test, so `LibghosttyPTYTeeAccumulator.append(seq:bytes:)`
/// and `LibghosttyPTYTee.receive(seq:bytes:)` take a `Data` payload through the
/// exact same code path the trampoline uses.
@MainActor
final class LibghosttyPTYTeeTests: XCTestCase {
    // MARK: - Accumulator

    func testAppendAsksForOneDrainPerWindow() {
        let accumulator = LibghosttyPTYTeeAccumulator()

        var scheduleRequests = 0
        for index in 0..<200 {
            if accumulator.append(seq: UInt64(index), bytes: Data([0x41])) {
                scheduleRequests += 1
            }
        }

        XCTAssertEqual(scheduleRequests, 1)
        let batch = accumulator.drain()
        XCTAssertEqual(batch?.startSeq, 0)
        XCTAssertEqual(batch?.bytes.count, 200)

        // The next window asks again.
        XCTAssertTrue(accumulator.append(seq: 200, bytes: Data([0x42])))
    }

    func testDrainIsEmptyWhenNothingStaged() {
        let accumulator = LibghosttyPTYTeeAccumulator()
        XCTAssertNil(accumulator.drain())
    }

    func testDrainReportsAbsoluteProducerOffset() {
        let accumulator = LibghosttyPTYTeeAccumulator()
        accumulator.append(seq: 9_000, bytes: Data("abc".utf8))
        accumulator.append(seq: 9_003, bytes: Data("de".utf8))

        let batch = accumulator.drain()
        XCTAssertEqual(batch?.startSeq, 9_000)
        XCTAssertEqual(batch?.bytes, Data("abcde".utf8))
        XCTAssertEqual(batch?.droppedBytes, 0)
    }

    /// Under pressure the buffer must shed its OLDEST bytes and stay bounded, and
    /// the loss must be detectable — `startSeq` jumps past the dropped range.
    /// Overflow sheds the WHOLE staged window, not just the excess. Trimming the
    /// excess would mean a full memmove of the buffer per callback for as long as
    /// it stayed saturated — on libghostty's io-reader thread, under the renderer
    /// mutex, which back-pressures the child and lengthens the very main-thread
    /// stall that caused the overflow. Dropping everything is O(1) and loss is
    /// still fully signalled by the forward jump in `startSeq`.
    func testShedsWholeWindowWhenOverCapacity() {
        let accumulator = LibghosttyPTYTeeAccumulator(capacity: 8)
        accumulator.append(seq: 0, bytes: Data("01234567".utf8))
        accumulator.append(seq: 8, bytes: Data("89AB".utf8))

        let batch = accumulator.drain()
        XCTAssertEqual(String(data: batch?.bytes ?? Data(), encoding: .utf8), "89AB")
        // The gap is visible: the consumer expected 0, the batch starts at 8.
        XCTAssertEqual(batch?.startSeq, 8)
        XCTAssertEqual(batch?.droppedBytes, 8)
    }

    func testSingleWriteLargerThanCapacityKeepsTail() {
        let accumulator = LibghosttyPTYTeeAccumulator(capacity: 4)
        accumulator.append(seq: 100, bytes: Data("abcdefgh".utf8))

        let batch = accumulator.drain()
        XCTAssertEqual(String(data: batch?.bytes ?? Data(), encoding: .utf8), "efgh")
        XCTAssertEqual(batch?.startSeq, 104)
        XCTAssertEqual(batch?.droppedBytes, 4)
    }

    func testDiscontinuousProducerSeqRebasesInsteadOfSplicing() {
        let accumulator = LibghosttyPTYTeeAccumulator()
        accumulator.append(seq: 0, bytes: Data("abc".utf8))
        // Not the expected continuation (3): keep the new bytes, drop the stale.
        accumulator.append(seq: 50, bytes: Data("xyz".utf8))

        let batch = accumulator.drain()
        XCTAssertEqual(batch?.startSeq, 50)
        XCTAssertEqual(batch?.bytes, Data("xyz".utf8))
    }

    func testEmptyPayloadIsIgnored() {
        let accumulator = LibghosttyPTYTeeAccumulator()
        XCTAssertFalse(accumulator.append(seq: 0, bytes: Data()))
        XCTAssertNil(accumulator.drain())
    }

    // MARK: - Tee

    func testTeeCoalescesManyCallbacksIntoOneDrain() {
        var scheduled: [() -> Void] = []
        var drains: [LibghosttyPTYTeeDrain] = []
        let tee = LibghosttyPTYTee(
            epoch: "epoch-1",
            schedule: { work in scheduled.append(work) },
            sink: { drains.append($0) }
        )

        for index in 0..<500 {
            tee.receive(seq: UInt64(index), bytes: Data([0x41]))
        }

        XCTAssertEqual(scheduled.count, 1, "one main-thread hop per drain window")
        XCTAssertTrue(drains.isEmpty)

        scheduled.removeFirst()()
        XCTAssertEqual(drains.count, 1)
        XCTAssertEqual(drains[0].startSeq, 0)
        XCTAssertEqual(drains[0].bytes.count, 500)

        // A later burst opens a new window.
        tee.receive(seq: 500, bytes: Data([0x42]))
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(drains.count, 2)
        XCTAssertEqual(drains[1].startSeq, 500)
    }

    func testTeeDropUnderPressureShowsUpAsSeqJumpAcrossDrains() {
        var scheduled: [() -> Void] = []
        var drains: [LibghosttyPTYTeeDrain] = []
        let tee = LibghosttyPTYTee(
            epoch: "epoch-1",
            capacity: 8,
            schedule: { work in scheduled.append(work) },
            sink: { drains.append($0) }
        )

        tee.receive(seq: 0, bytes: Data("01234567".utf8))
        // Main thread never ran the first drain: these push the oldest out.
        tee.receive(seq: 8, bytes: Data("89AB".utf8))
        scheduled.removeFirst()()

        XCTAssertEqual(drains.count, 1)
        // The consumer's cursor was 0; the drain starts at 8. That forward jump
        // is the loss signal the byte lane turns into a truncated resync.
        XCTAssertEqual(drains[0].startSeq, 8)
        XCTAssertEqual(drains[0].droppedBytes, 8)
        XCTAssertEqual(String(data: drains[0].bytes, encoding: .utf8), "89AB")
    }

    func testTeeCarriesItsEpoch() {
        let tee = LibghosttyPTYTee(epoch: "epoch-42", schedule: { _ in }, sink: { _ in })
        XCTAssertEqual(tee.epoch, "epoch-42")
    }
}
