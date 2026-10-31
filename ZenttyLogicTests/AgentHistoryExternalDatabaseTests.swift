import Foundation
import XCTest
@testable import Zentty

/// Read-only access to other agents' SQLite databases (Codex `state_5`, opencode). Fixtures are
/// built through `AgentHistoryDatabase(.readWrite)`; tests never import SQLite3.
final class AgentHistoryExternalDatabaseTests: XCTestCase {
    /// Holds a writer opened mid-read so the teardown block can close it.
    private final class WriterBox: @unchecked Sendable {
        var database: AgentHistoryDatabase?
    }

    private func makeFixture(
        _ name: String = "agent.sqlite",
        in directory: URL,
        journalMode: AgentHistoryDatabase.JournalMode = .wal
    ) throws -> AgentHistoryDatabase {
        let database = try AgentHistoryDatabase(
            url: directory.appendingPathComponent(name),
            mode: .readWrite,
            busyTimeoutMilliseconds: 2_000,
            journalMode: journalMode
        )
        addTeardownBlock { database.close() }
        return database
    }

    private func openExternal(_ url: URL, busyTimeoutMilliseconds: Int32 = 250) throws -> AgentHistoryDatabase {
        let database = try AgentHistoryDatabase.openExternalReadOnly(url: url, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        addTeardownBlock { database.close() }
        return database
    }

    private func listing(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// A WAL database whose writer has closed, with every row checkpointed into the main file and
    /// no `-wal`/`-shm` left beside it (removed explicitly if this SQLite build persists them).
    private func makeClosedWALDatabase(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("state_5.sqlite")
        let writer = try AgentHistoryDatabase(url: url, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        try writer.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)")
        try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", ["t1", "first"])
        try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", ["t2", "second"])
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        writer.close()
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        return url
    }

    // MARK: - Writes, rows, errors

    func test_external_open_write_fails() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let fixture = try makeFixture(in: directory)
        try fixture.execute("CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT)")
        try fixture.run("INSERT INTO session(id, title) VALUES (?, ?)", ["s1", "kept"])

        let external = try openExternal(fixture.url)
        for sql in ["INSERT INTO session(id, title) VALUES ('s2', 'new')",
                    "UPDATE session SET title = 'changed'",
                    "DELETE FROM session",
                    "CREATE TABLE intruder(v INTEGER)"] {
            XCTAssertThrowsError(try external.run(sql), sql) { error in
                XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .readOnly, sql)
            }
        }
        XCTAssertEqual(try fixture.query("SELECT title FROM session") { $0.string(0) }, ["kept"])
        XCTAssertFalse(try fixture.tableExists("intruder"))
    }

    func test_row_types_and_nulls() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let fixture = try makeFixture(in: directory)
        try fixture.execute("CREATE TABLE part(id INTEGER PRIMARY KEY, n INTEGER, r REAL, t TEXT, b BLOB)")
        try fixture.run("INSERT INTO part(id, n, r, t, b) VALUES (?, ?, ?, ?, ?)",
                        [1, .integer(1_730_000_000_123), .real(2.5), "héllo ✓", .blob(Data([0, 1, 255]))])
        try fixture.run("INSERT INTO part(id, n, r, t, b) VALUES (?, ?, ?, ?, ?)", [2, nil, nil, nil, nil])
        try fixture.run("INSERT INTO part(id, n, r, t, b) VALUES (?, ?, ?, ?, ?)", [3, 0, .real(0), "", .blob(Data())])

