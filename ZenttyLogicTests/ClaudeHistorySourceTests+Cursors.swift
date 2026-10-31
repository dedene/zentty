import Foundation
import XCTest
@testable import Zentty

/// Batching, cursors, admission and robustness tests of `ClaudeHistorySource`
/// (helpers live in `ClaudeHistorySourceTests.swift`).
extension ClaudeHistorySourceTests {
    // MARK: - Batching and cursors

    func test_batch_limit_has_more_resumable() throws {
        let fixture = try makeFixture()
        let url = try writeTranscript((0..<5).map { try! F.claudeUser("prompt \($0)", atMs: t + Int64($0)) }, in: fixture)
        let size = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: url.path)).size

        let batches = try ingestAll(fixture, unit: try unit(fixture), context: context(messageLimit: 2))
        XCTAssertEqual(batches.map(\.messages.count), [2, 2, 1])
        XCTAssertEqual(batches.map(\.hasMore), [true, true, false])
        XCTAssertEqual(batches.flatMap(\.messages).map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(batches.flatMap(\.messages).map(\.text), (0..<5).map { "prompt \($0)" })
        let offsets = batches.map(\.cursor.byteOffset)
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertEqual(offsets.last, size)
        XCTAssertEqual(batches.map(\.replaceContentOf), [[id], [], []])

        // Byte cap: every line exceeds a 1-byte budget, so each batch holds one line.
        let byBytes = try ingestAll(fixture, unit: try unit(fixture), context: context(sourceBytes: 1))
        XCTAssertEqual(byBytes.map(\.messages.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(byBytes.last?.cursor.byteOffset, size)
    }

    func test_incremental_seq_offset_and_cursor_fingerprint() throws {
        let fixture = try makeFixture()
        let url = try writeTranscript([try F.claudeUser("one", atMs: t), try F.claudeAssistant([F.claudeTextPart("two")], atMs: t + 1)], in: fixture)
        let first = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).last)
        let identity = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: url.path))
        XCTAssertEqual(first.cursor.identity, identity)
        XCTAssertEqual(first.cursor.byteOffset, identity.size)
        XCTAssertEqual(first.cursor.nextSeq, 2)
        XCTAssertEqual(first.cursor.unitKey, id)
        XCTAssertEqual(first.cursor.fingerprint, AgentHistoryFileFingerprint.compute(path: url.path, endOffset: identity.size))
        XCTAssertFalse(first.cursor.isRejected)
        XCTAssertEqual(fixture.source.classifyChange(unit: try unit(fixture), cursor: first.cursor), .unchanged)

        try F.append(try F.claudeUser("three", atMs: t + 2) + "\n" + "{\"type\":\"user\",\"mess", to: url)
        let grown = try unit(fixture)
        let change = fixture.source.classifyChange(unit: grown, cursor: first.cursor)
        XCTAssertEqual(change, .append(fromOffset: identity.size, nextSeq: 2))

        let next = try fixture.source.ingest(unit: grown, cursor: first.cursor,
                                             mode: .fromOffset(identity.size, nextSeq: 2), context: context())
        XCTAssertEqual(next.messages.map(\.seq), [2])
        XCTAssertEqual(next.messages.map(\.text), ["three"])
        XCTAssertEqual(next.replaceContentOf, [])
        XCTAssertEqual(next.sessions.first?.cwd, AgentHistoryPath.canonical(F.claudeCwd), "cwd carried in adapterState")
        XCTAssertLessThan(next.cursor.byteOffset, try XCTUnwrap(grown.identity).size, "the partial trailing line waits")
        XCTAssertEqual(next.cursor.nextSeq, 3)
        XCTAssertFalse(next.hasMore)
    }

    func test_truncation_classifies_rewrite() throws {
        let fixture = try makeFixture()
        let url = try writeTranscript([try F.claudeUser("long original prompt", atMs: t),
                                       try F.claudeAssistant([F.claudeTextPart("reply")], atMs: t + 1)], in: fixture)
        let first = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).last)

        // Rewritten in place, shorter: same inode, size below the cursor.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((try F.claudeUser("compacted", atMs: t + 5) + "\n").utf8))
        try handle.close()
        let rewritten = try unit(fixture)
        XCTAssertEqual(rewritten.identity?.ino, first.cursor.identity?.ino)
        XCTAssertEqual(fixture.source.classifyChange(unit: rewritten, cursor: first.cursor), .rewrite)

        let again = try fixture.source.ingest(unit: rewritten, cursor: first.cursor, mode: .fromStart, context: context())
        XCTAssertEqual(again.replaceContentOf, [id])
        XCTAssertEqual(again.messages.map(\.seq), [0])
        XCTAssertEqual(again.messages.map(\.text), ["compacted"])
    }

    // MARK: - Admission

    func test_excluded_stores_nothing_and_rejects() throws {
        let fixture = try makeFixture()
        let url = try writeTranscript([try F.claudeUser("private work", atMs: t),
                                       try F.claudeTitle("custom-title", "Private")], in: fixture)
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/Users/example/dev"]),
            tombstones: []
        )
        let batch = try fixture.source.ingest(unit: try unit(fixture), cursor: nil, mode: .fromStart,
                                              context: context(admission: admission))
        XCTAssertEqual(batch.sessions, [])
        XCTAssertEqual(batch.messages, [])
        XCTAssertEqual(batch.artifacts, [])
        XCTAssertEqual(batch.rejected, [id: .excludedFolder])
        XCTAssertEqual(batch.removedNativeIDs, [id])
        XCTAssertEqual(batch.diagnostics.skippedSessions[id], .excluded)
        XCTAssertFalse(batch.hasMore)
        XCTAssertEqual(batch.cursor.identity, AgentHistoryFileIdentity.stat(path: url.path))
    }

    func test_tombstoned_nothing() throws {
        let fixture = try makeFixture()
        try writeTranscript([try F.claudeUser("removed session", atMs: t)], in: fixture)
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            tombstones: [AgentHistorySessionKey(agent: .claude, nativeID: id)]
        )
        let batch = try fixture.source.ingest(unit: try unit(fixture), cursor: nil, mode: .fromStart,
                                              context: context(admission: admission))
        XCTAssertEqual(batch.sessions, [])
        XCTAssertEqual(batch.messages, [])
        XCTAssertEqual(batch.rejected, [id: .tombstoned])
        XCTAssertEqual(batch.diagnostics.skippedSessions[id], .tombstoned)
    }

    // MARK: - Robustness

    func test_malformed_oversized_counted() throws {
        let fixture = try makeFixture()
        let huge = try F.claudeUser(String(repeating: "x", count: JSONLTailReader.defaultMaxLineBytes + 10), atMs: t)
        try writeTranscript([
            "not json at all",
            "{\"type\":\"user\",\"message\":{\"content\":",
            huge,
            try F.claudeUser("survivor", atMs: t + 1),
        ], in: fixture)
        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        XCTAssertEqual(batch.messages.map(\.text), ["survivor"])
        XCTAssertEqual(batch.diagnostics.malformedLines, 2)
        XCTAssertEqual(batch.diagnostics.oversizedLines, 1)
    }

    func test_redacts_messages_commands() throws {
        let fixture = try makeFixture()
        let token = F.fakeGitHubToken()
        let key = F.fakeOpenAIKey()
        try writeTranscript([
            try F.claudeUser("use \(token) to push", atMs: t),
            try F.claudeAssistant([
                F.claudeTextPart("Setting OPENAI_API_KEY=\(key)"),
                F.claudeToolUse("Bash", input: ["command": "curl -H 'Authorization: Bearer \(key)' https://api.example.com"]),
            ], atMs: t + 1),
            try F.claudeUser("<bash-input>export GH=\(token)</bash-input>", atMs: t + 2),
        ], in: fixture)
        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        let stored = batch.messages.map(\.text) + batch.messages.map(\.searchText) + batch.artifacts.map(\.value)
            + [batch.sessions.first?.title ?? ""]
        XCTAssertFalse(stored.contains { $0.contains(token) || $0.contains(key) })
        XCTAssertTrue(batch.messages[0].text.contains(AgentHistoryRedactor.replacement))
        XCTAssertEqual(artifacts([batch], .command).count, 2)
        XCTAssertTrue(artifacts([batch], .command).allSatisfy { $0.contains(AgentHistoryRedactor.replacement) })
    }

    func test_cancellation_mid_file() throws {
        let fixture = try makeFixture()
        var lines = [try F.claudeUser("start", atMs: t)]
        let noise = try F.jsonLine(["type": "progress", "data": ["n": 1]])
        lines += Array(repeating: noise, count: JSONLTailReader.cancellationCheckInterval + 50)
        lines.append(try F.claudeUser("end", atMs: t + 1))
        try writeTranscript(lines, in: fixture)

        XCTAssertThrowsError(try fixture.source.ingest(
            unit: try unit(fixture), cursor: nil, mode: .fromStart, context: context(isCancelled: { true })
        )) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
