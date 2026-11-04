import Foundation
import XCTest
@testable import Zentty

/// `GrokTurnTimelineCache` incremental reads and invalidation, `GrokTurnStart.match`, and the
/// source using both across live appends.
final class GrokTurnTimelineTests: XCTestCase {
    private let sessionID = "01a07283-b64e-77b3-b235-8cc132de66ed"

    private var base: URL!
    private var eventsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        eventsURL = base.appendingPathComponent("events.jsonl")
    }

    private func ms(_ iso: String) -> Int64 {
        AgentHistoryTimestamp.milliseconds(iso8601: iso)!
    }

    private func turn(_ number: Int, _ ts: String) throws -> String {
        try AgentHistoryFixtures.grokEvent("turn_started", ts: ts, turnNumber: number)
    }

    private func noise(_ ts: String) throws -> String {
        try AgentHistoryFixtures.grokEvent("phase_changed", ts: ts)
    }

    private func start(_ number: Int, _ ts: String) -> GrokTurnStart {
        GrokTurnStart(turnNumber: number, atMs: ms(ts))
    }

    private func size(_ url: URL) throws -> Int64 {
        try XCTUnwrap(AgentHistoryFileIdentity.stat(path: url.path)).size
    }

    /// Overwrites the file in place, keeping its inode.
    private func overwriteInPlace(_ url: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    // MARK: - Cache

    func test_append_resumes_from_cached_offset() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        try AgentHistoryFixtures.writeJSONL([
            try AgentHistoryFixtures.grokEvent("loop_started", ts: "2026-09-05T17:00:59.000Z"),
            try turn(0, "2026-09-05T17:01:00.000Z"),
            try noise("2026-09-05T17:01:01.000Z"),
        ], to: eventsURL)

        XCTAssertEqual(cache.turns(eventsPath: path), [start(0, "2026-09-05T17:01:00.000Z")])
        XCTAssertEqual(cache.cachedOffset(eventsPath: path), try size(eventsURL))

        try AgentHistoryFixtures.append(
            try noise("2026-09-05T17:02:00.000Z") + "\n" + (try turn(1, "2026-09-05T17:02:30.000Z")) + "\n",
            to: eventsURL
        )
        XCTAssertEqual(cache.turns(eventsPath: path), [
            start(0, "2026-09-05T17:01:00.000Z"),
            start(1, "2026-09-05T17:02:30.000Z"),
        ])
        XCTAssertEqual(cache.cachedOffset(eventsPath: path), try size(eventsURL))
        // Unchanged file: same answer, nothing re-read twice.
        XCTAssertEqual(cache.turns(eventsPath: path).count, 2)
    }

    func test_partial_last_line_read_once_when_completed() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        let first = try turn(0, "2026-09-05T17:01:00.000Z")
        let second = try turn(1, "2026-09-05T17:02:00.000Z")
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        try Data((first + "\n" + second[..<split]).utf8).write(to: eventsURL)

        XCTAssertEqual(cache.turns(eventsPath: path), [start(0, "2026-09-05T17:01:00.000Z")])
        XCTAssertEqual(cache.cachedOffset(eventsPath: path), Int64(first.utf8.count + 1))

        try AgentHistoryFixtures.append(String(second[split...]) + "\n", to: eventsURL)
        let expected = [start(0, "2026-09-05T17:01:00.000Z"), start(1, "2026-09-05T17:02:00.000Z")]
        XCTAssertEqual(cache.turns(eventsPath: path), expected)
        XCTAssertEqual(cache.turns(eventsPath: path), expected)
        XCTAssertEqual(cache.cachedOffset(eventsPath: path), try size(eventsURL))
    }

    func test_truncated_file_rereads_from_start() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        try AgentHistoryFixtures.writeJSONL([
            try turn(0, "2026-09-05T17:01:00.000Z"),
            try noise("2026-09-05T17:01:01.000Z"),
            try turn(1, "2026-09-05T17:02:00.000Z"),
        ], to: eventsURL)
        XCTAssertEqual(cache.turns(eventsPath: path).count, 2)
        let inode = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino

        try overwriteInPlace(eventsURL, lines: [try turn(0, "2026-09-06T09:00:00.000Z")])
        XCTAssertEqual(try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino, inode)

        XCTAssertEqual(cache.turns(eventsPath: path), [start(0, "2026-09-06T09:00:00.000Z")])
    }

    func test_rewritten_prefix_rereads_from_start() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        try AgentHistoryFixtures.writeJSONL([
            try turn(0, "2026-09-05T17:01:00.000Z"),
            try turn(1, "2026-09-05T17:02:00.000Z"),
        ], to: eventsURL)
        XCTAssertEqual(cache.turns(eventsPath: path).count, 2)
        let inode = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino

        // Rewind: same inode, longer file, different bytes before the cached offset.
        try overwriteInPlace(eventsURL, lines: [
            try turn(0, "2026-09-05T18:01:00.000Z"),
            try turn(1, "2026-09-05T18:02:00.000Z"),
            try turn(2, "2026-09-05T18:03:00.000Z"),
        ])
        XCTAssertEqual(try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino, inode)

        XCTAssertEqual(cache.turns(eventsPath: path), [
            start(0, "2026-09-05T18:01:00.000Z"),
            start(1, "2026-09-05T18:02:00.000Z"),
            start(2, "2026-09-05T18:03:00.000Z"),
        ])
    }

    func test_replaced_file_rereads_from_start() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        try AgentHistoryFixtures.writeJSONL([
            try turn(0, "2026-09-05T17:01:00.000Z"),
            try turn(1, "2026-09-05T17:02:00.000Z"),
        ], to: eventsURL)
        XCTAssertEqual(cache.turns(eventsPath: path).count, 2)
        let inode = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino

        let replacement = base.appendingPathComponent("events.jsonl.new")
        try AgentHistoryFixtures.writeJSONL([
            try turn(0, "2026-09-05T19:01:00.000Z"),
            try turn(1, "2026-09-05T19:02:00.000Z"),
            try turn(2, "2026-09-05T19:03:00.000Z"),
        ], to: replacement)
        XCTAssertEqual(rename(replacement.path, path), 0)
        XCTAssertNotEqual(try XCTUnwrap(AgentHistoryFileIdentity.stat(path: path)).ino, inode)

        XCTAssertEqual(cache.turns(eventsPath: path), [
            start(0, "2026-09-05T19:01:00.000Z"),
            start(1, "2026-09-05T19:02:00.000Z"),
            start(2, "2026-09-05T19:03:00.000Z"),
        ])
    }

    func test_deleted_file_returns_empty_and_drops_entry() throws {
        let cache = GrokTurnTimelineCache()
        let path = eventsURL.path
        try AgentHistoryFixtures.writeJSONL([try turn(0, "2026-09-05T17:01:00.000Z")], to: eventsURL)
        XCTAssertEqual(cache.turns(eventsPath: path).count, 1)
        XCTAssertNotNil(cache.cachedOffset(eventsPath: path))

        try FileManager.default.removeItem(at: eventsURL)
        XCTAssertEqual(cache.turns(eventsPath: path), [])
        XCTAssertNil(cache.cachedOffset(eventsPath: path))
    }

    func test_full_cache_evicts_before_adding_a_new_path() throws {
        let cache = GrokTurnTimelineCache()
        var paths: [String] = []
        let line = try turn(0, "2026-09-05T17:01:00.000Z")
        for index in 0...GrokTurnTimelineCache.maxEntries {
            let url = base.appendingPathComponent("events-\(index).jsonl")
            try AgentHistoryFixtures.writeJSONL([line], to: url)
            paths.append(url.path)
        }
        for path in paths.dropLast() {
            XCTAssertEqual(cache.turns(eventsPath: path).count, 1)
        }
        XCTAssertNotNil(cache.cachedOffset(eventsPath: paths[0]))
        // Re-reading a cached path at capacity keeps everything.
        XCTAssertEqual(cache.turns(eventsPath: paths[0]).count, 1)
        XCTAssertNotNil(cache.cachedOffset(eventsPath: paths[GrokTurnTimelineCache.maxEntries - 1]))

        let newest = try XCTUnwrap(paths.last)
        XCTAssertEqual(cache.turns(eventsPath: newest).count, 1)
        XCTAssertNotNil(cache.cachedOffset(eventsPath: newest))
        XCTAssertNil(cache.cachedOffset(eventsPath: paths[0]))
        XCTAssertNil(cache.cachedOffset(eventsPath: paths[GrokTurnTimelineCache.maxEntries - 1]))
        // An evicted path still answers, from the start.
        XCTAssertEqual(cache.turns(eventsPath: paths[0]).count, 1)
    }

    // MARK: - match

    func test_match_without_prompt_index_takes_next_turn_after_last() {
        let turns = [
            GrokTurnStart(turnNumber: 0, atMs: 100),
            GrokTurnStart(turnNumber: 1, atMs: 200),
            GrokTurnStart(turnNumber: 2, atMs: 300),
        ]
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: nil, after: nil), 100)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: nil, after: 100), 200)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: nil, after: 250), 300)
        XCTAssertNil(GrokTurnStart.match(in: turns, promptIndex: nil, after: 300))
    }

    func test_match_repeated_turn_numbers_resolve_in_order() {
        // A resumed session restarts its numbering.
        let turns = [
            GrokTurnStart(turnNumber: 0, atMs: 100),
            GrokTurnStart(turnNumber: 1, atMs: 200),
            GrokTurnStart(turnNumber: 0, atMs: 300),
            GrokTurnStart(turnNumber: 1, atMs: 400),
        ]
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: 0, after: nil), 100)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: 1, after: 100), 200)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: 0, after: 200), 300)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: 1, after: 300), 400)
        XCTAssertNil(GrokTurnStart.match(in: turns, promptIndex: 0, after: 300))
        XCTAssertNil(GrokTurnStart.match(in: turns, promptIndex: 7, after: nil))
    }

    func test_match_never_reuses_an_equal_timestamp() {
        let turns = [
            GrokTurnStart(turnNumber: 0, atMs: 100),
            GrokTurnStart(turnNumber: 1, atMs: 100),
            GrokTurnStart(turnNumber: 1, atMs: 150),
        ]
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: 1, after: 100), 150)
        XCTAssertEqual(GrokTurnStart.match(in: turns, promptIndex: nil, after: 100), 150)
    }
}

