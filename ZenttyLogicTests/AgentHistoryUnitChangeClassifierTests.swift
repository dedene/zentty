import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryUnitChangeClassifierTests: XCTestCase {
    private func identity(dev: Int64 = 1, ino: Int64 = 10, size: Int64, mtimeNs: Int64 = 1_000) -> AgentHistoryFileIdentity {
        AgentHistoryFileIdentity(dev: dev, ino: ino, size: size, mtimeNs: mtimeNs)
    }

    private func cursor(
        identity: AgentHistoryFileIdentity?,
        byteOffset: Int64,
        nextSeq: Int = 4,
        fingerprint: Int64? = 42,
        isRejected: Bool = false
    ) -> AgentHistoryCursor {
        AgentHistoryCursor(
            sourceID: 1,
            unitKey: "unit",
            identity: identity,
            byteOffset: byteOffset,
            nextSeq: nextSeq,
            fingerprint: fingerprint,
            isRejected: isRejected
        )
    }

    private func classify(
        _ cursor: AgentHistoryCursor?,
        _ current: AgentHistoryFileIdentity?,
        fingerprint: Int64? = 42
    ) -> AgentHistoryUnitChange {
        AgentHistoryUnitChangeClassifier.classify(cursor: cursor, current: current) { fingerprint }
    }

    func test_no_cursor_is_new() {
        XCTAssertEqual(classify(nil, identity(size: 100)), .new)
        XCTAssertEqual(classify(nil, nil), .new)
    }

    func test_missing_file_with_cursor_is_missing() {
        XCTAssertEqual(classify(cursor(identity: identity(size: 100), byteOffset: 100), nil), .missing)
    }

    func test_grown_same_inode_appends_from_offset() {
        let stored = identity(size: 100, mtimeNs: 1_000)
        let change = classify(cursor(identity: stored, byteOffset: 100, nextSeq: 7), identity(size: 180, mtimeNs: 2_000))
        XCTAssertEqual(change, .append(fromOffset: 100, nextSeq: 7))
    }

    func test_same_size_and_mtime_is_unchanged() {
        var fingerprintCalls = 0
        let stored = identity(size: 100)
        let change = AgentHistoryUnitChangeClassifier.classify(
            cursor: cursor(identity: stored, byteOffset: 100),
            current: stored
        ) {
            fingerprintCalls += 1
            return 0
        }
        XCTAssertEqual(change, .unchanged)
        XCTAssertEqual(fingerprintCalls, 0, "unchanged files are never read")
    }

    func test_partially_read_unchanged_file_resumes_from_offset() {
        // Batch 1 of a large file was committed (cursor short of the stat'ed size) and the
        // continuation was lost on quit: the file must resume, not be treated as done.
        let stored = identity(size: 10_000_000, mtimeNs: 1_000)
        let change = classify(cursor(identity: stored, byteOffset: 8_000_000, nextSeq: 500), stored)
        XCTAssertEqual(change, .append(fromOffset: 8_000_000, nextSeq: 500))

        // The bytes before the offset changed under the same identity: still a rewrite.
        XCTAssertEqual(
            classify(cursor(identity: stored, byteOffset: 8_000_000, nextSeq: 500), stored, fingerprint: 7),
            .rewrite
        )
    }

    func test_same_size_new_mtime_is_zero_byte_append() {
        let stored = identity(size: 100, mtimeNs: 1_000)
        let change = classify(cursor(identity: stored, byteOffset: 100, nextSeq: 3), identity(size: 100, mtimeNs: 5_000))
        XCTAssertEqual(change, .append(fromOffset: 100, nextSeq: 3))
    }

    func test_truncated_file_is_rewrite() {
        let stored = identity(size: 100)
        XCTAssertEqual(classify(cursor(identity: stored, byteOffset: 100), identity(size: 40, mtimeNs: 2_000)), .rewrite)
    }

    func test_replaced_inode_is_rewrite() {
        let stored = identity(ino: 10, size: 100)
        XCTAssertEqual(classify(cursor(identity: stored, byteOffset: 100), identity(ino: 11, size: 200)), .rewrite)
        XCTAssertEqual(classify(cursor(identity: stored, byteOffset: 100), identity(dev: 2, ino: 10, size: 200)), .rewrite)
        XCTAssertEqual(classify(cursor(identity: nil, byteOffset: 100), identity(size: 200)), .rewrite)
    }

    func test_truncate_then_regrow_past_offset_is_rewrite_via_fingerprint() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("unit.jsonl")
        try AgentHistoryFixtures.writeJSONL([#"{"type":"user","n":1}"#, #"{"type":"user","n":2}"#], to: file)

        let before = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: file.path))
        let saved = cursor(
            identity: before,
            byteOffset: before.size,
            fingerprint: AgentHistoryFileFingerprint.compute(path: file.path, endOffset: before.size)
        )

        // Same inode, rewritten from scratch with different, longer content.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try AgentHistoryFixtures.append(
            #"{"type":"user","n":9}"# + "\n" + #"{"type":"assistant","n":10}"# + "\n" + #"{"type":"user","n":11}"# + "\n",
            to: file
        )
        try AgentHistoryFixtures.setModificationDate(Date(timeIntervalSinceNow: 60), of: file)
        let after = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: file.path))
        XCTAssertEqual(after.ino, before.ino)
        XCTAssertGreaterThan(after.size, before.size)

        let unit = AgentHistoryUnit(key: "unit", path: file.path, kind: .jsonl, identity: after, nativeSessionID: nil)
        XCTAssertEqual(ClassifierProbeSource().classifyChange(unit: unit, cursor: saved), .rewrite)

        // A genuine append keeps the window and classifies as append.
        let appendSaved = cursor(
            identity: after,
            byteOffset: after.size,
            nextSeq: 2,
            fingerprint: AgentHistoryFileFingerprint.compute(path: file.path, endOffset: after.size)
        )
        try AgentHistoryFixtures.append(#"{"type":"user","n":12}"# + "\n", to: file)
        try AgentHistoryFixtures.setModificationDate(Date(timeIntervalSinceNow: 120), of: file)
        let grown = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: file.path))
        let grownUnit = AgentHistoryUnit(key: "unit", path: file.path, kind: .jsonl, identity: grown, nativeSessionID: nil)
        XCTAssertEqual(
            ClassifierProbeSource().classifyChange(unit: grownUnit, cursor: appendSaved),
            .append(fromOffset: after.size, nextSeq: 2)
        )
    }

    func test_rejected_cursor_same_inode_stays_unchanged() {
        let stored = identity(size: 100)
        let rejected = cursor(identity: stored, byteOffset: 0, isRejected: true)
        XCTAssertEqual(classify(rejected, identity(size: 500, mtimeNs: 9_000), fingerprint: nil), .unchanged)
    }

    func test_rejected_cursor_new_inode_is_new() {
        let rejected = cursor(identity: identity(ino: 10, size: 100), byteOffset: 0, isRejected: true)
        XCTAssertEqual(classify(rejected, identity(ino: 99, size: 100)), .new)
        XCTAssertEqual(classify(cursor(identity: nil, byteOffset: 0, isRejected: true), identity(size: 1)), .new)
    }

    func test_fingerprint_is_stable_and_detects_changed_prefix() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("unit.jsonl")
        let body = String(repeating: "abcdefghij", count: 1_000) // 10,000 bytes
        try Data(body.utf8).write(to: file)

        let first = AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 10_000)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 10_000))
        XCTAssertEqual(
            first,
            AgentHistoryFileFingerprint.hash(Array(body.utf8)[(10_000 - AgentHistoryFileFingerprint.windowBytes)..<10_000])
        )
        XCTAssertEqual(
            AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 100),
            AgentHistoryFileFingerprint.hash(Array(body.utf8)[0..<100]),
            "short offsets hash the whole prefix"
        )
        XCTAssertNil(AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 20_000), "file shorter than offset")
        XCTAssertNil(AgentHistoryFileFingerprint.compute(path: directory.appendingPathComponent("nope").path, endOffset: 10))

        // A byte change inside the window changes the hash; one before it does not.
        var bytes = Array(body.utf8)
        bytes[9_000] = UInt8(ascii: "Z")
        try Data(bytes).write(to: file)
        XCTAssertNotEqual(first, AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 10_000))

        var outside = Array(body.utf8)
        outside[10] = UInt8(ascii: "Z")
        try Data(outside).write(to: file)
        XCTAssertEqual(first, AgentHistoryFileFingerprint.compute(path: file.path, endOffset: 10_000))
    }
}

/// A source that relies on the protocol's default `classifyChange`.
private final class ClassifierProbeSource: AgentHistorySource {
    let agent = AgentHistoryAgent.claude
    let root = AgentHistorySourceRoot(agent: .claude, path: "/tmp/probe", isDefault: true)
    let adapterVersion = 1
    let watchPaths: [String] = []

    func discoverUnits() throws -> [AgentHistoryUnit] { [] }
    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? { nil }
    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        AgentHistoryIngestBatch(cursor: cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key), hasMore: false)
    }
    func estimatedSessionCount() -> Int? { nil }
}
