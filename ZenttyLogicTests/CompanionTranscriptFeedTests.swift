import XCTest

@testable import Zentty

/// Unit tests for `CompanionTranscriptFeed`: path resolution through the source
/// seam, bounded snapshots, tail-driven deltas, and the unavailable reasons
/// (no adapter, missing file, session-ended rotation). The `DispatchSource` file
/// watch is replaced by a manually-fired watcher so events are deterministic;
/// the transcript files themselves are real temp-dir files.
@MainActor
final class CompanionTranscriptFeedTests: XCTestCase {
    // MARK: - Test doubles

    private final class FakeTranscriptSource: CompanionTranscriptSourceProviding {
        var targets: [String: CompanionTranscriptTarget] = [:]
        func companionTranscriptTarget(forPaneId paneId: String) -> CompanionTranscriptTarget? {
            targets[paneId]
        }
    }

    private final class ManualWatch: CompanionTranscriptFileWatch {
        var onEvent: (@MainActor (CompanionTranscriptFileEvent) -> Void)?
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    // MARK: - Fixture

    private var tempDir: URL!
    private var source: FakeTranscriptSource!
    /// The most recently created watch, so a test can fire its events.
    private var lastWatch: ManualWatch!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        source = FakeTranscriptSource()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeFeed(snapshotLimit: Int = CompanionTranscriptFeed.defaultSnapshotLimit) -> CompanionTranscriptFeed {
        CompanionTranscriptFeed(
            source: source,
            snapshotLimit: snapshotLimit,
            watcherFactory: { [weak self] _, onEvent in
                let watch = ManualWatch()
                watch.onEvent = onEvent
                self?.lastWatch = watch
                return watch
            }
        )
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func userLine(_ uuid: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-07-20T00:00:00.000Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func claudeTarget(url: URL) -> CompanionTranscriptTarget {
        CompanionTranscriptTarget(
            tool: .claudeCode,
            sessionID: "sess-1",
            workingDirectory: "/tmp/project",
            liveTranscriptPath: url.path
        )
    }

    // MARK: - Snapshot

    func testSubscribeReturnsSnapshotFromFile() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello"), userLine("u2", "world")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        let token = feed.addSubscriber { _ in }
        guard case .snapshot(let snapshot) = feed.subscribe(token: token, paneId: "p1") else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertEqual(snapshot.paneId, "p1")
        XCTAssertEqual(snapshot.sessionId, "sess-1")
        XCTAssertFalse(snapshot.truncated)
        XCTAssertEqual(snapshot.entries.compactMap(\.text), ["hello", "world"])
    }

    func testSnapshotIsBoundedAndFlagsTruncation() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines((0..<5).map { userLine("u\($0)", "line\($0)") }, to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed(snapshotLimit: 2)
        let token = feed.addSubscriber { _ in }
        guard case .snapshot(let snapshot) = feed.subscribe(token: token, paneId: "p1") else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertTrue(snapshot.truncated)
        // Only the last `snapshotLimit` entries survive.
        XCTAssertEqual(snapshot.entries.compactMap(\.text), ["line3", "line4"])
    }

    // MARK: - Deltas

    func testAppendAfterSubscribeEmitsDelta() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        var events: [CompanionTranscriptEvent] = []
        let token = feed.addSubscriber { events.append($0) }
        _ = feed.subscribe(token: token, paneId: "p1")

        try appendLine(userLine("u2", "world"), to: url)
        lastWatch.onEvent?(.changed)

        XCTAssertEqual(events.count, 1)
        guard case .delta(let delta) = events.first else {
            return XCTFail("Expected a delta")
        }
        XCTAssertEqual(delta.paneId, "p1")
        // Only the appended line is in the delta, not the snapshotted one.
        XCTAssertEqual(delta.entries.compactMap(\.text), ["world"])
    }

    func testDeltaFanOutToMultipleSubscribers() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        var firstEvents: [CompanionTranscriptEvent] = []
        var secondEvents: [CompanionTranscriptEvent] = []
        let firstToken = feed.addSubscriber { firstEvents.append($0) }
        let secondToken = feed.addSubscriber { secondEvents.append($0) }
        _ = feed.subscribe(token: firstToken, paneId: "p1")
        _ = feed.subscribe(token: secondToken, paneId: "p1")

        try appendLine(userLine("u2", "world"), to: url)
        lastWatch.onEvent?(.changed)

        XCTAssertEqual(firstEvents.count, 1)
        XCTAssertEqual(secondEvents.count, 1)
    }

    // MARK: - Unavailable reasons

    func testNoTargetYieldsNoAdapter() {
        let feed = makeFeed()
        let token = feed.addSubscriber { _ in }
        guard case .unavailable(let unavailable) = feed.subscribe(token: token, paneId: "ghost") else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(unavailable.reason, .noAdapter)
    }

    func testToolWithoutAdapterYieldsNoAdapter() {
        source.targets["p1"] = CompanionTranscriptTarget(
            tool: .codex,
            sessionID: "s",
            workingDirectory: "/tmp/project",
            liveTranscriptPath: nil
        )
        let feed = makeFeed()
        let token = feed.addSubscriber { _ in }
        guard case .unavailable(let unavailable) = feed.subscribe(token: token, paneId: "p1") else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(unavailable.reason, .noAdapter)
    }

    func testMissingFileYieldsFileMissing() {
        let url = tempDir.appendingPathComponent("does-not-exist.jsonl")
        source.targets["p1"] = claudeTarget(url: url)
        let feed = makeFeed()
        let token = feed.addSubscriber { _ in }
        guard case .unavailable(let unavailable) = feed.subscribe(token: token, paneId: "p1") else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(unavailable.reason, .fileMissing)
    }

    // MARK: - Rotation

    func testFileVanishedEmitsSessionEnded() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        var events: [CompanionTranscriptEvent] = []
        let token = feed.addSubscriber { events.append($0) }
        _ = feed.subscribe(token: token, paneId: "p1")

        // Rotation: the watched file is deleted/renamed under us.
        lastWatch.onEvent?(.vanished)

        XCTAssertEqual(events.count, 1)
        guard case .unavailable(let unavailable) = events.first else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(unavailable.reason, .sessionEnded)
        XCTAssertTrue(lastWatch.cancelled)
    }

    // MARK: - Teardown

    func testDisconnectCancelsWatchWhenLastSubscriberLeaves() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        let token = feed.addSubscriber { _ in }
        _ = feed.subscribe(token: token, paneId: "p1")
        XCTAssertFalse(lastWatch.cancelled)

        feed.removeSubscriber(token)
        XCTAssertTrue(lastWatch.cancelled)
    }

    func testPaneClosedStopsTailing() throws {
        let url = tempDir.appendingPathComponent("s.jsonl")
        try writeLines([userLine("u1", "hello")], to: url)
        source.targets["p1"] = claudeTarget(url: url)

        let feed = makeFeed()
        var events: [CompanionTranscriptEvent] = []
        let token = feed.addSubscriber { events.append($0) }
        _ = feed.subscribe(token: token, paneId: "p1")

        feed.handlePaneClosed(paneId: "p1")
        XCTAssertTrue(lastWatch.cancelled)

        // A late file event after close is ignored (tail is gone).
        try appendLine(userLine("u2", "world"), to: url)
        lastWatch.onEvent?(.changed)
        XCTAssertTrue(events.isEmpty)
    }
}
