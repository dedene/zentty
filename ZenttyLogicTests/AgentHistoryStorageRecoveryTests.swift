import Foundation
import XCTest
@testable import Zentty

/// A `FileManager` whose move and remove calls run a hook first, so tests can fail a file
/// operation or act in the middle of one. Hooks are set before use, on the test's thread.
final class AgentHistoryHookedFileManager: FileManager {
    var beforeMove: ((URL, URL) throws -> Void)?
    var beforeRemove: ((URL) throws -> Void)?

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try beforeMove?(srcURL, dstURL)
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        try beforeRemove?(URL)
        try super.removeItem(at: URL)
    }
}

final class AgentHistoryStorageRecoveryTests: XCTestCase {
    private let fileManager = FileManager.default

    private func writeGarbage(to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8_192).write(to: url)
    }

    private func corruptCopies(in paths: AgentHistoryPaths) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: paths.directoryURL.path)
            .filter(AgentHistoryPaths.isCorruptCopyName)
    }

    // MARK: - Failed quarantine

    func test_failed_quarantine_leaves_index_unavailable_and_readers_refuse() throws {
        let hooked = AgentHistoryHookedFileManager()
        let index = AgentHistoryTestIndex(testCase: self, fileManager: hooked)
        try index.openWriter()
        index.closeWriter()
        XCTAssertEqual(index.storage.availability, .ready)
        XCTAssertNotNil(index.storage.tokenizer)

        try writeGarbage(to: index.paths.databaseURL)
        let garbage = try Data(contentsOf: index.paths.databaseURL)
        hooked.beforeMove = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        XCTAssertThrowsError(try index.storage.openWriter()) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        XCTAssertEqual(index.storage.availability, .unavailable(.cantOpen))
        XCTAssertNil(index.storage.tokenizer)
        XCTAssertThrowsError(try index.storage.readers.withReader { try $0.userVersion() }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        XCTAssertEqual(index.storage.readers.openConnectionCountForTesting, 0)
        XCTAssertEqual(try Data(contentsOf: index.paths.databaseURL), garbage)
        XCTAssertEqual(try corruptCopies(in: index.paths), [])

        // Once the move works again, the next open recovers.
        hooked.beforeMove = nil
        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }
        XCTAssertEqual(handle.outcomes, [.recoveredFromCorruption, .created])
        XCTAssertEqual(index.storage.availability, .ready)
    }

    // MARK: - Reader fence

    private func probeValue(_ pool: AgentHistoryReaderPool) throws -> String? {
        try pool.withReader { try $0.queryOne("SELECT value FROM meta WHERE key = 'probe'") { $0.string(0) } }
    }

    private func assertBusy(_ result: Result<String?, Error>?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error)? = result else {
            return XCTFail("a reader opened while the index files were replaced: \(String(describing: result))",
                           file: file, line: line)
        }
        XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy, file: file, line: line)
    }

    func test_reader_cannot_pool_a_connection_while_index_files_are_removed() throws {
        let hooked = AgentHistoryHookedFileManager()
        let index = AgentHistoryTestIndex(testCase: self, fileManager: hooked)
        try index.openWriter().run("INSERT INTO meta(key, value) VALUES ('probe', 'old')")
        index.closeWriter()
        let pool = index.storage.readers

        var duringRemoval: Result<String?, Error>?
        hooked.beforeRemove = { [paths = index.paths] url in
            guard url == paths.databaseURL, duringRemoval == nil else { return }
            duringRemoval = Result { try self.probeValue(pool) }
        }
        try index.storage.removeIndexFiles()
        hooked.beforeRemove = nil

        assertBusy(duringRemoval)
        XCTAssertEqual(pool.openConnectionCountForTesting, 0)

        // After the rebuild, readers see the new file, not the deleted one.
        try index.openWriter()
        XCTAssertNil(try probeValue(pool))
    }

    func test_reader_cannot_pool_a_connection_while_corrupt_index_is_moved_aside() throws {
        let hooked = AgentHistoryHookedFileManager()
        let index = AgentHistoryTestIndex(testCase: self, fileManager: hooked)
        try index.openWriter().run("INSERT INTO meta(key, value) VALUES ('probe', 'old')")
        index.closeWriter()
        let pool = index.storage.readers
        // A foreign application id makes the next open quarantine an otherwise readable file.
        let stamp = try AgentHistoryDatabase(url: index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try stamp.setApplicationID(0x1234)
        stamp.close()

        var duringMove: Result<String?, Error>?
        hooked.beforeMove = { _, _ in
            guard duringMove == nil else { return }
            duringMove = Result { try self.probeValue(pool) }
        }
        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }
        hooked.beforeMove = nil

        XCTAssertEqual(handle.outcomes, [.recoveredFromCorruption, .created])
        assertBusy(duringMove)
        XCTAssertNil(try probeValue(pool))
    }

    func test_fence_refuses_readers_until_it_ends() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        let pool = index.storage.readers
        try pool.withReader { _ in }
        XCTAssertEqual(pool.openConnectionCountForTesting, 1)

        try pool.fenced {
            XCTAssertEqual(pool.openConnectionCountForTesting, 0)
            XCTAssertThrowsError(try pool.withReader { _ in }) { error in
                XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
            }
        }
        XCTAssertEqual(try pool.withReader { try $0.userVersion() }, AgentHistorySchema.currentVersion)
    }
}
