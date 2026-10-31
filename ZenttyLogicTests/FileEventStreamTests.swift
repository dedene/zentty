import CoreServices
import Foundation
import XCTest
@testable import Zentty

final class FileEventStreamTests: XCTestCase {
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.tests.file-event-stream")

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-event-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStream(
        watching path: String,
        latency: TimeInterval = 0.05,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> FileEventStream {
        let stream = FileEventStream(paths: [path], latency: latency, queue: queue, handler: handler)
        addTeardownBlock { [queue] in queue.sync { stream.stop() } }
        return stream
    }

    private func start(_ stream: FileEventStream) {
        let started = queue.sync { stream.start() }
        XCTAssertTrue(started)
    }

    /// Runs `body` shortly after the stream started so the write is not racing stream creation.
    private func afterStart(_ body: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: body)
    }

    private static func append(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    // MARK: - Paths and flags

    func test_canonicalPath_keeps_private_prefix_for_temporary_directory() throws {
        let directory = try makeDirectory()
        let canonical = FileEventStream.canonicalPath(directory.path + "/")
        XCTAssertTrue(canonical.hasPrefix("/private/"), canonical)
        XCTAssertFalse(canonical.hasSuffix("/"))
        XCTAssertTrue(canonical.hasSuffix(directory.lastPathComponent))

        let missing = FileEventStream.canonicalPath(directory.path + "/not-yet/created.jsonl")
        XCTAssertEqual(missing, canonical + "/not-yet/created.jsonl")
        XCTAssertEqual(FileEventStream.canonicalPath("/"), "/")

        let stream = FileEventStream(paths: [directory.path, directory.path + "/", ""], queue: queue) { _ in }
        XCTAssertEqual(stream.watchedPaths, [canonical])
    }

    func test_flags_requiringRescan_and_isDropped() {
        let rescanOnly: [FileEventFlags] = [.mustScanSubDirs, .rootChanged, .mount, .unmount]
        for flag in rescanOnly {
            XCTAssertTrue(flag.requiresRescan, "\(flag.rawValue)")
            XCTAssertFalse(flag.isDropped, "\(flag.rawValue)")
        }
        for flag in [FileEventFlags.userDropped, .kernelDropped] {
            XCTAssertTrue(flag.requiresRescan)
            XCTAssertTrue(flag.isDropped)
        }
        let itemEvent: FileEventFlags = [.itemCreated, .itemModified, .itemIsFile, .itemRenamed, .itemRemoved]
        XCTAssertFalse(itemEvent.requiresRescan)
        XCTAssertFalse(itemEvent.isDropped)
        XCTAssertFalse(FileEventFlags.historyDone.requiresRescan)

        let raw = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        XCTAssertEqual(FileEventFlags(fsEventFlags: raw), [.itemModified, .itemIsFile])
    }

    // MARK: - Live stream

    func test_reports_file_level_event_when_file_is_appended() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: file)
        let expectedPath = FileEventStream.canonicalPath(file.path)

        // The initial write may still be delivered after start; only events seen once the append
        // is armed count, so the test proves the append itself is reported.
        let armed = ArmedFlag()
        let modified = expectation(description: "modified event")
        modified.assertForOverFulfill = false
        let stream = makeStream(watching: directory.path) { events in
            guard armed.isArmed else {
                return
            }
            if events.contains(where: { $0.path == expectedPath && $0.flags.contains(.itemModified) && $0.flags.contains(.itemIsFile) }) {
                modified.fulfill()
            }
        }
        start(stream)
        afterStart { [queue] in
            queue.sync { armed.arm() }
            Self.append("{\"b\":2}\n", to: file)
        }

        wait(for: [modified], timeout: 5)
    }

    func test_reports_removed_file() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("gone.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let expectedPath = FileEventStream.canonicalPath(file.path)

        let removed = expectation(description: "removed event")
        removed.assertForOverFulfill = false
        let stream = makeStream(watching: directory.path) { events in
            if events.contains(where: { $0.path == expectedPath && $0.flags.contains(.itemRemoved) }) {
                removed.fulfill()
            }
        }
        start(stream)
        afterStart { try? FileManager.default.removeItem(at: file) }

        wait(for: [removed], timeout: 5)
    }

    func test_reports_rootChanged_when_watched_root_is_removed() throws {
        let parent = try makeDirectory()
        let root = parent.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let rootChanged = expectation(description: "rootChanged event")
        rootChanged.assertForOverFulfill = false
        let stream = makeStream(watching: root.path) { events in
            if events.contains(where: { $0.flags.contains(.rootChanged) && $0.flags.requiresRescan }) {
                rootChanged.fulfill()
            }
        }
        start(stream)
        afterStart { try? FileManager.default.removeItem(at: root) }

        wait(for: [rootChanged], timeout: 5)
    }

    func test_stop_delivers_no_further_events() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("late.jsonl")
        let expectedPath = FileEventStream.canonicalPath(file.path)

        let delivered = expectation(description: "no event after stop")
        delivered.isInverted = true
        let stream = makeStream(watching: directory.path) { events in
            if events.contains(where: { $0.path == expectedPath }) {
                delivered.fulfill()
            }
        }
        start(stream)
        queue.sync { stream.stop() }
        XCTAssertFalse(stream.isRunning)
        queue.sync { stream.stop() }

        try Data("{}\n".utf8).write(to: file)
        Self.append("{}\n", to: file)

        wait(for: [delivered], timeout: 1)
    }
}

private final class ArmedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }
}