// MARK: - Source

extension GrokTurnTimelineTests {
    private func makeSession(chat: [String], events: [String]) throws -> (source: GrokHistorySource, directory: URL) {
        let root = base.appendingPathComponent("grok-home", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let directory = try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: project.path, chat: chat, events: events
        )
        return (AgentHistoryFixtures.grokSource(root: root), directory)
    }

    func test_prompt_without_index_between_numbered_prompts() throws {
        let t0 = "2026-09-05T17:01:00.000Z"
        let t1 = "2026-09-05T17:02:00.000Z"
        let t2 = "2026-09-05T17:03:00.000Z"
        let (source, _) = try makeSession(
            chat: [
                try AgentHistoryFixtures.grokChat("user", text: "first", promptIndex: 0),
                try AgentHistoryFixtures.grokChat("assistant", text: "a"),
                try AgentHistoryFixtures.grokChat("user", text: "follow-up without index"),
                try AgentHistoryFixtures.grokChat("assistant", text: "b"),
                try AgentHistoryFixtures.grokChat("user", text: "third", promptIndex: 2),
                try AgentHistoryFixtures.grokChat("assistant", text: "c"),
            ],
            events: [try turn(0, t0), try turn(1, t1), try turn(2, t2)]
        )

        let batch = try AgentHistoryFixtures.grokIngest(source, id: sessionID)
        XCTAssertEqual(batch.messages.map(\.text), ["first", "a", "follow-up without index", "b", "third", "c"])
        XCTAssertEqual(batch.messages.map(\.atMs), [ms(t0), ms(t0) + 1, ms(t1), ms(t1) + 1, ms(t2), ms(t2) + 1])
    }

