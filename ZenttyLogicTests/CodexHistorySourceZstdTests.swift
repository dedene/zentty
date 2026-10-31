import Foundation
import XCTest
@testable import Zentty

/// Compressed rollouts: messages, decompressed-offset classification and continuation.
final class CodexHistorySourceZstdTests: XCTestCase {
    private typealias C = CodexHistoryFixtures
    private typealias F = AgentHistoryFixtures

    private func conversation(_ id: String, turns: Int, from start: Int64 = 1) -> [String] {
        [C.sessionMeta(id)] + (0 ..< turns).flatMap { index -> [String] in
            let at = start + Int64(index) * 10
            return [C.user("question \(index)", at: at), C.assistant("answer \(index)", at: at + 1)]
        }
    }

    func test_zst_messages() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: conversation(id, turns: 3), compressed: true)
        let unit = try C.unit(source, key: "rollout:" + id)
        XCTAssertEqual(unit.kind, .zstdJSONL)

        let batch = try XCTUnwrap(try C.ingestAll(source, unit: unit).last)
        XCTAssertEqual(batch.messages.map(\.text), ["question 0", "answer 0", "question 1", "answer 1", "question 2", "answer 2"])
        XCTAssertEqual(batch.sessions.first?.title, "question 0")
        let decompressed = Int64(conversation(id, turns: 3).map { $0 + "\n" }.joined().utf8.count)
        XCTAssertEqual(batch.cursor.byteOffset, decompressed, "offsets are decompressed bytes")
        XCTAssertEqual(batch.cursor.fingerprint, ZstdByteSource.fingerprint(path: unit.path, endOffset: decompressed))
        XCTAssertEqual(CodexRolloutState.decode(batch.cursor.adapterState)?.lastKind, .zst)
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: batch.cursor), .unchanged)
    }

    func test_zst_batches_continue_from_cached_stream_and_from_a_fresh_one() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: conversation(id, turns: 40), compressed: true)
        let unit = try C.unit(source, key: "rollout:" + id)
        let batches = try C.ingestAll(source, unit: unit, context: F.context(messageLimit: 7))
        XCTAssertEqual(batches.flatMap(\.messages).count, 80)
        XCTAssertEqual(batches.flatMap(\.messages).map(\.seq), Array(0 ..< 80))
        for batch in batches {
            XCTAssertEqual(batch.cursor.fingerprint, ZstdByteSource.fingerprint(path: unit.path, endOffset: batch.cursor.byteOffset))
        }

        // A resume without the cached stream (e.g. after relaunch) starts a fresh decoder.
        let midway = batches[3].cursor
        source.dropZstdContinuation(key: unit.key)
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: midway), .append(fromOffset: midway.byteOffset, nextSeq: midway.nextSeq),
                       "a cursor that stopped short resumes")
        let resumed = try C.ingestAll(source, unit: unit, cursor: midway, mode: .fromOffset(midway.byteOffset, nextSeq: midway.nextSeq),
                                      context: F.context(messageLimit: 7))
        XCTAssertEqual(resumed.flatMap(\.messages).map(\.text), batches[4...].flatMap(\.messages).map(\.text))
    }

    func test_plain_ingests_and_other_rejects_keep_the_parked_stream() throws {
        let (root, source) = try C.makeRoot(self)
        let backfill = C.newThreadID(), live = C.newThreadID(), otherZst = C.newThreadID(), tombstoned = C.newThreadID()
        try C.writeRollout(root: root, id: backfill, lines: conversation(backfill, turns: 20), compressed: true)
        try C.writeRollout(root: root, id: live, lines: conversation(live, turns: 2))
        try C.writeRollout(root: root, id: otherZst, lines: conversation(otherZst, turns: 20), compressed: true)
        try C.writeRollout(root: root, id: tombstoned, lines: conversation(tombstoned, turns: 2), compressed: true)
        let backfillUnit = try C.unit(source, key: "rollout:" + backfill)
        let context = F.context(messageLimit: 5)

        let first = try source.ingest(unit: backfillUnit, cursor: nil, mode: .fromStart, context: context)
        XCTAssertTrue(first.hasMore)

        // A live append to a plain rollout, a compressed rollout of another thread, and a
        // rejected compressed rollout run between two backfill batches.
        _ = try C.ingestAll(source, unit: try C.unit(source, key: "rollout:" + live), context: context)
        let other = try source.ingest(unit: try C.unit(source, key: "rollout:" + otherZst), cursor: nil, mode: .fromStart, context: context)
        XCTAssertTrue(other.hasMore)
        let admission = AgentHistoryAdmission(exclusions: AgentHistoryExclusionMatcher(folders: []),
                                              tombstones: [AgentHistorySessionKey(agent: .codex, nativeID: tombstoned)])
        let rejected = try source.ingest(unit: try C.unit(source, key: "rollout:" + tombstoned), cursor: nil, mode: .fromStart,
                                         context: F.context(admission: admission))
        XCTAssertEqual(rejected.rejected, [tombstoned: .tombstoned])

        let identity = try XCTUnwrap(backfillUnit.identity)
        let parked = try XCTUnwrap(source.takeZstdContinuation(key: backfillUnit.key, identity: identity, offset: first.cursor.byteOffset),
                                   "the backfill stream survives unrelated ingests")
        source.storeZstdContinuation(parked)
        XCTAssertNotNil(source.takeZstdContinuation(key: "rollout:" + otherZst, identity: try XCTUnwrap(try C.unit(source, key: "rollout:" + otherZst).identity),
                                                    offset: other.cursor.byteOffset), "two compressed streams fit side by side")
    }

    func test_jsonl_to_zst_equal_size_is_identity_only() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let lines = conversation(id, turns: 2)
        let plainURL = try C.writeRollout(root: root, id: id, lines: lines)
        let plain = try C.unit(source, key: "rollout:" + id)
        let cursor = try XCTUnwrap(try C.ingestAll(source, unit: plain).last).cursor
        XCTAssertEqual(CodexRolloutState.decode(cursor.adapterState)?.lastKind, .jsonl)

        // Codex compresses the finished rollout and removes the plain file.
        try C.writeRollout(root: root, id: id, lines: lines, compressed: true)
        try FileManager.default.removeItem(at: plainURL)
        let compressed = try C.unit(source, key: "rollout:" + id)
        XCTAssertEqual(compressed.kind, .zstdJSONL)
        XCTAssertEqual(source.classifyChange(unit: compressed, cursor: cursor), .identityOnly)

        // The indexer then stores the new identity only; the next poll sees nothing new.
        var saved = cursor
        saved.identity = compressed.identity
        XCTAssertEqual(source.classifyChange(unit: compressed, cursor: saved), .unchanged)
    }

    func test_zst_append_and_rewrite_classification_uses_decompressed_offsets() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let lines = conversation(id, turns: 2)
        try C.writeRollout(root: root, id: id, lines: lines, compressed: true)
        let first = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: "rollout:" + id)).last)

        // Appended content (the compressed file is rewritten, so the inode may change).
        try C.writeRollout(root: root, id: id, lines: lines + [C.user("follow-up", at: 500)], compressed: true)
        var unit = try C.unit(source, key: "rollout:" + id)
        XCTAssertNotEqual(unit.identity?.size, first.cursor.byteOffset, "compressed and decompressed sizes differ")
        let change = source.classifyChange(unit: unit, cursor: first.cursor)
        XCTAssertEqual(change, .append(fromOffset: first.cursor.byteOffset, nextSeq: first.cursor.nextSeq))
        let appended = try source.ingest(unit: unit, cursor: first.cursor,
                                         mode: .fromOffset(first.cursor.byteOffset, nextSeq: first.cursor.nextSeq), context: F.context())
        XCTAssertEqual(appended.messages.map(\.text), ["follow-up"])
        XCTAssertEqual(appended.messages.map(\.seq), [4])

        // Different history before the offset → rewrite.
        var edited = lines
        edited[1] = C.user("QUESTION 0", at: 1)
        try C.writeRollout(root: root, id: id, lines: edited + [C.user("follow-up", at: 500)], compressed: true)
        unit = try C.unit(source, key: "rollout:" + id)
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: appended.cursor), .rewrite)

        // Shorter content than the offset → rewrite.
        try C.writeRollout(root: root, id: id, lines: [C.sessionMeta(id)], compressed: true)
        unit = try C.unit(source, key: "rollout:" + id)
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: appended.cursor), .rewrite)
    }

    func test_window_recording_source_fingerprints_recent_bytes_only() throws {
        final class ArraySource: AgentHistoryByteSource {
            var bytes: [UInt8]
            init(_ bytes: [UInt8]) { self.bytes = bytes }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                let count = min(buffer.count, bytes.count)
                buffer.copyBytes(from: bytes.prefix(count))
                bytes.removeFirst(count)
                return count
            }
        }
        let content = (0 ..< 20_000).map { UInt8($0 % 251) }
        let window = CodexWindowRecordingSource(base: ArraySource(content), startOffset: 0, capacity: 8_192)
        try window.discard(5_000)
        XCTAssertEqual(window.fingerprint(endOffset: 5_000), AgentHistoryFileFingerprint.hash(content[904 ..< 5_000]))
        var buffer = [UInt8](repeating: 0, count: 3_000)
        _ = try buffer.withUnsafeMutableBytes { try window.read(into: $0) }
        XCTAssertEqual(window.fingerprint(endOffset: 8_000), AgentHistoryFileFingerprint.hash(content[3_904 ..< 8_000]))
        XCTAssertEqual(window.fingerprint(endOffset: 100), AgentHistoryFileFingerprint.hash(content[0 ..< 100]))
        var large = [UInt8](repeating: 0, count: 10_000)
        _ = try large.withUnsafeMutableBytes { try window.read(into: $0) }
        XCTAssertNil(window.fingerprint(endOffset: 8_000), "evicted")
        XCTAssertEqual(window.fingerprint(endOffset: 18_000), AgentHistoryFileFingerprint.hash(content[13_904 ..< 18_000]))
        XCTAssertNil(window.fingerprint(endOffset: 18_001), "not read yet")
    }
}
