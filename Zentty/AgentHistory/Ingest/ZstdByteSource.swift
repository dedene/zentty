import CZstd
import Darwin
import Foundation

/// Streams the decompressed bytes of a `.zst` file (one or more Zstandard frames, skippable
/// frames allowed) from the start, for compressed Codex rollouts.
///
/// Offsets are always in **decompressed** bytes: `offset`, `skip` and the cursor offsets callers
/// keep for a `.zstdJSONL` unit. Never compare them with the compressed file size and never
/// `pread` the compressed file at such an offset. The stream is forward-only; `skip` decompresses
/// and discards.
///
/// Errors: a corrupt stream throws `.decompression`; input that ends inside a frame throws
/// `.truncated`. A clean end of the last frame reads as EOF (0).
///
/// Not thread-safe: one instance per stream, used from one queue (the indexer queue).
final class ZstdByteSource: AgentHistoryByteSource {
    enum Failure: Error, Equatable {
        case cannotCreateStream
        /// Zstandard error code (`ZSTD_ErrorCode`).
        case decompression(code: Int)
        /// The compressed input ended inside a frame.
        case truncated
        /// `skip` asked for more bytes than the stream holds.
        case unexpectedEOF
    }

    static let bufferSize = 256 * 1024

    /// Decompressed bytes delivered (read or skipped) so far.
    private(set) var offset: Int64 = 0

    private let descriptor: Int32
    private let stream: OpaquePointer
    private let input: UnsafeMutableRawBufferPointer
    private var inputLength = 0
    private var inputPosition = 0
    private var inputEOF = false
    /// The last `ZSTD_decompressStream` call returned 0: every frame so far is decoded and
    /// flushed, so running out of input here is a clean end.
    private var atFrameBoundary = false
    /// EOF was returned. Later reads return 0 without calling the decoder (repeated no-progress
    /// calls make zstd report an error).
    private var finished = false
    private var discardBuffer: UnsafeMutableRawBufferPointer?

