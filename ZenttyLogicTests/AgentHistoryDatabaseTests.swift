import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryDatabaseTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeDatabase(
        _ name: String = "index.sqlite",
        in directory: URL? = nil,
        mode: AgentHistoryDatabase.Mode = .readWrite,
        busyTimeoutMilliseconds: Int32 = 2_000,
        journalMode: AgentHistoryDatabase.JournalMode = .wal
    ) throws -> AgentHistoryDatabase {
        let directory = try directory ?? makeDirectory()
        let database = try AgentHistoryDatabase(
            url: directory.appendingPathComponent(name),
            mode: mode,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            journalMode: journalMode
        )
        addTeardownBlock { database.close() }
        return database
    }

    // MARK: - Open

    func test_open_creates_file_with_wal_and_foreign_keys() throws {
        let directory = try makeDirectory()
        let database = try makeDatabase(in: directory)
        XCTAssertTrue(database.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite").path))
        let journalMode = try database.queryOne("PRAGMA journal_mode") { $0.string(0) }
        XCTAssertEqual(journalMode, "wal")
        XCTAssertEqual(try database.scalarInt64("PRAGMA foreign_keys"), 1)
        XCTAssertEqual(try database.scalarInt64("PRAGMA trusted_schema"), 0)
    }

    func test_read_write_open_refuses_symlinked_database_file() throws {
        let directory = try makeDirectory()
        let real = try makeDatabase("real.sqlite", in: directory)
        try real.execute("CREATE TABLE t(v INTEGER)")
        let link = directory.appendingPathComponent("index.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("real.sqlite"))
        XCTAssertThrowsError(try AgentHistoryDatabase(url: link, mode: .readWrite, busyTimeoutMilliseconds: 50)) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
    }

    // MARK: - Values

    func test_bind_and_read_round_trip_all_value_types() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v)")
        let blob = Data([0, 1, 2, 0, 255])
        let values: [AgentHistoryValue] = [
            .integer(Int64.max),
            .integer(Int64.min),
            .integer(0),
            .real(3.25),
            .text("héllo 👋🏽 世界"),
            .text("a\u{0}b"),
            .text(""),
            .blob(blob),
            .blob(Data()),
            .null,
        ]
        for (index, value) in values.enumerated() {
            try database.run("INSERT INTO t(id, v) VALUES (?, ?)", [.integer(Int64(index)), value])
        }
        let read = try database.query("SELECT v FROM t ORDER BY id") { $0.value(0) }
        XCTAssertEqual(read, values)

        let text = try database.queryOne("SELECT v FROM t WHERE id = 5") { $0.string(0) }
        XCTAssertEqual(text, "a\u{0}b")
        XCTAssertEqual(text?.utf8.count, 3)
        let bytes = try database.queryOne("SELECT v FROM t WHERE id = 4") { row in
            row.withUTF8Bytes(0) { Array($0) }
        }
        XCTAssertEqual(bytes ?? nil, Array("héllo 👋🏽 世界".utf8))
        let nullBytes = try database.queryOne("SELECT v FROM t WHERE id = 9") { row in
            row.withUTF8Bytes(0) { Array($0) }
        }
        XCTAssertEqual(nullBytes, .some(nil))

        let typed = try database.queryOne("SELECT ?, ?, ?, ?, ?, ?", [42, "x", nil, .real(1.5), .integer(1), .blob(blob)]) { row in
            (row.int64(0), row.string(1), row.isNull(2), row.optionalInt64(2), row.optionalString(2),
             row.double(3), row.bool(4), row.data(5), row.optionalInt64(0), row.optionalString(1))
        }
        let unwrapped = try XCTUnwrap(typed)
        XCTAssertEqual(unwrapped.0, 42)
        XCTAssertEqual(unwrapped.1, "x")
        XCTAssertTrue(unwrapped.2)
        XCTAssertNil(unwrapped.3)
        XCTAssertNil(unwrapped.4)
        XCTAssertEqual(unwrapped.5, 1.5)
        XCTAssertTrue(unwrapped.6)
        XCTAssertEqual(unwrapped.7, blob)
        XCTAssertEqual(unwrapped.8, 42)
        XCTAssertEqual(unwrapped.9, "x")
    }

    func test_value_of_helpers_map_nil_to_null() {
        XCTAssertEqual(AgentHistoryValue.of(nil as Int64?), .null)
        XCTAssertEqual(AgentHistoryValue.of(nil as Int?), .null)
        XCTAssertEqual(AgentHistoryValue.of(nil as String?), .null)
        XCTAssertEqual(AgentHistoryValue.of(nil as Bool?), .null)
        XCTAssertEqual(AgentHistoryValue.of(nil as Double?), .null)
        XCTAssertEqual(AgentHistoryValue.of(nil as Data?), .null)
        XCTAssertEqual(AgentHistoryValue.of(Int64(7)), .integer(7))
        XCTAssertEqual(AgentHistoryValue.of(Int(8)), .integer(8))
        XCTAssertEqual(AgentHistoryValue.of("s"), .text("s"))
        XCTAssertEqual(AgentHistoryValue.of(true), .integer(1))
        XCTAssertEqual(AgentHistoryValue.of(false), .integer(0))
        XCTAssertEqual(AgentHistoryValue.of(2.5), .real(2.5))
        let literalNil: AgentHistoryValue = nil
        let literalInt: AgentHistoryValue = 9
        let literalText: AgentHistoryValue = "t"
        XCTAssertEqual(literalNil, .null)
        XCTAssertEqual(literalInt, .integer(9))
        XCTAssertEqual(literalText, .text("t"))
    }

    // MARK: - Statement cache and lifecycle

    func test_statement_cache_reuses_prepared_statements() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER)")
        XCTAssertEqual(database.cachedStatementCount, 0)
        for value in 0..<5 {
            try database.run("INSERT INTO t(v) VALUES (?)", [.integer(Int64(value))])
        }
        XCTAssertEqual(database.cachedStatementCount, 1)
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t"), 5)
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t"), 5)
        XCTAssertEqual(database.cachedStatementCount, 2)
        // Reuse clears old bindings: a fresh query with the same SQL sees only its own binding.
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t WHERE v >= ?", [3]), 2)
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t WHERE v >= ?", [0]), 5)
        XCTAssertEqual(database.cachedStatementCount, 3)
    }

    func test_close_is_idempotent_and_finalizes_statements() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER)")
        try database.run("INSERT INTO t(v) VALUES (1)")
        XCTAssertEqual(database.cachedStatementCount, 1)
        database.close()
        XCTAssertFalse(database.isOpen)
        XCTAssertEqual(database.cachedStatementCount, 0)
        database.close()
        XCTAssertFalse(database.isOpen)
        XCTAssertThrowsError(try database.scalarInt64("SELECT 1")) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .misuse)
        }
    }

    // MARK: - Transactions

    func test_transaction_commits_on_success() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER)")
        let result = try database.transaction { () -> Int in
            XCTAssertTrue(database.isInTransaction)
            try database.run("INSERT INTO t(v) VALUES (1)")
            try database.run("INSERT INTO t(v) VALUES (2)")
            return database.changes
        }
        XCTAssertEqual(result, 1)
        XCTAssertFalse(database.isInTransaction)
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t"), 2)
        XCTAssertGreaterThan(database.lastInsertRowID, 0)
    }

    func test_transaction_rolls_back_on_throw() throws {
        struct Boom: Error {}
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER)")
        XCTAssertThrowsError(try database.transaction {
            try database.run("INSERT INTO t(v) VALUES (1)")
            throw Boom()
        }) { XCTAssertTrue($0 is Boom) }
        XCTAssertFalse(database.isInTransaction)
        XCTAssertEqual(try database.scalarInt64("SELECT count(*) FROM t"), 0)
    }

    func test_nested_transaction_uses_savepoint_and_inner_failure_rolls_back_inner_only() throws {
        struct Boom: Error {}
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER)")
        try database.transaction {
            try database.run("INSERT INTO t(v) VALUES (1)")
            XCTAssertThrowsError(try database.transaction {
                try database.run("INSERT INTO t(v) VALUES (2)")
                throw Boom()
            })
            XCTAssertTrue(database.isInTransaction)
            try database.transaction {
                try database.run("INSERT INTO t(v) VALUES (3)")
            }
        }
        XCTAssertFalse(database.isInTransaction)
        let values = try database.query("SELECT v FROM t ORDER BY v") { $0.int64(0) }
        XCTAssertEqual(values, [1, 3])
    }

    func test_read_transaction_on_read_only_connection() throws {
        let directory = try makeDirectory()
        let writer = try makeDatabase(in: directory)
        try writer.execute("CREATE TABLE t(v INTEGER)")
        try writer.run("INSERT INTO t(v) VALUES (1), (2), (3)")
        let reader = try makeDatabase(in: directory, mode: .readOnly)
        let (count, sum) = try reader.readTransaction { () -> (Int64?, Int64?) in
            XCTAssertTrue(reader.isInTransaction)
            return (try reader.scalarInt64("SELECT count(*) FROM t"), try reader.scalarInt64("SELECT sum(v) FROM t"))
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(sum, 6)
        XCTAssertFalse(reader.isInTransaction)
        XCTAssertEqual(try reader.scalarInt64("PRAGMA query_only"), 1)
    }

    // MARK: - Error mapping

    func test_constraint_violation_maps_to_constraint_kind() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(v INTEGER UNIQUE)")
        try database.run("INSERT INTO t(v) VALUES (1)")
        XCTAssertThrowsError(try database.run("INSERT INTO t(v) VALUES (1)")) { error in
            let dbError = error as? AgentHistoryDatabaseError
            XCTAssertEqual(dbError?.kind, .constraint)
            XCTAssertEqual(dbError?.code, 19)            // SQLITE_CONSTRAINT
            XCTAssertEqual(dbError?.extendedCode, 2067)  // SQLITE_CONSTRAINT_UNIQUE
            XCTAssertEqual(dbError?.isCorruption, false)
        }
    }

    func test_not_a_database_maps_to_corruption() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("garbage.sqlite")
        try Data(repeating: 0x5A, count: 4_096).write(to: url)
        XCTAssertThrowsError(try AgentHistoryDatabase(url: url, mode: .readWrite, busyTimeoutMilliseconds: 50)) { error in
            let dbError = error as? AgentHistoryDatabaseError
            XCTAssertEqual(dbError?.kind, .notADatabase)
            XCTAssertEqual(dbError?.isCorruption, true)
        }
    }

    func test_busy_timeout_reports_busy() throws {
        let directory = try makeDirectory()
        let first = try makeDatabase(in: directory, busyTimeoutMilliseconds: 50, journalMode: .delete)
        try first.execute("CREATE TABLE t(v INTEGER)")
        try first.run("INSERT INTO t(v) VALUES (1)")
        let second = try makeDatabase(in: directory, busyTimeoutMilliseconds: 50, journalMode: .delete)
        XCTAssertEqual(try second.queryOne("PRAGMA journal_mode") { $0.string(0) }, "delete")
        try first.execute("BEGIN EXCLUSIVE")
        addTeardownBlock { try? first.execute("ROLLBACK") }
        XCTAssertThrowsError(try second.scalarInt64("SELECT count(*) FROM t")) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
        }
    }

    func test_read_only_connection_rejects_writes() throws {
        let directory = try makeDirectory()
        let writer = try makeDatabase(in: directory)
        try writer.execute("CREATE TABLE t(v INTEGER)")
        let reader = try makeDatabase(in: directory, mode: .readOnly)
        XCTAssertThrowsError(try reader.run("INSERT INTO t(v) VALUES (1)")) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .readOnly)
        }
        XCTAssertEqual(try writer.scalarInt64("SELECT count(*) FROM t"), 0)
    }

    // MARK: - External read-only

    func test_external_read_only_open_does_not_create_missing_file() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("missing dir?#%/state.sqlite")
        XCTAssertThrowsError(try AgentHistoryDatabase.openExternalReadOnly(url: url)) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        let plain = directory.appendingPathComponent("absent.sqlite")
        XCTAssertThrowsError(try AgentHistoryDatabase.openExternalReadOnly(url: plain)) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func test_external_read_only_reads_wal_database_written_by_another_connection() throws {
        let directory = try makeDirectory()
        let name = "agent db #1 ?.sqlite"
        let writer = try makeDatabase(name, in: directory)
        try writer.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)")
        try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", ["a", "first"])
        try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", ["b", "second"])

        let external = try AgentHistoryDatabase.openExternalReadOnly(url: directory.appendingPathComponent(name))
        addTeardownBlock { external.close() }
        XCTAssertEqual(external.mode, .externalReadOnly)
        let titles = try external.readTransaction {
            try external.query("SELECT title FROM threads ORDER BY id") { $0.string(0) }
        }
        XCTAssertEqual(titles, ["first", "second"])
        XCTAssertEqual(try external.scalarInt64("PRAGMA query_only"), 1)
        XCTAssertThrowsError(try external.run("DELETE FROM threads")) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .readOnly)
        }
        try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", ["c", "third"])
        XCTAssertEqual(try external.scalarInt64("SELECT count(*) FROM threads"), 3)
    }

    // MARK: - Cancellation

    private static let longQuery = """
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ?) SELECT count(*) FROM c
        """

    func test_progress_handler_aborts_with_interrupted_and_can_be_removed() throws {
        let database = try makeDatabase()
        database.setProgressHandler(everyInstructions: 1_000) { true }
        XCTAssertThrowsError(try database.scalarInt64(Self.longQuery, [.integer(50_000_000)])) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .interrupted)
        }
        database.setProgressHandler(everyInstructions: 1_000, nil)
        XCTAssertEqual(try database.scalarInt64(Self.longQuery, [.integer(10_000)]), 10_000)
    }

    func test_interrupt_cancels_running_query() throws {
        let database = try makeDatabase()
        let finished = expectation(description: "query finished")
        let outcome = OutcomeBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try database.scalarInt64(Self.longQuery, [.integer(5_000_000_000)])
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
            finished.fulfill()
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { database.interrupt() }
        timer.resume()
        wait(for: [finished], timeout: 20)
        timer.cancel()
        XCTAssertEqual((outcome.error as? AgentHistoryDatabaseError)?.kind, .interrupted)
        XCTAssertEqual(try database.scalarInt64("SELECT 1"), 1)
    }

    // MARK: - Pragmas and errors

    func test_user_version_and_application_id_round_trip() throws {
        let database = try makeDatabase()
        XCTAssertEqual(try database.userVersion(), 0)
        XCTAssertEqual(try database.applicationID(), 0)
        try database.setUserVersion(7)
        try database.setApplicationID(0x5A_48_53_54)
        XCTAssertEqual(try database.userVersion(), 7)
        XCTAssertEqual(try database.applicationID(), 0x5A_48_53_54)
    }

    func test_description_omits_sqlite_message() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE secret_table(v INTEGER UNIQUE)")
        try database.run("INSERT INTO secret_table(v) VALUES (1)")
        XCTAssertThrowsError(try database.run("INSERT INTO secret_table(v) VALUES (1)")) { error in
            let dbError = try? XCTUnwrap(error as? AgentHistoryDatabaseError)
            XCTAssertEqual(dbError?.message.contains("secret_table"), true)
            let rendered = [String(describing: error), error.localizedDescription, "\(error)"]
            for text in rendered {
                XCTAssertFalse(text.contains("secret_table"), text)
                XCTAssertFalse(text.contains("UNIQUE"), text)
                XCTAssertTrue(text.hasPrefix("SQLite constraint (19/2067)"), text)
            }
        }
    }

    func test_explain_query_plan_returns_details() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE t(a INTEGER, b TEXT); CREATE INDEX t_a ON t(a);")
        let plan = try database.explainQueryPlan("SELECT b FROM t WHERE a = ?", [1])
        XCTAssertTrue(plan.contains { $0.contains("t_a") }, plan.joined(separator: "\n"))
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    func set(_ error: Error?) { lock.lock(); storedError = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
}
