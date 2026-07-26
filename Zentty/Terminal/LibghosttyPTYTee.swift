import Foundation
import OSLog

private let libghosttyPTYTeeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "LibghosttyPTYTee")

// MARK: - Drain batch

/// One coalesced run of raw PTY bytes handed to the main actor.
///
/// `startSeq` is the absolute surface-stream offset of `bytes[0]` (the same
/// counter libghostty's tee reports), so a consumer can splice runs together and
/// detect loss. `droppedBytes` is how many bytes were shed from the OLDEST end of
/// the buffer since the previous drain because the consumer could not keep up —
/// it is diagnostics only: the authoritative loss signal is the jump in
/// `startSeq`, which the byte-lane feed turns into a `truncated` resync.
struct LibghosttyPTYTeeDrain: Equatable {
    let startSeq: Int
    let bytes: Data
    let droppedBytes: Int
}

// MARK: - Accumulator

/// Lock-guarded staging buffer between libghostty's io-reader thread and the main
/// actor.
///
/// The tee callback runs on the surface's dedicated io-reader thread while
/// libghostty holds its renderer state mutex: time spent there back-pressures the
/// child process and stalls the renderer, so ``append(seq:bytes:)`` does nothing
/// but take an `NSLock`, `memcpy`, and set a flag. Everything else (base64, wire
/// framing, fan-out) happens on the main actor after ``drain()``.
///
/// Bounded on purpose: when the main thread cannot keep up the buffer sheds its
/// OLDEST bytes rather than growing without limit. Because the retained bytes
/// keep their absolute offsets, a drop shows up downstream as a forward jump in
/// `startSeq` — detectable, not a silent splice of discontinuous output.
final class LibghosttyPTYTeeAccumulator: @unchecked Sendable {
    /// Max staged bytes before the oldest are shed. Sized well above one drain
    /// window of a fast producer (a `yes` loop or a noisy build) yet small enough
    /// that a stalled main thread cannot balloon memory across many panes.
    static let defaultCapacity = 512 * 1024

    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    /// Absolute stream offset of `buffer[0]`.
    private var startSeq = 0
    private var droppedBytes = 0
    /// True while a drain has been scheduled but has not run. Mirrors
    /// `LibghosttySurfaceActionCoalescer`: the first append in a window asks for a
    /// hop, every append after it rides along.
    private var pendingDrain = false

    init(capacity: Int = LibghosttyPTYTeeAccumulator.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        buffer.reserveCapacity(min(capacity, 64 * 1024))
    }

    /// Stages one tee callback's bytes.
    ///
    /// - Returns: `true` when the caller must schedule a drain (this append opened
    ///   a new drain window), `false` when a drain is already pending — that is
    ///   what keeps a chatty pane to one main-thread hop per window instead of one
    ///   per callback.
    @discardableResult
    func append(seq: UInt64, bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
        let incomingSeq = Int(clamping: seq)

        lock.lock()
        defer { lock.unlock() }

        if buffer.isEmpty {
            // Fresh window: adopt the callback's absolute offset as our base.
            startSeq = incomingSeq
        } else if incomingSeq != startSeq + buffer.count {
            // The stream skipped (or repeated) relative to what we hold. Exactly
            // one thread feeds a surface's tee, so this is not expected; keep the
            // NEW bytes and rebase rather than splicing a lie.
            buffer.removeAll(keepingCapacity: true)
            startSeq = incomingSeq
        }

        let typed = base.assumingMemoryBound(to: UInt8.self)
        buffer.append(contentsOf: UnsafeBufferPointer(start: typed, count: bytes.count))

        if buffer.count > capacity {
            // Shed the WHOLE staged window, not just the excess. Trimming the
            // excess would mean `removeFirst` on a 512 KiB array — a full memmove
            // per callback for as long as the buffer stays saturated, on the
            // io-reader thread, while libghostty holds the renderer mutex. That
            // back-pressures the child and blocks the main thread's own ghostty
            // calls, which lengthens the very stall that caused the overflow.
            //
            // Dropping everything is O(1) and costs nothing in correctness: loss
            // is signalled by the forward jump in `startSeq`, and the phone resets
            // its emulator on any gap regardless of how many bytes went missing.
            droppedBytes += buffer.count - bytes.count
            buffer.removeAll(keepingCapacity: true)
            startSeq = incomingSeq
            buffer.append(contentsOf: UnsafeBufferPointer(start: typed, count: bytes.count))

            // A single callback larger than the whole buffer: keep its tail.
            if buffer.count > capacity {
                let overflow = buffer.count - capacity
                buffer.removeFirst(overflow)
                startSeq += overflow
                droppedBytes += overflow
            }
        }

        guard !pendingDrain else { return false }
        pendingDrain = true
        return true
    }