    init(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let stream = ZSTD_createDStream() else {
            close(descriptor)
            throw Failure.cannotCreateStream
        }
        self.descriptor = descriptor
        self.stream = stream
        self.input = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 1)
    }

    deinit {
        ZSTD_freeDStream(stream)
        close(descriptor)
        input.deallocate()
        discardBuffer?.deallocate()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0, !finished else {
            return 0
        }
        var output = ZSTD_outBuffer(dst: base, size: buffer.count, pos: 0)
        while true {
            if inputPosition == inputLength {
                if !inputEOF {
                    try refill()
                }
                if inputPosition == inputLength, inputEOF, atFrameBoundary {
                    finished = true
                    return 0
                }
                // Otherwise the decoder may still hold output; one call with empty input flushes it.
            }

            var source = ZSTD_inBuffer(src: input.baseAddress, size: inputLength, pos: inputPosition)
            let result = ZSTD_decompressStream(stream, &output, &source)
            inputPosition = source.pos
            if ZSTD_isError(result) != 0 {
                throw Failure.decompression(code: -result)
            }
            atFrameBoundary = result == 0

            if output.pos > 0 {
                offset += Int64(output.pos)
                return output.pos
            }
            if inputPosition == inputLength, inputEOF {
                if atFrameBoundary {
                    finished = true
                    return 0
                }
                throw Failure.truncated
            }
        }
    }

    /// Decompresses and discards `count` bytes. Throws `.unexpectedEOF` when the stream ends first.
    func skip(_ count: Int64) throws {
        guard count > 0 else {
            return
        }
        let scratch: UnsafeMutableRawBufferPointer
        if let discardBuffer {
            scratch = discardBuffer
        } else {
            scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 1)
            discardBuffer = scratch
        }
        var remaining = count
        while remaining > 0 {
            let length = Int(min(remaining, Int64(scratch.count)))
            let delivered = try read(into: UnsafeMutableRawBufferPointer(rebasing: scratch[0 ..< length]))
            if delivered == 0 {
                throw Failure.unexpectedEOF
            }
            remaining -= Int64(delivered)
        }
    }

    private func refill() throws {
        while true {
            let count = Darwin.read(descriptor, input.baseAddress!, input.count)
            if count > 0 {
                inputLength = count
                inputPosition = 0
                return
            }
            if count == 0 {
                inputLength = 0
                inputPosition = 0
                inputEOF = true
                return
            }
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

extension ZstdByteSource {
    private static let frameMagic: UInt32 = 0xFD2F_B528
    private static let skippableMagicStart: UInt32 = 0x184D_2A50
    private static let skippableMagicMask: UInt32 = 0xFFFF_FFF0
    private static let frameHeaderSizeMax = 18

    /// Total decompressed size of the file, from the frame headers alone (no decompression).
    /// Walks every frame (block headers only) so concatenated frames sum correctly; skippable
    /// frames count 0. nil when the file cannot be read, is not a complete Zstandard stream, or
    /// any frame omits its content size.
    static func frameContentSize(path: String) -> Int64? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return nil
        }
        let fileSize = Int64(info.st_size)
        guard fileSize > 0 else {
            return nil
        }

        var position: Int64 = 0
        var total: Int64 = 0
        var header = [UInt8](repeating: 0, count: frameHeaderSizeMax)
        while position < fileSize {
            let headerLength = readFully(descriptor, into: &header, count: frameHeaderSizeMax, at: position)
            guard headerLength >= 8 else {
                return nil
            }
            let magic = littleEndianUInt32(header, at: 0)
            if magic & skippableMagicMask == skippableMagicStart {
                position += 8 + Int64(littleEndianUInt32(header, at: 4))
                continue
            }
            guard magic == frameMagic else {
                return nil
            }

            let contentSize = header.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, headerLength) }
            // ZSTD_CONTENTSIZE_UNKNOWN (-1) and ZSTD_CONTENTSIZE_ERROR (-2).
            guard contentSize < UInt64.max - 1, contentSize <= UInt64(Int64.max - total) else {
                return nil
            }
            total += Int64(contentSize)

            let descriptorByte = header[4]
            let singleSegment = (descriptorByte >> 5) & 1 == 1
            let hasChecksum = (descriptorByte >> 2) & 1 == 1
            let dictionaryIDBytes: Int64 = [0, 1, 2, 4][Int(descriptorByte & 3)]
            let contentSizeBytes: Int64 = [singleSegment ? 1 : 0, 2, 4, 8][Int(descriptorByte >> 6)]
            position += 5 + (singleSegment ? 0 : 1) + dictionaryIDBytes + contentSizeBytes

            var blockHeader = [UInt8](repeating: 0, count: 3)
            while true {
                guard readFully(descriptor, into: &blockHeader, count: 3, at: position) == 3 else {
                    return nil
                }
                let value = UInt32(blockHeader[0]) | UInt32(blockHeader[1]) << 8 | UInt32(blockHeader[2]) << 16
                let isLast = value & 1 == 1
                let blockSize = Int64(value >> 3)
                switch (value >> 1) & 3 {
                case 0, 2: position += 3 + blockSize  // raw, compressed
                case 1: position += 3 + 1  // RLE: one byte repeated blockSize times
                default: return nil  // reserved
                }
                if isLast {
                    break
                }
            }
            if hasChecksum {
                position += 4
            }
        }
        return position == fileSize ? total : nil
    }

    /// FNV-1a 64 (`AgentHistoryFileFingerprint.hash`) over the decompressed window
    /// `[endOffset - min(4096, endOffset), endOffset)`, the `.zstdJSONL` counterpart of
    /// `AgentHistoryFileFingerprint.compute`. Decompresses from the start of the file. nil when the
    /// file cannot be decoded or decompresses to fewer than `endOffset` bytes.
    static func fingerprint(path: String, endOffset: Int64) -> Int64? {
        guard endOffset >= 0 else {
            return nil
        }
        let length = Int(min(Int64(AgentHistoryFileFingerprint.windowBytes), endOffset))
        do {
            let source = try ZstdByteSource(path: path)
            try source.skip(endOffset - Int64(length))
            var window = [UInt8](repeating: 0, count: length)
            let filled = try window.withUnsafeMutableBytes { raw -> Int in
                var filled = 0
                while filled < length {
                    let count = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[filled...]))
                    if count == 0 {
                        break
                    }
                    filled += count
                }
                return filled
            }
            guard filled == length else {
                return nil
            }
            return AgentHistoryFileFingerprint.hash(window)
        } catch {
            return nil
        }
    }

    private static func readFully(_ descriptor: Int32, into buffer: inout [UInt8], count: Int, at offset: Int64) -> Int {
        buffer.withUnsafeMutableBytes { raw -> Int in
            var total = 0
            while total < count {
                let result = pread(descriptor, raw.baseAddress! + total, count - total, off_t(offset) + off_t(total))
                if result > 0 {
                    total += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return total
        }
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
