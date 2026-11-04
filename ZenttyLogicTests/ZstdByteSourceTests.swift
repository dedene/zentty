import Foundation
import XCTest
@testable import Zentty

final class ZstdByteSourceTests: XCTestCase {
    // MARK: - Hand-built frames

    private enum Block {
        case raw([UInt8])
        case rle(UInt8, count: Int)

        var contentCount: Int {
            switch self {
            case let .raw(bytes): bytes.count
            case let .rle(_, count): count
            }
        }
    }

    /// Single-segment frame, no checksum, content size in the header (1, 2 or 4 bytes).
    private func frame(_ blocks: [Block]) -> [UInt8] {
        let contentSize = blocks.reduce(0) { $0 + $1.contentCount }
        var bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        if contentSize <= 255 {
            bytes += [0x20, UInt8(contentSize)]
        } else if contentSize <= 65_791 {
            let stored = contentSize - 256
            bytes += [0x60, UInt8(stored & 0xFF), UInt8(stored >> 8)]
        } else {
            bytes += [0xA0] + (0 ..< 4).map { UInt8((contentSize >> ($0 * 8)) & 0xFF) }
        }
        for (index, block) in blocks.enumerated() {
            bytes += blockBytes(block, isLast: index == blocks.count - 1)
        }
        return bytes
    }

    /// Frame with no content size (not single segment, 1 KB window) holding one raw block.
    private func frameWithoutContentSize(_ payload: [UInt8]) -> [UInt8] {
        [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00] + blockBytes(.raw(payload), isLast: true)
    }

    private func skippableFrame(_ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count)
        return [0x50, 0x2A, 0x4D, 0x18, UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
            + payload
    }

