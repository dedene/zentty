import Foundation
import XCTest
@testable import Zentty

/// In-memory source that hands out at most `maxRead` bytes per call (simulates short reads).
private final class MemoryByteSource: AgentHistoryByteSource {
    private var bytes: [UInt8]
    private var position = 0
    private let maxRead: Int

    init(_ text: String, maxRead: Int = .max) {
        self.bytes = Array(text.utf8)
        self.maxRead = maxRead
    }

    func append(_ text: String) {
        bytes.append(contentsOf: Array(text.utf8))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = min(buffer.count, maxRead, bytes.count - position)
        guard count > 0 else {
            return 0
        }
        bytes.withUnsafeBytes { source in
            buffer.baseAddress!.copyMemory(from: source.baseAddress! + position, byteCount: count)
        }
        position += count
        return count
    }
}

final class JSONLTailReaderTests: XCTestCase {
    private struct Line: Equatable {
        let text: String
        let endOffset: Int64
    }

    private func collect(
        _ reader: inout JSONLTailReader,
        stopAfter: Int? = nil
    ) throws -> (lines: [Line], stats: JSONLTailReader.Stats) {
        var lines: [Line] = []
        let stats = try reader.readLines { line, endOffset in
            lines.append(Line(text: String(decoding: line, as: UTF8.self), endOffset: endOffset))
            if let stopAfter, lines.count >= stopAfter {
                return .stop
            }
            return .continue
        }
        return (lines, stats)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func test_reads_complete_lines_and_committed_offset() throws {
        var reader = JSONLTailReader(source: MemoryByteSource("{\"a\":1}\n{\"b\":2}\n"), startOffset: 0)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines, [Line(text: "{\"a\":1}", endOffset: 8), Line(text: "{\"b\":2}", endOffset: 16)])
        XCTAssertEqual(
            stats,
            JSONLTailReader.Stats(committedOffset: 16, lines: 2, oversizedLines: 0, reachedEOF: true, cancelled: false)
        )
    }

