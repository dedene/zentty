import Foundation
import XCTest
@testable import Zentty

/// Several writers (Zentty instances of one flavor) opening the same index directory.
final class AgentHistoryStorageConcurrencyTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Result<[AgentHistoryOpenOutcome], Error>] = []
        private var handles: [AgentHistoryWriterHandle] = []

        func record(_ open: () throws -> AgentHistoryWriterHandle) {
            let result = Result(catching: open)
            lock.lock()
            outcomes.append(result.map(\.outcomes))
            if case .success(let handle) = result { handles.append(handle) }
            lock.unlock()
        }

        var all: [Result<[AgentHistoryOpenOutcome], Error>] {
            lock.lock()
            defer { lock.unlock() }
            return outcomes
        }

        func closeAll() {
            lock.lock()
            defer { lock.unlock() }
            for handle in handles { handle.database.close() }
        }
    }

    private func corruptCopies(in paths: AgentHistoryPaths) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.directoryURL.path)
            .filter(AgentHistoryPaths.isCorruptCopyName)
    }

    func test_schema_created_by_another_writer_after_snapshot_is_opened_not_quarantined() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let paths = index.paths
        var options = AgentHistoryStorage.Options()
        // Another writer builds the index between this open's snapshot (empty file, version 0)
        // and its write transaction.
        options.beforeSchemaWriteForTesting = {
            do {
                let other = try AgentHistoryDatabase(url: paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
                defer { other.close() }
                try other.transaction {
                    try AgentHistorySchema.createVersion1(
                        other, tokenizer: AgentHistorySchema.probeTokenizer(other),
                        now: Date(timeIntervalSince1970: 1_793_000_000), appVersion: "other"
                    )
                    try other.setUserVersion(AgentHistorySchema.currentVersion)
                    try other.setApplicationID(AgentHistorySchema.applicationID)
                    try other.run("INSERT INTO meta(key, value) VALUES ('probe', 'first writer')")
                }
            } catch {
                XCTFail("the other writer failed: \(error)")
            }
        }
        let storage = AgentHistoryStorage(paths: paths, options: options, appVersion: "test")
        let handle = try storage.openWriter()
        addTeardownBlock {
            handle.database.close()
            storage.readers.closeAll()
        }

        XCTAssertEqual(handle.outcomes, [.opened])
        XCTAssertEqual(try corruptCopies(in: paths), [])
        XCTAssertEqual(try handle.database.queryOne("SELECT value FROM meta WHERE key = 'probe'") { $0.string(0) },
                       "first writer")
    }

    func test_concurrent_writers_create_one_index_and_quarantine_nothing() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let paths = index.paths
        let storages = (0..<4).map { _ in AgentHistoryStorage(paths: paths, appVersion: "test") }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: storages.count) { i in
            results.record { try storages[i].openWriter() }
        }
        addTeardownBlock {
            results.closeAll()
            for storage in storages { storage.readers.closeAll() }
        }

        let outcomes = try results.all.map { try $0.get() }
        XCTAssertEqual(outcomes.filter { $0 == [.created] }.count, 1, "\(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == [.opened] }.count, storages.count - 1, "\(outcomes)")
        XCTAssertEqual(try corruptCopies(in: paths), [])
    }

    func test_open_waits_for_the_setup_lock_and_reports_busy() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try FileManager.default.createDirectory(at: index.paths.directoryURL, withIntermediateDirectories: true)
        let held = try AgentHistorySetupLock(url: index.paths.lockURL, timeout: 0)

        var options = AgentHistoryStorage.Options()
        options.setupLockTimeout = 0.1
        let storage = AgentHistoryStorage(paths: index.paths, options: options, appVersion: "test")
        addTeardownBlock { storage.readers.closeAll() }

        XCTAssertThrowsError(try storage.openWriter()) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
        }
        XCTAssertEqual(storage.availability, .unavailable(.busy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.paths.databaseURL.path))

        held.unlock()
        let handle = try storage.openWriter()
        addTeardownBlock { handle.database.close() }
        XCTAssertEqual(handle.outcomes, [.created])
        XCTAssertEqual(storage.availability, .ready)
    }
}