        let external = try openExternal(fixture.url)
        let rows = try external.readTransaction {
            try external.query("SELECT n, r, t, b FROM part ORDER BY id") { row in
                (0..<4).map { row.value(Int32($0)) }
            }
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], [.integer(1_730_000_000_123), .real(2.5), .text("héllo ✓"), .blob(Data([0, 1, 255]))])
        XCTAssertEqual(rows[1], [.null, .null, .null, .null])
        XCTAssertEqual(rows[2][0], .integer(0))
        XCTAssertEqual(rows[2][2], .text(""))

        let nulls = try external.queryOne("SELECT n, t, b FROM part WHERE id = 2") { row in
            (row.optionalInt64(0), row.optionalString(1), row.optionalData(2), row.isNull(0))
        }
        XCTAssertNil(nulls?.0)
        XCTAssertNil(nulls?.1)
        XCTAssertNil(nulls?.2)
        XCTAssertEqual(nulls?.3, true)
        let text = try external.queryOne("SELECT t FROM part WHERE id = 1") { row in
            row.withUTF8Bytes(0) { Array($0) }
        }
        XCTAssertEqual(text ?? nil, Array("héllo ✓".utf8))
    }

    func test_missing_file_error() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let missing = directory.appendingPathComponent("opencode.db")
        XCTAssertThrowsError(try AgentHistoryDatabase.openExternalReadOnly(url: missing)) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        XCTAssertEqual(try listing(directory), [])
    }

    func test_busy_maps_to_busy() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let fixture = try makeFixture(in: directory, journalMode: .delete)
        try fixture.execute("CREATE TABLE session(id TEXT PRIMARY KEY)")
        try fixture.run("INSERT INTO session(id) VALUES ('s1')")

        let external = try openExternal(fixture.url, busyTimeoutMilliseconds: 20)
        try fixture.execute("BEGIN EXCLUSIVE")
        XCTAssertThrowsError(try external.readTransaction {
            try external.scalarInt64("SELECT count(*) FROM session")
        }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .busy)
        }
        try fixture.execute("COMMIT")
        XCTAssertFalse(external.isInTransaction)
        XCTAssertEqual(try external.scalarInt64("SELECT count(*) FROM session"), 1)
    }

    // MARK: - Introspection

    func test_columns_probe_and_table_exists() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let fixture = try makeFixture(in: directory)
        try fixture.execute("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, cwd TEXT, \"odd \"\"name\"\"\" INTEGER);
            CREATE VIEW recent AS SELECT id FROM threads;
            CREATE INDEX threads_cwd ON threads(cwd);
            """)

        let external = try openExternal(fixture.url)
        XCTAssertEqual(try external.columns(of: "threads"), ["id", "title", "cwd", "odd \"name\""])
        XCTAssertEqual(try external.columns(of: "missing"), [])
        XCTAssertEqual(try external.columns(of: "threads'; DROP TABLE threads; --"), [])
        XCTAssertTrue(try external.tableExists("threads"))
        XCTAssertTrue(try external.tableExists("recent"))
        XCTAssertFalse(try external.tableExists("threads_cwd"))
        XCTAssertFalse(try external.tableExists("missing"))
        XCTAssertFalse(try external.tableExists("THREADS_typo"))
        XCTAssertTrue(try fixture.tableExists("threads"))
    }

    // MARK: - Files on disk

    func test_no_files_created_for_delete_journal_db() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let fixture = try makeFixture(in: directory, journalMode: .delete)
        try fixture.execute("CREATE TABLE session(id TEXT PRIMARY KEY)")
        try fixture.run("INSERT INTO session(id) VALUES ('s1')")
        fixture.close()
        let before = try listing(directory)
        let beforeBytes = try bytes(fixture.url)
        XCTAssertEqual(before, ["agent.sqlite"])

        let external = try openExternal(fixture.url)
        XCTAssertEqual(try external.readTransaction { try external.scalarInt64("SELECT count(*) FROM session") }, 1)
        XCTAssertEqual(try external.columns(of: "session"), ["id"])
        external.close()

        XCTAssertEqual(try listing(directory), before)
        XCTAssertEqual(try bytes(fixture.url), beforeBytes)
    }

    func test_wal_db_held_open_by_writer_is_readable_and_never_checkpointed() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let writer = try makeFixture(in: directory)
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        for index in 0..<50 {
            try writer.run("INSERT INTO threads(id, title) VALUES (?, ?)", [.text("t\(index)"), .text("title \(index)")])
        }
        let walURL = URL(fileURLWithPath: writer.url.path + "-wal")
        let mainBytes = try bytes(writer.url)
        let walBytes = try bytes(walURL)
        let before = try listing(directory)
        XCTAssertFalse(walBytes.isEmpty)

        let external = try openExternal(writer.url)
        let count = try external.readTransaction { try external.scalarInt64("SELECT count(*) FROM threads") }
        XCTAssertEqual(count, 50)
        XCTAssertEqual(try external.columns(of: "threads"), ["id", "title"])
        external.close()

        XCTAssertEqual(try listing(directory), before)
        XCTAssertEqual(try bytes(writer.url), mainBytes, "the main database file must not be checkpointed into")
        XCTAssertEqual(try bytes(walURL), walBytes)
        try writer.run("INSERT INTO threads(id, title) VALUES ('t50', 'after')")
        XCTAssertEqual(try writer.scalarInt64("SELECT count(*) FROM threads"), 51)
    }

    /// A plain `mode=ro` connection cannot read a WAL database without `-wal` (SQLite would have to
    /// create it), so `readExternalSnapshot` reads it with `immutable=1` and creates nothing.
    func test_wal_db_without_shm_leaves_no_new_files() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let url = try makeClosedWALDatabase(in: directory)
        let before = try listing(directory)
        let beforeBytes = try bytes(url)
        XCTAssertEqual(before, ["state_5.sqlite"])

        var calls = 0
        let (titles, hasThreads, columns) = try AgentHistoryDatabase.readExternalSnapshot(url: url) { database in
            calls += 1
            XCTAssertEqual(database.mode, .externalReadOnly)
            return (try database.query("SELECT title FROM threads ORDER BY id") { $0.string(0) },
                    try database.tableExists("threads"),
                    try database.columns(of: "threads"))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(titles, ["first", "second"])
        XCTAssertTrue(hasThreads)
        XCTAssertEqual(columns, ["id", "title"])

        XCTAssertEqual(try listing(directory), before)
        XCTAssertEqual(try bytes(url), beforeBytes)
    }

    func test_snapshot_retries_without_immutable_when_a_writer_appears_during_the_read() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let url = try makeClosedWALDatabase(in: directory)
        let writer = WriterBox()
        addTeardownBlock { writer.database?.close() }

        var calls = 0
        let count = try AgentHistoryDatabase.readExternalSnapshot(url: url) { database -> Int64? in
            calls += 1
            let count = try database.scalarInt64("SELECT count(*) FROM threads")
            if writer.database == nil {
                // The agent starts writing mid-read: `-wal` appears and the immutable view is stale.
                let opened = try AgentHistoryDatabase(url: url, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
                try opened.execute("PRAGMA wal_autocheckpoint = 0")
                try opened.run("INSERT INTO threads(id, title) VALUES ('t3', 'third')")
                writer.database = opened
            }
            return count
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(count, 3)
    }

    func test_snapshot_reads_delete_journal_and_live_wal_databases_with_regular_connection() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        let rollback = try makeFixture("opencode.db", in: directory, journalMode: .delete)
        try rollback.execute("CREATE TABLE session(id TEXT PRIMARY KEY)")
        try rollback.run("INSERT INTO session(id) VALUES ('s1')")
        rollback.close()
        let wal = try makeFixture("state_5.sqlite", in: directory)
        try wal.execute("CREATE TABLE threads(id TEXT PRIMARY KEY)")
        try wal.run("INSERT INTO threads(id) VALUES ('t1')")
        let before = try listing(directory)

        XCTAssertEqual(try AgentHistoryDatabase.readExternalSnapshot(url: rollback.url) {
            try $0.scalarInt64("SELECT count(*) FROM session")
        }, 1)
        XCTAssertEqual(try AgentHistoryDatabase.readExternalSnapshot(url: wal.url) {
            try $0.scalarInt64("SELECT count(*) FROM threads")
        }, 1)
        XCTAssertEqual(try listing(directory), before)
    }

    func test_snapshot_missing_file_and_body_error_propagate() throws {
        let directory = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        XCTAssertThrowsError(try AgentHistoryDatabase.readExternalSnapshot(url: directory.appendingPathComponent("absent.db")) {
            try $0.scalarInt64("SELECT 1")
        }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .cantOpen)
        }
        let url = try makeClosedWALDatabase(in: directory)
        XCTAssertThrowsError(try AgentHistoryDatabase.readExternalSnapshot(url: url) {
            try $0.scalarInt64("SELECT missing_column FROM threads")
        }) { error in
            XCTAssertEqual((error as? AgentHistoryDatabaseError)?.kind, .other)
        }
        XCTAssertEqual(try listing(directory), ["state_5.sqlite"])
    }
}