    private func blockBytes(_ block: Block, isLast: Bool) -> [UInt8] {
        let type: UInt32
        let body: [UInt8]
        switch block {
        case let .raw(bytes):
            type = 0
            body = bytes
        case let .rle(byte, _):
            type = 1
            body = [byte]
        }
        let value = (isLast ? 1 : 0) | type << 1 | UInt32(block.contentCount) << 3
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)] + body
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ bytes: [UInt8], name: String = "rollout.jsonl.zst") throws -> String {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    private func readAll(_ source: ZstdByteSource, chunkSize: Int = 64 * 1024) throws -> [UInt8] {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = try chunk.withUnsafeMutableBytes { try source.read(into: $0) }
            if count == 0 {
                return result
            }
            result += chunk[0 ..< count]
        }
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // MARK: - Real sample

    /// The text compressed into `sampleBase64`: 1,500 JSONL lines, 168,030 bytes, so the frame
    /// spans more than one 128 KB block.
    private static let sampleText: String = (0 ..< 1_500).map { index in
        let role = index % 2 == 0 ? "user" : "assistant"
        return #"{"type":"response_item","seq":\#(index),"payload":{"role":"\#(role)","text":"synthetic line \#(index) of the zstd fixture"}}"#
            + "\n"
    }.joined()

    /// `zstd -19` (v1.5.7 CLI, content size and checksum on) of `sampleText`.
    private static let sampleBase64 = """
    KLUv/aRekAIATBwAVnl4HGBN0mIsWUb7UpaKQq8IgsBV2d3dm/qmjcNglBOYAHAAcQCJeGdW9WRDVmyK7apmIt6ZVT3VUJWaUruq
    mYh3ZlVPD12e8q5qJuKdWdUT0dDO6mhO4uDN2VhNPVOyQJAgCwQhIICKCuN4gEgiFgdjkCATcyAkc8AwZY6FRcIULJIDIVmQQAwB
    I4k4EiPAeDgQiASGB4NCwDAgYEiQIGgwAoqA4XAgRoChcCSLgQNZYGhAjgdDwDgaJBKDIqV2Vz1zxO82u+qfpsvlXVKlTEKkOzKj
    KnoiIipUaLeolsyCWO6KWakqX0ophXZVMxHvzKqedmjLTtld1UzEO7OqJx3SolN0VzUT8c6s6imHsuSU3FXNRLwzq3rCISw4BXdV
    MxHvzKqebujKTbld1QzzU8q7q7qZi7h3a7ZV+0tLW7bsrqpqpiLqnZppldJKSlq06G6qZmYi5l2aZVV+UlKWLLmLqpiJiHiHZliF
    j4SEBQvunuplHuLdndlV3R8dXblyu6ZqmYaGRmdmVmVvZGTFiu2WamUWYt2VWVXVFxVVqf/8z//8z//8z//8z//8z//8z//8z//8
    z//8z//8z//8z//8z//8z//8z//8z//8z//8z//8zz//8z//8z//8z//8z//AYJLqCKA4u3sHweiV5RUlgMSQBD4VxAYQWAEwev4
    A8XNAsoNmjR2Ki5qULpAqUJR4cbFnQVKGyprbCpcbKC5QFNDkeLFi5sFlBtoauxUXNRIeYFShaKGi4s7C5RWaNbYVLjYgXKBpoZi
    iotXABf/WalQsYGlwkaFTQsXFy5VUNagqbizuJFLtvNSoErAmgNbijLnGCkGbilQp8DmqJ2jbwsd4cwnRYGWItYUaFNkjPy8crCm
    QEsRagokp4wqA9woaBGkxSii5GfFQBbrmduFW7JiArQyYMZ31izQUkRNgTaLjJGfKwfrFGgpoKZA0pRRZcCNgjaCtBgiSn6uGMhS
    oEqBNhmEmFZDo9VCo004TAaNIeYwuUNmjjl1RiTWOk4defZE+BPR/rzkUpYEZxKOmHBkwhlJDOoy4ciEExGeiPDnkgNZEiyTcGTC
    kQnPSGJQx4QjM5yIcCLCn0sOyJLgTMKRGY5MOCOJQR0nHJlwIsKJEP5cciBLgjMTjkw4MrNwL41zWHM4SBwO4A2ODtTUYEcd5MhK
    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
    ezl0LXI7WD17HVstuZ24Ons5di15O1gte70JbbFzzC6HzYDfB3QEAMKMCwTwOdJrFVVUUUUVVVRRRQVVVFFFFVVUUUUVVVR5nud5
    nufhPM/zPM/zPM/zPAGAo/QmDlZnW4euSW4HK2evw64lt/Ux+cFWnXkduya5HUydvU67llwdrM6+jl2T3A7Wzl6HXUtuD1ZnWyds
    vo1rK3k7WB17HbssuR1cnb0Wu5bcHayOvY5dl9wOxm1kBADizAoF8DlJuwlFFVVUUUUVVVRRRZXnecI8z/M8z/M8z/M8z/M8Q57n
    eZ7neZ4BgKP0JsHlaOXsddC15LZgdbZ17FrkdrBy9jq2WjJXPofaYmtnr0OrJbcFq7O3Y9cit4PVs9ex1ZLbidXZy7FrydvBatkb
    mx8s27QuuR2snL0Ou5bcHqzOto5dy1wmB1UEALIMCAXgDyBYAt5777333nvvvffOe++9995777333nvuvfcOgKP4Evj/FQT++Qd3
    t/XE5Wi17HVoteR2YnX2cuxa8nawWvY6dltyO7A6ez3sGigmz9yWc6uz12LXkrWD1bnXscuS28HV2Wuxa8ndwerY67TrktvB1InN
    b3Xbxl5LbgdWZy/HroulDrpTpWM=
"""

    private func samplePath() throws -> String {
        let data = try XCTUnwrap(Data(base64Encoded: Self.sampleBase64, options: .ignoreUnknownCharacters))
        return try write(Array(data))
    }

    // MARK: - Tests

    func test_raw_block_frame() throws {
        let text = "{\"a\":1}\n{\"b\":2}\n"
        let path = try write(frame([.raw(bytes(text))]))

        let source = try ZstdByteSource(path: path)
        XCTAssertEqual(try readAll(source), bytes(text))
        XCTAssertEqual(source.offset, Int64(text.utf8.count))
        // Reads after EOF stay at EOF and never reach the decoder again.
        for _ in 0 ..< 40 {
            XCTAssertEqual(try readAll(source), [])
        }
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: path), Int64(text.utf8.count))
    }

    func test_multi_block() throws {
        let expected = bytes("alpha\n") + [UInt8](repeating: 0x78, count: 300) + bytes("\nomega\n")
        let path = try write(frame([.raw(bytes("alpha\n")), .rle(0x78, count: 300), .raw(bytes("\nomega\n"))]))

        XCTAssertEqual(try readAll(ZstdByteSource(path: path), chunkSize: 7), expected)
        XCTAssertEqual(try readAll(ZstdByteSource(path: path), chunkSize: 1), expected)
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: path), Int64(expected.count))

        let skipped = try ZstdByteSource(path: path)
        try skipped.skip(6 + 300)
        XCTAssertEqual(skipped.offset, 306)
        XCTAssertEqual(try readAll(skipped), bytes("\nomega\n"))
    }

    func test_concatenated_and_skippable_frames_read_as_one_stream() throws {
        let first = "{\"seq\":0}\n{\"se"
        let second = "q\":1}\n"
        let path = try write(
            frame([.raw(bytes(first))]) + skippableFrame([1, 2, 3, 4, 5]) + frame([.raw(bytes(second))])
        )

        XCTAssertEqual(try readAll(ZstdByteSource(path: path), chunkSize: 5), bytes(first + second))
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: path), Int64((first + second).utf8.count))

        var reader = JSONLTailReader(source: try ZstdByteSource(path: path), startOffset: 0, chunkSize: 4)
        var lines: [String] = []
        let stats = try reader.readLines { line, _ in
            lines.append(String(decoding: line, as: UTF8.self))
            return .continue
        }
        XCTAssertEqual(lines, ["{\"seq\":0}", "{\"seq\":1}"])
        XCTAssertEqual(stats.committedOffset, Int64((first + second).utf8.count))
        XCTAssertTrue(stats.reachedEOF)
    }

    func test_frame_content_size() throws {
        let small = try write(frame([.raw(bytes("x"))]))
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: small), 1)

        let large = try write(frame([.rle(0x41, count: 70_000)]))
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: large), 70_000)

        // Content size absent from the header: unknown, but the data still decodes.
        let unknown = try write(frameWithoutContentSize(bytes("abc\n")))
        XCTAssertNil(ZstdByteSource.frameContentSize(path: unknown))
        XCTAssertEqual(try readAll(ZstdByteSource(path: unknown)), bytes("abc\n"))

        let complete = frame([.raw(bytes("hello\n")), .raw(bytes("world\n"))])
        XCTAssertNil(ZstdByteSource.frameContentSize(path: try write(Array(complete.dropLast(3)))))
        XCTAssertNil(ZstdByteSource.frameContentSize(path: try write(complete + [0x00])))
        XCTAssertNil(ZstdByteSource.frameContentSize(path: try write(bytes("{\"plain\":true}\n"))))
        XCTAssertNil(ZstdByteSource.frameContentSize(path: try write([])))
        XCTAssertNil(ZstdByteSource.frameContentSize(path: "/nonexistent/agent-history-\(UUID().uuidString).zst"))
    }

    func test_corrupt_throws() throws {
        let plain = try write(bytes("{\"plain\":true}\n"))
        XCTAssertThrowsError(try readAll(ZstdByteSource(path: plain))) { error in
            guard case .decompression = error as? ZstdByteSource.Failure else {
                return XCTFail("expected a decompression error, got \(error)")
            }
        }

        let empty = try write([])
        XCTAssertThrowsError(try readAll(ZstdByteSource(path: empty))) { error in
            XCTAssertEqual(error as? ZstdByteSource.Failure, .truncated)
        }

        let sample = try XCTUnwrap(Data(base64Encoded: Self.sampleBase64, options: .ignoreUnknownCharacters))
        let truncated = try write(Array(sample.prefix(sample.count / 2)))
        XCTAssertThrowsError(try readAll(ZstdByteSource(path: truncated))) { error in
            XCTAssertEqual(error as? ZstdByteSource.Failure, .truncated)
        }

        var flipped = Array(sample)
        flipped[flipped.count / 2] ^= 0xFF
        XCTAssertThrowsError(try readAll(ZstdByteSource(path: try write(flipped))))

        let short = try ZstdByteSource(path: try write(frame([.raw(bytes("abc"))])))
        XCTAssertThrowsError(try short.skip(4)) { error in
            XCTAssertEqual(error as? ZstdByteSource.Failure, .unexpectedEOF)
        }

        XCTAssertThrowsError(try ZstdByteSource(path: "/nonexistent/agent-history-\(UUID().uuidString).zst")) { error in
            XCTAssertTrue(error is POSIXError)
        }
    }

    func test_real_compressed_sample() throws {
        let path = try samplePath()
        let expected = bytes(Self.sampleText)
        XCTAssertEqual(expected.count, 168_030)

        XCTAssertEqual(try readAll(ZstdByteSource(path: path)), expected)
        XCTAssertEqual(try readAll(ZstdByteSource(path: path), chunkSize: 4_093), expected)
        XCTAssertEqual(ZstdByteSource.frameContentSize(path: path), Int64(expected.count))

        var reader = JSONLTailReader(source: try ZstdByteSource(path: path), startOffset: 0)
        var count = 0
        var lastLine = ""
        let stats = try reader.readLines { line, _ in
            count += 1
            lastLine = String(decoding: line, as: UTF8.self)
            return .continue
        }
        XCTAssertEqual(count, 1_500)
        XCTAssertTrue(lastLine.contains("synthetic line 1499 of the zstd fixture"))
        XCTAssertEqual(stats.committedOffset, Int64(expected.count))

        // Resume mid-stream: skip to a decompressed offset, then read the rest.
        let resumed = try ZstdByteSource(path: path)
        try resumed.skip(150_000)
        XCTAssertEqual(try readAll(resumed), Array(expected[150_000...]))
    }

    func test_fingerprint_hashes_decompressed_window() throws {
        let path = try samplePath()
        let expected = bytes(Self.sampleText)

        XCTAssertEqual(
            ZstdByteSource.fingerprint(path: path, endOffset: 140_000),
            AgentHistoryFileFingerprint.hash(expected[(140_000 - 4_096) ..< 140_000])
        )
        XCTAssertEqual(
            ZstdByteSource.fingerprint(path: path, endOffset: 100),
            AgentHistoryFileFingerprint.hash(expected[0 ..< 100])
        )
        XCTAssertEqual(
            ZstdByteSource.fingerprint(path: path, endOffset: Int64(expected.count)),
            AgentHistoryFileFingerprint.hash(expected[(expected.count - 4_096)...])
        )
        XCTAssertNil(ZstdByteSource.fingerprint(path: path, endOffset: Int64(expected.count) + 1))
        XCTAssertNil(ZstdByteSource.fingerprint(path: path, endOffset: -1))
    }
}