    func test_live_append_uses_appended_turn_start() throws {
        let t0 = "2026-09-05T17:01:00.000Z"
        let t1 = "2026-09-05T17:04:00.000Z"
        let (source, directory) = try makeSession(
            chat: [
                try AgentHistoryFixtures.grokChat("user", text: "first", promptIndex: 0),
                try AgentHistoryFixtures.grokChat("assistant", text: "a"),
            ],
            events: [try turn(0, t0), try noise("2026-09-05T17:01:05.000Z")]
        )
        let eventsPath = directory.appendingPathComponent("events.jsonl")
        let first = try AgentHistoryFixtures.grokIngest(source, id: sessionID)
        XCTAssertEqual(first.messages.map(\.atMs), [ms(t0), ms(t0) + 1])
        XCTAssertEqual(source.timelines.cachedOffset(eventsPath: eventsPath.path), try size(eventsPath))

        try AgentHistoryFixtures.append(
            try noise("2026-09-05T17:03:59.000Z") + "\n" + (try turn(1, t1)) + "\n",
            to: eventsPath
        )
        try AgentHistoryFixtures.append(
            try AgentHistoryFixtures.grokChat("user", text: "second", promptIndex: 1) + "\n"
                + (try AgentHistoryFixtures.grokChat("assistant", text: "b")) + "\n",
            to: directory.appendingPathComponent("chat_history.jsonl")
        )

        let second = try AgentHistoryFixtures.grokIngest(source, id: sessionID, cursor: first.cursor)
        XCTAssertTrue(second.replaceContentOf.isEmpty)
        XCTAssertEqual(second.messages.map(\.text), ["second", "b"])
        XCTAssertEqual(second.messages.map(\.seq), [2, 3])
        XCTAssertEqual(second.messages.map(\.atMs), [ms(t1), ms(t1) + 1])
        XCTAssertEqual(source.timelines.cachedOffset(eventsPath: eventsPath.path), try size(eventsPath))
    }
}
