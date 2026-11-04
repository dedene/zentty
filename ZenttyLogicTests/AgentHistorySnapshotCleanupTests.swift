import Foundation
import XCTest
@testable import Zentty

/// Private copies of another agent's database (`readExternalSnapshot` on a `-wal` without
/// `-shm`) hold raw conversation text. They live in `AgentHistory/snapshots/`, so Delete Index
/// removes them with the rest, and leftovers from a crash are swept when the index next opens.
final class AgentHistorySnapshotCleanupTests: XCTestCase {
    private let fileManager = FileManager.default

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    /// A snapshot directory as a crash mid-read leaves it: a copy of the database and its `-wal`.
    @discardableResult
    private func makeLeftoverSnapshot(in paths: AgentHistoryPaths, suffix: String = "AbC123") throws -> URL {
        let directory = paths.directoryURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("zentty-agent-history-read.\(suffix)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("raw conversation".utf8).write(to: directory.appendingPathComponent("snapshot.sqlite"))
        try Data("raw wal".utf8).write(to: directory.appendingPathComponent("snapshot.sqlite-wal"))
        return directory
    }

    /// A WAL database with commits only in `-wal` and no `-shm` beside it, at `url`.
    private func makeWALDatabaseWithoutSHM(at url: URL, schema: String, in scratch: URL) throws {
        let writerDirectory = scratch.appendingPathComponent("writer-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: writerDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AgentHistoryDatabase(url: writerDirectory.appendingPathComponent("db.sqlite"),
                                              mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        defer { writer.close() }
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute(schema)
        try fileManager.copyItem(at: writer.url, to: url)
        try fileManager.copyItem(at: URL(fileURLWithPath: writer.url.path + "-wal"),
                                 to: URL(fileURLWithPath: url.path + "-wal"))
        XCTAssertFalse(fileManager.fileExists(atPath: url.path + "-shm"))
    }

    // MARK: - Where copies go

    func test_index_snapshot_policy_copies_inside_the_index_directory_and_removes_the_copy() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.storage.ensureDirectory()
        let scratch = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let url = scratch.appendingPathComponent("agent/state_5.sqlite")
        try makeWALDatabaseWithoutSHM(at: url, schema: "CREATE TABLE threads(id TEXT PRIMARY KEY)", in: scratch)
        let snapshots = index.paths.snapshotsDirectoryURL
        XCTAssertEqual(snapshots, index.paths.directoryURL.appendingPathComponent("snapshots", isDirectory: true))

        var duringRead: [String] = []
        try AgentHistoryDatabase.readExternalSnapshot(url: url, copyPolicy: .index(index.paths)) { database in
            duringRead = try self.fileManager.contentsOfDirectory(atPath: snapshots.path)
            XCTAssertEqual(database.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                           snapshots.standardizedFileURL)
        }

        XCTAssertEqual(duringRead.count, 1)
        XCTAssertTrue(duringRead.first?.hasPrefix("zentty-agent-history-read.") ?? false)
        XCTAssertEqual(try permissions(snapshots), 0o700)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: snapshots.path), [])
    }

    func test_index_snapshot_policy_never_recreates_a_deleted_index_directory() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let scratch = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let url = scratch.appendingPathComponent("agent/state_5.sqlite")
        try makeWALDatabaseWithoutSHM(at: url, schema: "CREATE TABLE threads(id TEXT PRIMARY KEY)", in: scratch)

        XCTAssertThrowsError(try AgentHistoryDatabase.readExternalSnapshot(url: url, copyPolicy: .index(index.paths)) { _ in })
        XCTAssertFalse(fileManager.fileExists(atPath: index.paths.directoryURL.path))
    }

    func test_database_sources_built_for_the_index_copy_into_its_snapshots_directory() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.storage.ensureDirectory()
        let scratch = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let codexRoot = scratch.appendingPathComponent("codex", isDirectory: true)
        let openCodeRoot = scratch.appendingPathComponent("opencode", isDirectory: true)
        try makeWALDatabaseWithoutSHM(
            at: codexRoot.appendingPathComponent(CodexThreadCatalog.databaseFileName),
            schema: "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT)", in: scratch
        )
        try makeWALDatabaseWithoutSHM(
            at: openCodeRoot.appendingPathComponent(OpenCodeHistorySource.databaseFileName),
            schema: "CREATE TABLE unrelated(id TEXT PRIMARY KEY)", in: scratch
        )
        let sources = AgentHistorySourceFactory.makeSources(
            roots: [
                AgentHistorySourceRoot(agent: .codex, path: codexRoot.path, isDefault: true),
                AgentHistorySourceRoot(agent: .opencode, path: openCodeRoot.path, isDefault: true),
            ],
            snapshotCopyPolicy: .index(index.paths)
        )
        let codex = try XCTUnwrap(sources.first as? CodexHistorySource)
        let openCode = try XCTUnwrap(sources.last as? OpenCodeHistorySource)
        let snapshots = index.paths.snapshotsDirectoryURL

        XCTAssertNil(codex.catalog.lookup().problem, "the catalog must read through the private copy")
        XCTAssertTrue(fileManager.fileExists(atPath: snapshots.path), "Codex copies into the index's snapshots")
        try fileManager.removeItem(at: snapshots)

        XCTAssertNil(try openCode.existingNativeIDs())
        XCTAssertTrue(fileManager.fileExists(atPath: snapshots.path), "opencode copies into the index's snapshots")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: snapshots.path), [])
    }

    // MARK: - Leftovers

    func test_opening_the_index_removes_leftover_snapshots() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let first = try makeLeftoverSnapshot(in: index.paths, suffix: "AbC123")
        let second = try makeLeftoverSnapshot(in: index.paths, suffix: "XyZ789")

        try index.openWriter()

        XCTAssertFalse(fileManager.fileExists(atPath: first.path))
        XCTAssertFalse(fileManager.fileExists(atPath: second.path))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: index.paths.snapshotsDirectoryURL.path), [])
    }

    func test_delete_index_removes_leftover_snapshots() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        index.closeWriter()
        let leftover = try makeLeftoverSnapshot(in: index.paths)

        try index.storage.withExclusiveOwnership(timeout: 0) {
            try index.storage.removeEverything()
        }

        XCTAssertFalse(fileManager.fileExists(atPath: leftover.path))
        XCTAssertFalse(fileManager.fileExists(atPath: index.paths.snapshotsDirectoryURL.path))
    }
}