    func test_start_offset_is_added_to_end_offsets() throws {
        var reader = JSONLTailReader(source: MemoryByteSource("x\ny\n"), startOffset: 100)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.endOffset), [102, 104])
        XCTAssertEqual(stats.committedOffset, 104)
    }

    func test_partial_trailing_line_left() throws {
        var reader = JSONLTailReader(source: MemoryByteSource("one\ntwo\nthr"), startOffset: 0)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.text), ["one", "two"])
        XCTAssertEqual(stats.committedOffset, 8)
        XCTAssertTrue(stats.reachedEOF)
    }

    func test_resume_after_append() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"n\":1}\n{\"n\":2".utf8).write(to: file)

        var first = JSONLTailReader(source: try FileByteSource(path: file.path, offset: 0), startOffset: 0)
        let (firstLines, firstStats) = try collect(&first)
        XCTAssertEqual(firstLines.map(\.text), ["{\"n\":1}"])
        XCTAssertEqual(firstStats.committedOffset, 8)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}\n{\"n\":3}\n".utf8))
        try handle.close()

        let resumeOffset = firstStats.committedOffset
        var second = JSONLTailReader(
            source: try FileByteSource(path: file.path, offset: resumeOffset),
            startOffset: resumeOffset
        )
        let (secondLines, secondStats) = try collect(&second)
        XCTAssertEqual(secondLines.map(\.text), ["{\"n\":2}", "{\"n\":3}"])
        XCTAssertEqual(secondLines.map(\.endOffset), [16, 24])
        XCTAssertEqual(secondStats.committedOffset, 24)
        XCTAssertTrue(secondStats.reachedEOF)
    }

    func test_same_reader_continues_after_append() throws {
        let source = MemoryByteSource("a\nb")
        var reader = JSONLTailReader(source: source, startOffset: 0)
        let (firstLines, firstStats) = try collect(&reader)
        XCTAssertEqual(firstLines.map(\.text), ["a"])
        XCTAssertEqual(firstStats.committedOffset, 2)

        source.append("c\nd\n")
        let (secondLines, secondStats) = try collect(&reader)
        XCTAssertEqual(secondLines.map(\.text), ["bc", "d"])
        XCTAssertEqual(secondStats.committedOffset, 7)
    }

    func test_file_byte_source_missing_file_throws() {
        XCTAssertThrowsError(try FileByteSource(path: "/nonexistent-\(UUID().uuidString)/x.jsonl", offset: 0))
    }

    func test_oversized_line_skipped_counted_continues() throws {
        let big = String(repeating: "x", count: 50)
        let text = "short\n\(big)\nafter\n"
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0, maxLineBytes: 10, chunkSize: 8)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.text), ["short", "after"])
        XCTAssertEqual(stats.oversizedLines, 1)
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.committedOffset, Int64(text.utf8.count))
    }

    func test_oversized_line_within_one_chunk_is_skipped() throws {
        let text = "\(String(repeating: "y", count: 20))\nok\n"
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0, maxLineBytes: 10, chunkSize: 1024)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.text), ["ok"])
        XCTAssertEqual(stats.oversizedLines, 1)
    }

    func test_line_of_exactly_max_bytes_is_delivered() throws {
        let exact = String(repeating: "z", count: 10)
        var reader = JSONLTailReader(source: MemoryByteSource("\(exact)\n"), startOffset: 0, maxLineBytes: 10, chunkSize: 3)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.text), [exact])
        XCTAssertEqual(stats.oversizedLines, 0)
    }

    func test_completed_oversized_last_line_commits_after_it() throws {
        // A completed oversized line advances the offset so a resume never re-reads it.
        let text = "a\n\(String(repeating: "q", count: 30))\n"
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0, maxLineBytes: 10, chunkSize: 4)
        let (_, stats) = try collect(&reader)

        XCTAssertEqual(stats.committedOffset, Int64(text.utf8.count))
        XCTAssertEqual(stats.oversizedLines, 1)
    }

    func test_oversized_partial_at_eof_keeps_offset() throws {
        let text = "keep\n\(String(repeating: "p", count: 40))"
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0, maxLineBytes: 10, chunkSize: 8)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.map(\.text), ["keep"])
        XCTAssertEqual(stats.committedOffset, 5, "offset stays at the start of the unfinished oversized line")
        XCTAssertEqual(stats.oversizedLines, 0, "counted only once the line is complete")
        XCTAssertTrue(stats.reachedEOF)
    }

    func test_stop_commits_processed_line() throws {
        var reader = JSONLTailReader(source: MemoryByteSource("1\n2\n3\n4\n"), startOffset: 0, chunkSize: 1024)
        let (lines, stats) = try collect(&reader, stopAfter: 2)

        XCTAssertEqual(lines.map(\.text), ["1", "2"])
        XCTAssertEqual(stats.committedOffset, 4)
        XCTAssertEqual(stats.lines, 2)
        XCTAssertFalse(stats.reachedEOF)

        // The rest of the buffered chunk is kept for the next call.
        let (rest, restStats) = try collect(&reader)
        XCTAssertEqual(rest.map(\.text), ["3", "4"])
        XCTAssertEqual(restStats.committedOffset, 8)
        XCTAssertTrue(restStats.reachedEOF)
    }

    func test_throwing_body_propagates() {
        struct Boom: Error {}
        var reader = JSONLTailReader(source: MemoryByteSource("a\nb\n"), startOffset: 0)
        XCTAssertThrowsError(try reader.readLines { _, _ in throw Boom() })
    }

    func test_crlf_and_blank_lines() throws {
        let text = "{\"a\":1}\r\n\r\n\n{\"b\":2}\n\n"
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0)
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines, [Line(text: "{\"a\":1}", endOffset: 9), Line(text: "{\"b\":2}", endOffset: 20)])
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.committedOffset, Int64(text.utf8.count), "skipped blank lines are consumed")
    }

    func test_lines_across_tiny_chunks() throws {
        let records = (0..<50).map { "{\"index\":\($0),\"text\":\"line \($0) é\"}" }
        let text = records.joined(separator: "\n") + "\n"
        for chunkSize in [1, 2, 3, 7] {
            var reader = JSONLTailReader(
                source: MemoryByteSource(text, maxRead: 5),
                startOffset: 0,
                chunkSize: chunkSize
            )
            let (lines, stats) = try collect(&reader)
            XCTAssertEqual(lines.map(\.text), records, "chunk size \(chunkSize)")
            XCTAssertEqual(stats.committedOffset, Int64(text.utf8.count), "chunk size \(chunkSize)")
            XCTAssertEqual(lines.last?.endOffset, Int64(text.utf8.count))
        }
    }

    func test_cancellation_stops_and_reports() throws {
        let text = (0..<3_000).map { "\($0)" }.joined(separator: "\n") + "\n"
        var checks = 0
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0, chunkSize: 4096) {
            checks += 1
            return true
        }
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.count, 1_024)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(stats.cancelled)
        XCTAssertFalse(stats.reachedEOF)
        XCTAssertEqual(stats.lines, 1_024)
        XCTAssertEqual(stats.committedOffset, lines.last?.endOffset)
    }

    func test_not_cancelled_checks_every_1024_lines() throws {
        let text = (0..<3_000).map { "\($0)" }.joined(separator: "\n") + "\n"
        var checks = 0
        var reader = JSONLTailReader(source: MemoryByteSource(text), startOffset: 0) {
            checks += 1
            return false
        }
        let (lines, stats) = try collect(&reader)

        XCTAssertEqual(lines.count, 3_000)
        XCTAssertEqual(checks, 2)
        XCTAssertFalse(stats.cancelled)
        XCTAssertTrue(stats.reachedEOF)
    }
}
