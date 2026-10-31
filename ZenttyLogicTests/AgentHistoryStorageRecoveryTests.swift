import Foundation
import XCTest
@testable import Zentty

/// A `FileManager` whose move and remove calls run a hook first, so tests can fail a file
/// operation or act in the middle of one. Hooks are set before use, on the test's thread.
final class AgentHistoryHookedFileManager: FileManager, @unchecked Sendable {
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
}
