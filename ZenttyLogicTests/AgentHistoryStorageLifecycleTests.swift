import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryStorageLifecycleTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }
        func advance(by seconds: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private let fileManager = FileManager.default

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func writeGarbage(to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x5A, count: 8_192)
        try garbage.write(to: url)
    }

    private func corruptCopies(in paths: AgentHistoryPaths) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: paths.directoryURL.path)
            .filter(AgentHistoryPaths.isCorruptCopyName)
            .sorted()
    }

    private func objectNames(_ db: AgentHistoryDatabase) throws -> Set<String> {
        Set(try db.query("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") { $0.string(0) })
    }

    // MARK: - Create / reopen

    func test_open_writer_creates_schema_at_current_version() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }

        XCTAssertEqual(handle.outcomes, [.created])
        XCTAssertEqual(try handle.database.userVersion(), AgentHistorySchema.currentVersion)
        XCTAssertEqual(try handle.database.applicationID(), AgentHistorySchema.applicationID)
        XCTAssertEqual(index.storage.availability, .ready)
        XCTAssertEqual(index.storage.tokenizer, handle.tokenizer)
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(handle.database), handle.tokenizer)
        let names = try objectNames(handle.database)
        for table in ["meta", "sources", "sessions", "messages", "artifacts", "cursors", "tombstones", "usage_carryover"] {
            XCTAssertTrue(names.contains(table), table)
        }
        XCTAssertEqual(try handle.database.queryOne("SELECT value FROM meta WHERE key = 'app_version'") { $0.string(0) }, "test")
    }

    func test_reopen_is_plain_open() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        index.closeWriter()

        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }
        XCTAssertEqual(handle.outcomes, [.opened])
        XCTAssertEqual(try corruptCopies(in: index.paths), [])
    }

    // MARK: - Permissions

    func test_directory_is_0700_and_excluded_from_backup() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try fileManager.createDirectory(at: index.paths.directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try index.openWriter()

        XCTAssertEqual(try permissions(index.paths.directoryURL), 0o700)
        let values = try index.paths.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func test_database_wal_and_shm_are_0600() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let db = try index.openWriter()
        try db.run("INSERT INTO meta(key, value) VALUES ('probe', 'x')")

        for url in [index.paths.databaseURL, index.paths.walURL, index.paths.shmURL] {
            XCTAssertTrue(fileManager.fileExists(atPath: url.path), url.lastPathComponent)
            XCTAssertEqual(try permissions(url), 0o600, url.lastPathComponent)
        }
    }

    // MARK: - Newer schema

    func test_newer_schema_is_unavailable_and_file_untouched() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        index.closeWriter()
        let bump = try AgentHistoryDatabase(url: index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try bump.setUserVersion(AgentHistorySchema.currentVersion + 1)
        bump.close()
        let before = try Data(contentsOf: index.paths.databaseURL)

        XCTAssertThrowsError(try index.storage.openWriter()) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .schemaTooNew(found: AgentHistorySchema.currentVersion + 1))
        }
        XCTAssertEqual(index.storage.availability, .readOnlyNewerSchema(found: AgentHistorySchema.currentVersion + 1))
        XCTAssertNil(index.storage.tokenizer)
        XCTAssertThrowsError(try index.storage.readers.withReader { try $0.userVersion() }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .schemaTooNew(found: AgentHistorySchema.currentVersion + 1))
        }

        // A fresh storage whose readers run before any writer open refuses too.
        let other = AgentHistoryStorage(paths: index.paths)
        addTeardownBlock { other.readers.closeAll() }
        XCTAssertThrowsError(try other.readers.withReader { try $0.userVersion() }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .schemaTooNew(found: AgentHistorySchema.currentVersion + 1))
        }
        XCTAssertEqual(other.availability, .readOnlyNewerSchema(found: AgentHistorySchema.currentVersion + 1))

        XCTAssertEqual(try Data(contentsOf: index.paths.databaseURL), before)
        XCTAssertEqual(try corruptCopies(in: index.paths), [])
    }

    // MARK: - Corruption and foreign files

    func test_corrupt_database_is_moved_aside_and_rebuilt() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try writeGarbage(to: index.paths.databaseURL)
        let garbage = try Data(contentsOf: index.paths.databaseURL)

        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }

        XCTAssertEqual(handle.outcomes, [.recoveredFromCorruption, .created])
        XCTAssertEqual(index.storage.availability, .ready)
        XCTAssertEqual(try handle.database.userVersion(), AgentHistorySchema.currentVersion)
        let copies = try corruptCopies(in: index.paths)
        XCTAssertEqual(copies, [index.paths.corruptDatabaseURL(at: Date(timeIntervalSince1970: 1_793_000_000)).lastPathComponent])
        let copy = index.paths.directoryURL.appendingPathComponent(try XCTUnwrap(copies.first))
        XCTAssertEqual(try Data(contentsOf: copy), garbage)

        try handle.database.run("INSERT INTO meta(key, value) VALUES ('after', 'recovery')")
        XCTAssertEqual(try index.storage.readers.withReader {
            try $0.queryOne("SELECT value FROM meta WHERE key = 'after'") { $0.string(0) }
        }, "recovery")
    }

    func test_only_newest_corrupt_copy_is_kept() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_793_000_000))
        let index = AgentHistoryTestIndex(testCase: self, now: { clock.now() })
        try fileManager.createDirectory(at: index.paths.directoryURL, withIntermediateDirectories: true)
        let ancient = index.paths.directoryURL.appendingPathComponent("index.corrupt-20200101T000000Z.sqlite")
        try Data("old".utf8).write(to: ancient)

        try writeGarbage(to: index.paths.databaseURL)
        try index.openWriter()
        index.closeWriter()
        XCTAssertEqual(try corruptCopies(in: index.paths), [index.paths.corruptDatabaseURL(at: clock.now()).lastPathComponent])

        clock.advance(by: 3_600)
        try writeGarbage(to: index.paths.databaseURL)
        let handle = try index.storage.openWriter()
        addTeardownBlock { handle.database.close() }
        XCTAssertEqual(handle.outcomes.first, .recoveredFromCorruption)
        XCTAssertEqual(try corruptCopies(in: index.paths), [index.paths.corruptDatabaseURL(at: clock.now()).lastPathComponent])
    }

    func test_foreign_sqlite_file_is_quarantined() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try fileManager.createDirectory(at: index.paths.directoryURL, withIntermediateDirectories: true)
        let foreign = try AgentHistoryDatabase(url: index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try foreign.execute("CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES ('keep me');")
        foreign.close()

        let handle = try index.storage.openWriter()
        XCTAssertEqual(handle.outcomes, [.recoveredFromCorruption, .created])
        XCTAssertFalse(try objectNames(handle.database).contains("notes"))
        XCTAssertEqual(try corruptCopies(in: index.paths).count, 1)
        handle.database.close()

        // An empty database stamped by another application is foreign too.
        try fileManager.removeItem(at: index.paths.directoryURL)
        try fileManager.createDirectory(at: index.paths.directoryURL, withIntermediateDirectories: true)
        let stamped = try AgentHistoryDatabase(url: index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try stamped.setApplicationID(0x1234)
        stamped.close()

        let second = try index.storage.openWriter()
        addTeardownBlock { second.database.close() }
        XCTAssertEqual(second.outcomes, [.recoveredFromCorruption, .created])
        XCTAssertEqual(try second.database.applicationID(), AgentHistorySchema.applicationID)
    }

    // MARK: - Removal

    func test_remove_index_files_keeps_state_json() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let db = try index.openWriter()
        try db.run("INSERT INTO meta(key, value) VALUES ('probe', 'x')")
        try Data("{}".utf8).write(to: index.paths.stateURL)
        index.closeWriter()

        try index.storage.removeIndexFiles()

        for url in [index.paths.databaseURL, index.paths.walURL, index.paths.shmURL] {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: index.paths.stateURL.path))
        XCTAssertEqual(index.storage.diskUsageBytes(), 0)

        let reopened = try index.storage.openWriter()
        addTeardownBlock { reopened.database.close() }
        XCTAssertEqual(reopened.outcomes, [.created])
    }

    func test_remove_everything_deletes_directory_and_closes_readers() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        try index.openWriter()
        var reader: AgentHistoryDatabase?
        try index.storage.readers.withReader { db in
            reader = db
            _ = try db.userVersion()
        }
        XCTAssertGreaterThan(index.storage.diskUsageBytes(), 0)
        index.closeWriter()

        try index.storage.removeEverything()

        XCTAssertEqual(reader?.isOpen, false)
        XCTAssertEqual(index.storage.readers.openConnectionCountForTesting, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: index.paths.directoryURL.path))
        XCTAssertEqual(index.storage.availability, .ready)
    }

    // MARK: - Readers

    func test_readers_see_committed_rows_while_writer_holds_transaction() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let writer = try index.openWriter()
        try writer.run("INSERT INTO meta(key, value) VALUES ('k1', 'committed')")

        try writer.transaction {
            try writer.run("INSERT INTO meta(key, value) VALUES ('k2', 'pending')")
            let seen = try index.storage.readers.withReader { reader in
                try reader.query("SELECT key FROM meta WHERE key LIKE 'k%' ORDER BY key") { $0.string(0) }
            }
            XCTAssertEqual(seen, ["k1"])
        }

        let after = try index.storage.readers.withReader { reader in
            try reader.query("SELECT key FROM meta WHERE key LIKE 'k%' ORDER BY key") { $0.string(0) }
        }
        XCTAssertEqual(after, ["k1", "k2"])
    }

    func test_reader_pool_close_all_closes_checked_out_connection_on_return() throws {
        var options = AgentHistoryStorage.Options()
        options.readerCount = 1
        let index = AgentHistoryTestIndex(testCase: self, options: options)
        try index.openWriter()
        let pool = index.storage.readers

        var first: AgentHistoryDatabase?
        try pool.withReader { db in
            first = db
            pool.closeAll()
            XCTAssertTrue(db.isOpen)
            XCTAssertEqual(try db.userVersion(), AgentHistorySchema.currentVersion)
        }
        XCTAssertEqual(first?.isOpen, false)

        var second: AgentHistoryDatabase?
        try pool.withReader { db in second = db }
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second?.isOpen, true)
    }

    func test_reader_check_in_clears_progress_handler() throws {
        var options = AgentHistoryStorage.Options()
        options.readerCount = 1
        let index = AgentHistoryTestIndex(testCase: self, options: options)
        try index.openWriter()
        let pool = index.storage.readers
        let query = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 5000) SELECT count(*) FROM n"

        var first: AgentHistoryDatabase?
        try pool.withReader { db in
            first = db
            db.setProgressHandler(everyInstructions: 10) { true }
            XCTAssertThrowsError(try db.scalarInt64(query)) { error in
                XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .interrupted)
            }
        }

        try pool.withReader { db in
            XCTAssertTrue(db === first)
            XCTAssertEqual(try db.scalarInt64(query), 5_000)
        }
    }

    func test_tokenizer_override_forces_fallback() throws {
        let index = AgentHistoryTestIndex(testCase: self)
        let created = try index.openWriter()
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(created), .trigram)
        index.closeWriter()

        var options = AgentHistoryStorage.Options()
        options.tokenizerOverride = .unicode61
        let fallback = AgentHistoryStorage(paths: index.paths, options: options)
        let handle = try fallback.openWriter()
        addTeardownBlock {
            handle.database.close()
            fallback.readers.closeAll()
        }

        XCTAssertEqual(handle.outcomes, [.opened, .tokenizerChanged(from: .trigram, to: .unicode61)])
        XCTAssertEqual(handle.tokenizer, .unicode61)
        XCTAssertEqual(fallback.tokenizer, .unicode61)
        XCTAssertEqual(try AgentHistorySchema.storedTokenizer(handle.database), .unicode61)
        let ftsSQL = try handle.database.queryOne("SELECT sql FROM sqlite_master WHERE name = 'messages_fts'") { $0.string(0) }
        XCTAssertTrue(ftsSQL?.contains("unicode61") == true)

        // A fresh index with the override is built with it directly.
        var noneOptions = AgentHistoryStorage.Options()
        noneOptions.tokenizerOverride = AgentHistoryTokenizer.none
        let fresh = AgentHistoryTestIndex(testCase: self, options: noneOptions)
        let freshDB = try fresh.openWriter()
        XCTAssertEqual(fresh.storage.tokenizer, AgentHistoryTokenizer.none)
        XCTAssertFalse(try objectNames(freshDB).contains("messages_fts"))
    }
}