    /// Test/parity seam: the same staging path with a `Data` payload, so the
    /// coalescing and drop behaviour are exercisable without a real C callback.
    @discardableResult
    func append(seq: UInt64, bytes: Data) -> Bool {
        bytes.withUnsafeBytes { append(seq: seq, bytes: $0) }
    }

    /// Takes everything staged since the last drain, or `nil` when empty.
    func drain() -> LibghosttyPTYTeeDrain? {
        lock.lock()
        defer { lock.unlock() }

        pendingDrain = false
        guard !buffer.isEmpty else {
            droppedBytes = 0
            return nil
        }
        let batch = LibghosttyPTYTeeDrain(
            startSeq: startSeq,
            bytes: Data(buffer),
            droppedBytes: droppedBytes
        )
        buffer.removeAll(keepingCapacity: true)
        startSeq += batch.bytes.count
        droppedBytes = 0
        return batch
    }
}

// MARK: - Tee

/// Owns one surface's PTY tee: the accumulator the C callback writes into, the
/// coalesced hop to the main actor, and the sink that receives each drain.
///
/// The instance itself is the C callback's `userdata`. It is held strongly by the
/// surface for exactly as long as the tee is installed; libghostty guarantees no
/// callback is in flight once removal returns, so the surface removes the tee
/// first and only then drops its reference (see `LibghosttySurface.setPTYStreamSink`).
final class LibghosttyPTYTee: @unchecked Sendable {
    typealias Sink = @MainActor (LibghosttyPTYTeeDrain) -> Void
    typealias Scheduler = (@escaping @Sendable () -> Void) -> Void

    /// Opaque id for the surface lifetime these offsets belong to.
    let epoch: String

    private let accumulator: LibghosttyPTYTeeAccumulator
    private let sink: Sink
    private let schedule: Scheduler

    init(
        epoch: String,
        capacity: Int = LibghosttyPTYTeeAccumulator.defaultCapacity,
        schedule: @escaping Scheduler = { DispatchQueue.main.async(execute: $0) },
        sink: @escaping Sink
    ) {
        self.epoch = epoch
        self.accumulator = LibghosttyPTYTeeAccumulator(capacity: capacity)
        self.schedule = schedule
        self.sink = sink
    }

    /// Hot path — called on libghostty's io-reader thread. Copies and returns.
    func receive(seq: UInt64, bytes: UnsafeRawBufferPointer) {
        guard accumulator.append(seq: seq, bytes: bytes) else { return }
        // At most one drain is outstanding at a time (the accumulator only asks
        // once per window), so the hop cannot reorder against itself.
        schedule { [weak self] in self?.drainOnMain() }
    }

    /// Test seam mirroring the C callback with a `Data` payload.
    func receive(seq: UInt64, bytes: Data) {
        bytes.withUnsafeBytes { receive(seq: seq, bytes: $0) }
    }

    private func drainOnMain() {
        guard let batch = accumulator.drain() else { return }
        if batch.droppedBytes > 0 {
            libghosttyPTYTeeLogger.info(
                "pty tee shed oldest bytes under pressure: dropped=\(batch.droppedBytes, privacy: .public)"
            )
        }
        MainActor.assumeIsolated { sink(batch) }
    }
}
