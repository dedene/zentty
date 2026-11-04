import Darwin
import Foundation

/// A forward-only byte stream for transcript ingest. `read` fills a prefix of `buffer` and returns
/// how many bytes it wrote; 0 means EOF (for now: a file that grows later can return more).
protocol AgentHistoryByteSource: AnyObject {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

/// Plain file read with `read(2)` from a starting offset. The descriptor closes on deinit.
final class FileByteSource: AgentHistoryByteSource {
    private let descriptor: Int32

    init(path: String, offset: Int64) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.posixError()
        }
        if offset > 0, lseek(descriptor, off_t(offset), SEEK_SET) < 0 {
            let error = Self.posixError()
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else {
            return 0
        }
        while true {
            let count = Darwin.read(descriptor, base, buffer.count)
            if count >= 0 {
                return count
            }
            if errno != EINTR {
                throw Self.posixError()
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Streams complete JSONL lines from a byte source without loading the file.
///
/// Rules:
/// - Only complete (`\n`-terminated) lines are delivered. A trailing `\r` is stripped; empty lines
///   are skipped. A partial trailing line stays buffered for the next call (or is re-read by a
///   new reader started at `committedOffset`).
/// - `committedOffset` is the absolute offset just past the last consumed complete line: delivered
///   lines (including the one that returned `.stop`), skipped blank lines and discarded oversized
///   lines. It is always a line start, so it is safe to persist as a resume offset.
/// - A line longer than `maxLineBytes` switches to discard mode until its `\n`; it is counted in
///   `oversizedLines` once complete. If EOF arrives while discarding, the offset stays at the
///   start of that line (it may still be being written).
/// - `isCancelled` is checked after every 1,024 consumed lines (A-7).
///
/// The reader keeps its buffers between calls, so calling `readLines` again continues where the
/// previous call stopped. Copies share the buffers: use one reader per stream.
struct JSONLTailReader {
    static let defaultMaxLineBytes = 2 * 1024 * 1024
    static let cancellationCheckInterval = 1_024

    enum Control {
        case `continue`, stop
    }

    struct Stats: Equatable {
        var committedOffset: Int64
        var lines: Int
        var oversizedLines: Int
        var reachedEOF: Bool
        var cancelled: Bool
    }

    /// Chunk and partial-line storage. A class so the line body can borrow it while the reader's
    /// scalar state is mutated.
    private final class Buffers {
        let chunk: UnsafeMutableRawBufferPointer
        var chunkLength = 0
        var scanIndex = 0
        var carry: [UInt8] = []

        init(chunkSize: Int) {
            chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
        }

        deinit {
            chunk.deallocate()
        }
    }

    private let source: AgentHistoryByteSource
    private let maxLineBytes: Int
    private let isCancelled: () -> Bool
    private let buffers: Buffers
    /// Absolute offset of `chunk[0]`.
    private var chunkBaseOffset: Int64
    private var committedOffset: Int64
    private var discarding = false
    private var linesSinceCancellationCheck = 0

    init(
        source: AgentHistoryByteSource,
        startOffset: Int64,
        maxLineBytes: Int = defaultMaxLineBytes,
        chunkSize: Int = 1 << 18,
        isCancelled: @escaping () -> Bool = { false }
    ) {
        self.source = source
        self.maxLineBytes = max(1, maxLineBytes)
        self.isCancelled = isCancelled
        self.buffers = Buffers(chunkSize: max(1, chunkSize))
        self.chunkBaseOffset = startOffset
        self.committedOffset = startOffset
    }

    /// Calls `body` with each complete line (without `\n`/`\r`) and the absolute offset just
    /// past its `\n`. The line buffer is only valid during the call. Errors from `body` or the
    /// source propagate; the offset of the failing line is not committed and the reader should be
    /// discarded (start a new one at the last `committedOffset`).
    mutating func readLines(
        _ body: (_ line: UnsafeRawBufferPointer, _ endOffset: Int64) throws -> Control
    ) throws -> Stats {
        var stats = Stats(committedOffset: committedOffset, lines: 0, oversizedLines: 0, reachedEOF: false, cancelled: false)
        let buffers = self.buffers

        while true {
            if buffers.scanIndex >= buffers.chunkLength {
                chunkBaseOffset += Int64(buffers.chunkLength)
                buffers.chunkLength = 0
                buffers.scanIndex = 0
                let count = try source.read(into: buffers.chunk)
                if count <= 0 {
                    stats.reachedEOF = true
                    break
                }
                buffers.chunkLength = count
            }

            let start = buffers.scanIndex
            let remaining = buffers.chunkLength - start
            let base = buffers.chunk.baseAddress! + start
            guard let newline = memchr(base, Int32(UInt8(ascii: "\n")), remaining) else {
                // No line end in this chunk: buffer the partial line (or keep discarding).
                if !discarding {
                    if buffers.carry.count + remaining > maxLineBytes {
                        discarding = true
                        buffers.carry.removeAll(keepingCapacity: false)
                    } else {
                        buffers.carry.append(contentsOf: UnsafeRawBufferPointer(start: base, count: remaining))
                    }
                }
                buffers.scanIndex = buffers.chunkLength
                continue
            }

            let length = UnsafeRawPointer(newline) - UnsafeRawPointer(base)
            let newlineIndex = start + length
            buffers.scanIndex = newlineIndex + 1
            let endOffset = chunkBaseOffset + Int64(newlineIndex + 1)

            let control: Control
            if discarding || buffers.carry.count + length > maxLineBytes {
                discarding = false
                buffers.carry.removeAll(keepingCapacity: false)
                stats.oversizedLines += 1
                control = .continue
            } else if buffers.carry.isEmpty {
                control = try Self.deliver(UnsafeRawBufferPointer(start: base, count: length), endOffset, &stats, body)
            } else {
                buffers.carry.append(contentsOf: UnsafeRawBufferPointer(start: base, count: length))
                control = try buffers.carry.withUnsafeBytes { try Self.deliver($0, endOffset, &stats, body) }
                buffers.carry.removeAll(keepingCapacity: true)
            }

            committedOffset = endOffset
            stats.committedOffset = endOffset
            if control == .stop {
                break
            }

            linesSinceCancellationCheck += 1
            if linesSinceCancellationCheck >= Self.cancellationCheckInterval {
                linesSinceCancellationCheck = 0
                if isCancelled() {
                    stats.cancelled = true
                    break
                }
            }
        }
        return stats
    }

    private static func deliver(
        _ raw: UnsafeRawBufferPointer,
        _ endOffset: Int64,
        _ stats: inout Stats,
        _ body: (_ line: UnsafeRawBufferPointer, _ endOffset: Int64) throws -> Control
    ) throws -> Control {
        var line = raw
        if let last = line.last, last == UInt8(ascii: "\r") {
            line = UnsafeRawBufferPointer(rebasing: line.dropLast())
        }
        guard !line.isEmpty else {
            return .continue
        }
        stats.lines += 1
        return try body(line, endOffset)
    }
}
